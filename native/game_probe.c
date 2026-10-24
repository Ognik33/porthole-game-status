// game_probe — native helper for Porthole add-ons.
//
// Porthole contract (same as porthole_lan.dll): int porthole_native_main(int argc, char **argv).
// argv holds only our arguments. Output: UTF-8 text lines on stdout, fields separated by TAB.
// Porthole drops a stream with invalid UTF-8, so every value we print is sanitized.
//
// Main mode for the add-on:
//   --agent <port> <token>     one process per session. Listens on 127.0.0.1:<port> for commands
//                              (sent with porthole.tcp_send), reports events on stdout.
//
// Diagnostic / CLI modes:
//   --status <game> <port>     one query, one line
//   --watch  <game> <port> [s] query every s seconds, print when it changes
//   --clip   <text>            put text on the clipboard
//   --lan-addr                 address of Porthole's virtual LAN adapter (porthole0)
//   --mc-listen [s]            print Minecraft LAN announcements (multicast)
//   --hello
// Global flags (before the mode): --debug, --try-addr A.B.C.D
//
// Agent protocol (version 1)
//   commands, one per line:  <token> TAB <command> [TAB arg]...
//     worlds <seq> [<game>:<port>]...   desired set of worlds; newer seq wins, older is ignored
//     clip <text>                       put text on the clipboard
//     ping                              -> pong
//     quit
//   events:
//     hello   proto=1 version=.. caps=clip,lan
//     ready   port=..
//     ack     seq=..
//     status  game=.. port=.. version=.. online=.. max=.. motd=.. host=.. world=.. players=..
//             ping=modern|legacy addr=..
//     offline game=.. port=.. reason=connect|timeout|protocol|json|socket
//     lanaddr addr=..   |   lanaddr none
//     clip ok | clip error=..
//     pong
//     error reason=.. [detail=..]

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cJSON.h"

#define PROBE_VERSION "0.3.0"
#define AGENT_PROTO 1
#define MAX_PACKET (2 * 1024 * 1024)
#define MAX_WORLDS 32

// ======================================================================
// platform layer
// ======================================================================

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
typedef SOCKET sock_t;
#define BAD_SOCK INVALID_SOCKET
#define CLOSESOCK closesocket
typedef CRITICAL_SECTION mutex_t;
static void mutex_init(mutex_t *m) { InitializeCriticalSection(m); }
static void mutex_lock(mutex_t *m) { EnterCriticalSection(m); }
static void mutex_unlock(mutex_t *m) { LeaveCriticalSection(m); }
static void sleep_ms(int ms) { Sleep((DWORD)ms); }
typedef DWORD(WINAPI *thread_fn)(void *);
#define THREAD_RET DWORD WINAPI
#define THREAD_RETURN return 0
static int thread_start(thread_fn fn, void *arg) {
    HANDLE h = CreateThread(NULL, 0, fn, arg, 0, NULL);
    if (!h) return 0;
    CloseHandle(h);
    return 1;
}
#else
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/time.h>
#include <netdb.h>
typedef int sock_t;
#define BAD_SOCK (-1)
#define CLOSESOCK close
typedef pthread_mutex_t mutex_t;
static void mutex_init(mutex_t *m) { pthread_mutex_init(m, NULL); }
static void mutex_lock(mutex_t *m) { pthread_mutex_lock(m); }
static void mutex_unlock(mutex_t *m) { pthread_mutex_unlock(m); }
static void sleep_ms(int ms) { usleep((useconds_t)ms * 1000); }
typedef void *(*thread_fn)(void *);
#define THREAD_RET void *
#define THREAD_RETURN return NULL
static int thread_start(thread_fn fn, void *arg) {
    pthread_t t;
    if (pthread_create(&t, NULL, fn, arg) != 0) return 0;
    pthread_detach(t);
    return 1;
}
#endif

static int net_init(void) {
#ifdef _WIN32
    static volatile LONG done = 0;
    if (!done) {
        WSADATA w;
        if (WSAStartup(MAKEWORD(2, 2), &w) != 0) return 0;
        done = 1;
    }
#endif
    return 1;
}

static void set_timeouts(sock_t s, int ms) {
#ifdef _WIN32
    DWORD t = (DWORD)ms;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&t, sizeof t);
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&t, sizeof t);
#else
    struct timeval tv = { ms / 1000, (ms % 1000) * 1000 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
#endif
}

static void addr_str(unsigned long a, char *out, size_t n) {
    unsigned char *b = (unsigned char *)&a;
    snprintf(out, n, "%u.%u.%u.%u", b[0], b[1], b[2], b[3]);
}

// ======================================================================
// output (thread-safe, UTF-8 sanitized)
// ======================================================================

static mutex_t g_out_lock;
static volatile int g_out_ok = 1;
static int g_debug = 0;
static unsigned long g_extra_addr = 0; // --try-addr

static void out_line(const char *s) {
    mutex_lock(&g_out_lock);
    if (g_out_ok) {
        size_t n = strlen(s);
#ifdef _WIN32
        HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
        DWORD w;
        if (!h || h == INVALID_HANDLE_VALUE || !WriteFile(h, s, (DWORD)n, &w, NULL) || !WriteFile(h, "\n", 1, &w, NULL))
            g_out_ok = 0;
#else
        if (fwrite(s, 1, n, stdout) != n || fputc('\n', stdout) == EOF) g_out_ok = 0;
        fflush(stdout);
#endif
    }
    mutex_unlock(&g_out_lock);
}

typedef struct { char *p; size_t n, cap; } sbuf;

static void sb_putn(sbuf *b, const char *s, size_t n) {
    if (b->n + n + 1 > b->cap) {
        size_t c = b->cap ? b->cap * 2 : 256;
        while (c < b->n + n + 1) c *= 2;
        char *q = realloc(b->p, c);
        if (!q) return;
        b->p = q;
        b->cap = c;
    }
    memcpy(b->p + b->n, s, n);
    b->n += n;
    b->p[b->n] = 0;
}
static void sb_put(sbuf *b, const char *s) { sb_putn(b, s, strlen(s)); }
static void sb_free(sbuf *b) { free(b->p); b->p = NULL; b->n = b->cap = 0; }
static const char *sb_str(const sbuf *b) { return b->p ? b->p : ""; }

// field value: TAB/CR/LF -> space, drop other control chars, strip Minecraft '§x' codes,
// keep only valid UTF-8, cap length
static void sb_put_clean(sbuf *b, const char *s, size_t max_bytes) {
    const unsigned char *u = (const unsigned char *)s;
    size_t start = b->n;
    while (*u && b->n - start < max_bytes) {
        if (u[0] == 0xC2 && u[1] == 0xA7) {
            u += 2;
            if (*u) {
                if (*u < 0x80) u++;
                else { u++; while ((*u & 0xC0) == 0x80) u++; }
            }
            continue;
        }
        unsigned char c = *u;
        if (c == '\t' || c == '\r' || c == '\n') { sb_putn(b, " ", 1); u++; continue; }
        if (c < 0x20 || c == 0x7F) { u++; continue; }
        if (c < 0x80) { sb_putn(b, (const char *)u, 1); u++; continue; }
        int len = (c >= 0xF0 && c <= 0xF4) ? 4 : (c >= 0xE0 && c <= 0xEF) ? 3 : (c >= 0xC2 && c <= 0xDF) ? 2 : 0;
        int ok = len > 0;
        for (int i = 1; ok && i < len; i++) if ((u[i] & 0xC0) != 0x80) ok = 0;
        if (ok) { sb_putn(b, (const char *)u, (size_t)len); u += len; }
        else { sb_putn(b, "?", 1); u++; }
    }
}

static void sb_field(sbuf *b, const char *key, const char *val) {
    sb_put(b, "\t");
    sb_put(b, key);
    sb_put(b, "=");
    sb_put_clean(b, val ? val : "", 512);
}
static void sb_field_int(sbuf *b, const char *key, long v) {
    char n[32];
    snprintf(n, sizeof n, "%ld", v);
    sb_field(b, key, n);
}

static void dbg(const char *tag, const char *msg) {
    if (!g_debug) return;
    sbuf l = {0};
    sb_put(&l, "debug");
    sb_field(&l, "tag", tag);
    sb_field(&l, "msg", msg);
    out_line(sb_str(&l));
    sb_free(&l);
}
static void dbg_hex(const char *tag, const unsigned char *p, int n) {
    if (!g_debug) return;
    char buf[256];
    int k = snprintf(buf, sizeof buf, "%d bytes:", n);
    for (int i = 0; i < n && i < 32 && k < (int)sizeof buf - 4; i++) k += snprintf(buf + k, sizeof buf - k, " %02x", p[i]);
    dbg(tag, buf);
}

static void emit_error(const char *reason, const char *detail) {
    sbuf l = {0};
    sb_put(&l, "error");
    sb_field(&l, "reason", reason);
    if (detail) sb_field(&l, "detail", detail);
    out_line(sb_str(&l));
    sb_free(&l);
}

// ======================================================================
// connections to local game ports
// ======================================================================

// per-world connection memory: which local address answered last time
typedef struct { unsigned long last_addr; } conn_ctx;

static int ctx_is_loopback(const conn_ctx *c) { return c->last_addr == htonl(0x7F000001); }

static sock_t tcp_connect_addr(unsigned long addr_be, int port) {
    sock_t s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == BAD_SOCK) return BAD_SOCK;
    set_timeouts(s, 3000);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = addr_be;
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) { CLOSESOCK(s); return BAD_SOCK; }
    return s;
}

// Loopback first; some old servers (Minecraft 1.3 LAN) bind only to the PC's own address,
// so then every IPv4 address of this machine. The one that answered is remembered per world.
static sock_t tcp_connect_local(conn_ctx *c, int port) {
    sock_t s;
    if (c->last_addr) {
        s = tcp_connect_addr(c->last_addr, port);
        if (s != BAD_SOCK) return s;
    }
    unsigned long lo = htonl(0x7F000001);
    s = tcp_connect_addr(lo, port);
    if (s != BAD_SOCK) { c->last_addr = lo; return s; }
    if (g_extra_addr) {
        s = tcp_connect_addr(g_extra_addr, port);
        if (s != BAD_SOCK) { c->last_addr = g_extra_addr; return s; }
    }
    char host[256];
    if (gethostname(host, sizeof host) != 0) return BAD_SOCK;
    struct addrinfo hints, *res = NULL, *it;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, NULL, &hints, &res) != 0) return BAD_SOCK;
    s = BAD_SOCK;
    for (it = res; it; it = it->ai_next) {
        unsigned long a = ((struct sockaddr_in *)it->ai_addr)->sin_addr.s_addr;
        if (a == lo) continue;
        char ab[32];
        addr_str(a, ab, sizeof ab);
        dbg("connect", ab);
        s = tcp_connect_addr(a, port);
        if (s != BAD_SOCK) { c->last_addr = a; break; }
    }
    freeaddrinfo(res);
    return s;
}

static int send_all(sock_t s, const unsigned char *p, int n) {
    while (n > 0) {
        int w = send(s, (const char *)p, n, 0);
        if (w <= 0) return 0;
        p += w;
        n -= w;
    }
    return 1;
}
static int recv_all(sock_t s, unsigned char *p, int n) {
    while (n > 0) {
        int r = recv(s, (char *)p, n, 0);
        if (r <= 0) return 0;
        p += r;
        n -= r;
    }
    return 1;
}

// ======================================================================
// adapter: Minecraft (Java Edition)
//   modern Server List Ping (1.7+), legacy 0xFE 0x01 (1.4-1.6), legacy 0xFE (1.3 and older)
// ======================================================================

static int put_varint(unsigned char *p, unsigned int v) {
    int n = 0;
    do {
        unsigned char b = v & 0x7F;
        v >>= 7;
        if (v) b |= 0x80;
        p[n++] = b;
    } while (v);
    return n;
}
static int recv_varint(sock_t s, int *out) {
    unsigned int v = 0;
    for (int i = 0; i < 5; i++) {
        unsigned char b;
        if (!recv_all(s, &b, 1)) return 0;
        v |= (unsigned int)(b & 0x7F) << (7 * i);
        if (!(b & 0x80)) { *out = (int)v; return 1; }
    }
    return 0;
}
static int buf_varint(const unsigned char **p, const unsigned char *end, int *out) {
    unsigned int v = 0;
    for (int i = 0; i < 5; i++) {
        if (*p >= end) return 0;
        unsigned char b = *(*p)++;
        v |= (unsigned int)(b & 0x7F) << (7 * i);
        if (!(b & 0x80)) { *out = (int)v; return 1; }
    }
    return 0;
}

static void chat_text(sbuf *b, const cJSON *c) {
    if (!c) return;
    if (cJSON_IsString(c)) { sb_put(b, c->valuestring); return; }
    if (cJSON_IsArray(c)) {
        const cJSON *e;
        cJSON_ArrayForEach(e, c) chat_text(b, e);
        return;
    }
    if (cJSON_IsObject(c)) {
        const cJSON *t = cJSON_GetObjectItemCaseSensitive(c, "text");
        if (cJSON_IsString(t)) sb_put(b, t->valuestring);
        chat_text(b, cJSON_GetObjectItemCaseSensitive(c, "extra"));
    }
}

static char *offline_line(const char *game, int port, const char *reason) {
    sbuf l = {0};
    sb_put(&l, "offline");
    sb_field(&l, "game", game);
    sb_field_int(&l, "port", port);
    sb_field(&l, "reason", reason);
    return l.p;
}

// common tail for both Minecraft protocols
static char *mc_status_out(const conn_ctx *c, int port, const char *version, long protocol, long online, long max,
                           const char *motd, const char *players, const char *ping) {
    sbuf host = {0}, world = {0};
    const char *sep = strstr(motd, " - ");
    if (sep) { sb_putn(&host, motd, (size_t)(sep - motd)); sb_put(&world, sep + 3); }
    else sb_put(&world, motd);
    char ab[32];
    addr_str(c->last_addr, ab, sizeof ab);
    sbuf l = {0};
    sb_put(&l, "status");
    sb_field(&l, "game", "minecraft");
    sb_field_int(&l, "port", port);
    sb_field(&l, "version", version);
    sb_field_int(&l, "protocol", protocol);
    sb_field_int(&l, "online", online);
    sb_field_int(&l, "max", max);
    sb_field(&l, "motd", motd);
    sb_field(&l, "host", sb_str(&host));
    sb_field(&l, "world", sb_str(&world));
    sb_field(&l, "players", players);
    sb_field(&l, "ping", ping);
    sb_field(&l, "addr", ab);
    sb_free(&host);
    sb_free(&world);
    return l.p;
}

static char *mc_modern_on(const conn_ctx *c, sock_t s, int port) {
    unsigned char *pkt = NULL;
    cJSON *j = NULL;
    const char *reason = NULL;
    char *out = NULL;
    {
        unsigned char hs[64], body[64];
        const char *host = "127.0.0.1";
        int n = 0;
        n += put_varint(body + n, 0x00);
        n += put_varint(body + n, 0xFFFFFFFFu); // protocol -1: status only
        n += put_varint(body + n, (unsigned)strlen(host));
        memcpy(body + n, host, strlen(host));
        n += (int)strlen(host);
        body[n++] = (unsigned char)((port >> 8) & 0xFF);
        body[n++] = (unsigned char)(port & 0xFF);
        n += put_varint(body + n, 1);
        int h = put_varint(hs, (unsigned)n);
        memcpy(hs + h, body, (size_t)n);
        h += n;
        hs[h++] = 0x01;
        hs[h++] = 0x00;
        dbg_hex("modern send", hs, h);
        if (!send_all(s, hs, h)) { reason = "connect"; goto done; }
    }
    {
        int len = 0, id = -1, slen = 0;
        if (!recv_varint(s, &len)) { dbg("modern", "no reply"); reason = "timeout"; goto done; }
        if (len <= 0 || len > MAX_PACKET) { reason = "protocol"; goto done; }
        pkt = malloc((size_t)len);
        if (!pkt || !recv_all(s, pkt, len)) { reason = "timeout"; goto done; }
        const unsigned char *p = pkt, *end = pkt + len;
        if (!buf_varint(&p, end, &id) || id != 0) { reason = "protocol"; goto done; }
        if (!buf_varint(&p, end, &slen) || slen < 0 || slen > end - p) { reason = "protocol"; goto done; }
        j = cJSON_ParseWithLength((const char *)p, (size_t)slen);
        if (!j) { reason = "json"; goto done; }
    }
    {
        const cJSON *ver = cJSON_GetObjectItemCaseSensitive(j, "version");
        const cJSON *vname = ver ? cJSON_GetObjectItemCaseSensitive(ver, "name") : NULL;
        const cJSON *vproto = ver ? cJSON_GetObjectItemCaseSensitive(ver, "protocol") : NULL;
        const cJSON *pl = cJSON_GetObjectItemCaseSensitive(j, "players");
        const cJSON *on = pl ? cJSON_GetObjectItemCaseSensitive(pl, "online") : NULL;
        const cJSON *mx = pl ? cJSON_GetObjectItemCaseSensitive(pl, "max") : NULL;
        const cJSON *sample = pl ? cJSON_GetObjectItemCaseSensitive(pl, "sample") : NULL;
        sbuf motd = {0}, players = {0};
        chat_text(&motd, cJSON_GetObjectItemCaseSensitive(j, "description"));
        if (cJSON_IsArray(sample)) {
            const cJSON *e;
            cJSON_ArrayForEach(e, sample) {
                const cJSON *nm = cJSON_GetObjectItemCaseSensitive(e, "name");
                if (cJSON_IsString(nm)) {
                    if (players.n) sb_put(&players, ",");
                    sb_put(&players, nm->valuestring);
                }
            }
        }
        out = mc_status_out(c, port, cJSON_IsString(vname) ? vname->valuestring : "",
                            cJSON_IsNumber(vproto) ? vproto->valueint : -1, cJSON_IsNumber(on) ? on->valueint : -1,
                            cJSON_IsNumber(mx) ? mx->valueint : -1, sb_str(&motd), sb_str(&players), "modern");
        sb_free(&motd);
        sb_free(&players);
    }
done:
    if (j) cJSON_Delete(j);
    free(pkt);
    CLOSESOCK(s);
    return out ? out : offline_line("minecraft", port, reason ? reason : "unknown");
}

static void sb_put_cp(sbuf *b, unsigned int cp) {
    char u[4];
    int n;
    if (cp < 0x80) { u[0] = (char)cp; n = 1; }
    else if (cp < 0x800) { u[0] = (char)(0xC0 | (cp >> 6)); u[1] = (char)(0x80 | (cp & 0x3F)); n = 2; }
    else if (cp < 0x10000) {
        u[0] = (char)(0xE0 | (cp >> 12)); u[1] = (char)(0x80 | ((cp >> 6) & 0x3F)); u[2] = (char)(0x80 | (cp & 0x3F)); n = 3;
    } else {
        u[0] = (char)(0xF0 | (cp >> 18)); u[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        u[2] = (char)(0x80 | ((cp >> 6) & 0x3F)); u[3] = (char)(0x80 | (cp & 0x3F)); n = 4;
    }
    sb_putn(b, u, (size_t)n);
}

static char *mc_legacy_on(const conn_ctx *c, sock_t s, int port, int plain) {
    const char *reason = NULL;
    unsigned short *chars = NULL;
    char *out = NULL;
    sbuf f[8];
    memset(f, 0, sizeof f);
    {
        unsigned char req[2] = { 0xFE, 0x01 };
        dbg_hex("legacy send", req, plain ? 1 : 2);
        if (!send_all(s, req, plain ? 1 : 2)) { reason = "connect"; goto done; }
    }
    unsigned char hdr[3];
    if (!recv_all(s, hdr, 3)) { dbg("legacy", "no reply"); reason = "timeout"; goto done; }
    dbg_hex("legacy recv", hdr, 3);
    if (hdr[0] != 0xFF) { reason = "protocol"; goto done; }
    int n = (hdr[1] << 8) | hdr[2];
    if (n <= 0 || n > 32767) { reason = "protocol"; goto done; }
    {
        unsigned char *raw = malloc((size_t)n * 2);
        if (!raw) { reason = "protocol"; goto done; }
        if (!recv_all(s, raw, n * 2)) { free(raw); reason = "timeout"; goto done; }
        chars = malloc(sizeof(unsigned short) * (size_t)n);
        if (!chars) { free(raw); reason = "protocol"; goto done; }
        for (int i = 0; i < n; i++) chars[i] = (unsigned short)((raw[2 * i] << 8) | raw[2 * i + 1]);
        free(raw);
    }
    {
        int nf = 0;
        int v2 = (n >= 3 && chars[0] == 0xA7 && chars[1] == '1' && chars[2] == 0); // 1.4-1.6 "§1\0..."
        unsigned short sep = v2 ? 0 : 0xA7;
        sb_put(&f[0], "");
        for (int i = v2 ? 3 : 0; i < n; i++) {
            unsigned int cp = chars[i];
            if (cp == sep) {
                if (nf < 7) { nf++; sb_put(&f[nf], ""); }
                continue;
            }
            if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < n && chars[i + 1] >= 0xDC00 && chars[i + 1] <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (chars[i + 1] - 0xDC00);
                i++;
            }
            sb_put_cp(&f[nf], cp);
        }
        nf++;
        if (v2 && nf >= 5) {
            out = mc_status_out(c, port, sb_str(&f[1]), atol(sb_str(&f[0])), atol(sb_str(&f[3])), atol(sb_str(&f[4])),
                                sb_str(&f[2]), "", "legacy");
        } else if (!v2 && nf >= 3) {
            out = mc_status_out(c, port, "", -1, atol(sb_str(&f[nf - 2])), atol(sb_str(&f[nf - 1])), sb_str(&f[0]), "",
                                "legacy");
        } else {
            reason = "protocol";
        }
    }
done:
    for (int i = 0; i < 8; i++) sb_free(&f[i]);
    free(chars);
    CLOSESOCK(s);
    return out ? out : offline_line("minecraft", port, reason ? reason : "unknown");
}

enum { P_MODERN = 1, P_LEGACY = 2, P_LEGACY_PLAIN = 3 };

static int is_status(const char *l) { return strncmp(l, "status", 6) == 0; }
static int is_refused(const char *l) { return strstr(l, "reason=connect") != NULL; }

static char *mc_try(conn_ctx *c, int port, int proto) {
    if (!net_init()) return offline_line("minecraft", port, "socket");
    sock_t s = tcp_connect_local(c, port);
    if (s == BAD_SOCK) return offline_line("minecraft", port, "connect");
    if (proto == P_MODERN) return mc_modern_on(c, s, port);
    return mc_legacy_on(c, s, port, proto == P_LEGACY_PLAIN);
}

// per-world Minecraft state
typedef struct {
    conn_ctx conn;
    int mode; // protocol that worked, 0 = unknown
    int next; // next candidate when only one connection per poll is allowed
} mc_state;

// One poll. Over loopback every protocol is tried at once. Over a LAN address (old servers) only
// one connection per poll: those servers silently drop a reconnect from the same non-loopback
// address within ~5 s.
static char *mc_poll(mc_state *st, int port) {
    if (st->mode) {
        char *l = mc_try(&st->conn, port, st->mode);
        if (is_status(l) || is_refused(l)) return l;
        free(l);
        st->next = st->mode;
        st->mode = 0;
        return offline_line("minecraft", port, "timeout");
    }
    int first = st->next ? st->next : P_MODERN;
    char *l = mc_try(&st->conn, port, first);
    if (is_status(l)) { st->mode = first; st->next = 0; return l; }
    if (is_refused(l)) return l;
    if (!ctx_is_loopback(&st->conn)) {
        static const int order[3] = { P_LEGACY, P_LEGACY_PLAIN, P_MODERN };
        int idx = 0;
        for (int i = 0; i < 3; i++) if (order[i] == first) idx = i;
        st->next = (first == P_MODERN && st->next == 0) ? P_LEGACY : order[(idx + 1) % 3];
        return l;
    }
    static const int rest[2] = { P_LEGACY, P_LEGACY_PLAIN };
    for (int i = 0; i < 2; i++) {
        if (rest[i] == first) continue;
        char *x = mc_try(&st->conn, port, rest[i]);
        if (is_status(x)) { free(l); st->mode = rest[i]; st->next = 0; return x; }
        free(x);
    }
    return l;
}

// ======================================================================
// adapter registry
// ======================================================================

typedef struct {
    const char *id;
    void *(*create)(void);
    void (*destroy)(void *state);
    char *(*poll)(void *state, int port);       // heap line: status / offline
    int (*interval_ms)(void *state, int base_ms); // how long to wait before the next poll
} adapter;

static void *mc_create(void) { return calloc(1, sizeof(mc_state)); }
static void mc_destroy(void *s) { free(s); }
static char *mc_poll_v(void *s, int port) { return mc_poll((mc_state *)s, port); }
static int mc_interval(void *s, int base_ms) {
    mc_state *st = (mc_state *)s;
    // old servers reached over a LAN address throttle reconnects (~5 s)
    if (st->conn.last_addr && !ctx_is_loopback(&st->conn) && base_ms < 7000) return 7000;
    return base_ms;
}

static const adapter ADAPTERS[] = {
    { "minecraft", mc_create, mc_destroy, mc_poll_v, mc_interval },
};

static const adapter *find_adapter(const char *id) {
    for (size_t i = 0; i < sizeof ADAPTERS / sizeof ADAPTERS[0]; i++)
        if (!strcmp(ADAPTERS[i].id, id)) return &ADAPTERS[i];
    return NULL;
}

// ======================================================================
// clipboard
// ======================================================================

static const char *clip_set(const char *text) {
#ifdef _WIN32
    int wn = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (wn <= 0) return "utf8";
    HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)wn * sizeof(wchar_t));
    if (!mem) return "alloc";
    wchar_t *w = (wchar_t *)GlobalLock(mem);
    MultiByteToWideChar(CP_UTF8, 0, text, -1, w, wn);
    GlobalUnlock(mem);
    int opened = 0;
    for (int i = 0; i < 10 && !opened; i++) {
        opened = OpenClipboard(NULL);
        if (!opened) Sleep(50);
    }
    if (!opened) { GlobalFree(mem); return "busy"; }
    EmptyClipboard();
    if (!SetClipboardData(CF_UNICODETEXT, mem)) { CloseClipboard(); GlobalFree(mem); return "set"; }
    CloseClipboard();
    return NULL;
#else
    (void)text;
    return "unsupported";
#endif
}

static void emit_clip(const char *text) {
    const char *err = clip_set(text);
    if (!err) { out_line("clip\tok"); return; }
    sbuf l = {0};
    sb_put(&l, "clip");
    sb_field(&l, "error", err);
    out_line(sb_str(&l));
    sb_free(&l);
}

// ======================================================================
// virtual LAN address (adapter "porthole0" created by Porthole's Virtual LAN add-on)
// ======================================================================

static void find_lan_addr(char *out, size_t n) {
    out[0] = 0;
#ifdef _WIN32
    ULONG size = 16 * 1024;
    IP_ADAPTER_ADDRESSES *list = NULL;
    ULONG rc = ERROR_BUFFER_OVERFLOW;
    for (int tries = 0; tries < 3 && rc == ERROR_BUFFER_OVERFLOW; tries++) {
        free(list);
        list = malloc(size);
        if (!list) return;
        rc = GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
                                  NULL, list, &size);
    }
    if (rc == NO_ERROR) {
        for (IP_ADAPTER_ADDRESSES *a = list; a && !out[0]; a = a->Next) {
            if (!a->FriendlyName || _wcsicmp(a->FriendlyName, L"porthole0") != 0) continue;
            if (a->OperStatus != IfOperStatusUp) continue;
            for (IP_ADAPTER_UNICAST_ADDRESS *u = a->FirstUnicastAddress; u; u = u->Next) {
                if (u->Address.lpSockaddr->sa_family != AF_INET) continue;
                addr_str(((struct sockaddr_in *)u->Address.lpSockaddr)->sin_addr.s_addr, out, n);
                break;
            }
        }
    }
    free(list);
#else
    (void)n;
#endif
}

static void emit_lan(const char *addr) {
    sbuf l = {0};
    sb_put(&l, "lanaddr");
    if (addr[0]) sb_field(&l, "addr", addr);
    else sb_put(&l, "\tnone");
    out_line(sb_str(&l));
    sb_free(&l);
}

// ======================================================================
// agent
// ======================================================================

static volatile int g_quit = 0;

// one watched world = one thread. The thread owns its state and frees it on exit;
// the agent only flips `stop`.
typedef struct world {
    int port;
    char game[17];
    volatile int stop;
    int base_ms;
} world;

static THREAD_RET world_thread(void *arg) {
    world *w = (world *)arg;
    const adapter *ad = find_adapter(w->game);
    void *st = ad ? ad->create() : NULL;
    char *last = NULL;
    if (!ad || !st) {
        emit_error("adapter", w->game);
    } else {
        while (!w->stop && !g_quit && g_out_ok) {
            char *l = ad->poll(st, w->port);
            if (w->stop) { free(l); break; } // removed while we were asking: say nothing
            if (!last || strcmp(last, l) != 0) out_line(l);
            free(last);
            last = l;
            int wait = ad->interval_ms(st, w->base_ms);
            for (int t = 0; t < wait && !w->stop && !g_quit; t += 100) sleep_ms(100);
        }
    }
    free(last);
    if (ad && st) ad->destroy(st);
    free(w);
    THREAD_RETURN;
}

static THREAD_RET lan_thread(void *arg) {
    (void)arg;
    char last[32] = "-", now[32];
    while (!g_quit && g_out_ok) {
        find_lan_addr(now, sizeof now);
        if (strcmp(now, last) != 0) {
            emit_lan(now);
            strcpy(last, now);
        }
        for (int t = 0; t < 3000 && !g_quit; t += 100) sleep_ms(100);
    }
    THREAD_RETURN;
}

typedef struct {
    world *slots[MAX_WORLDS]; // owned by threads; we keep pointers only while they run
    long seq;
    char token[65];
} agent_state;

static int valid_game_id(const char *s) {
    size_t n = strlen(s);
    if (n == 0 || n > 16) return 0;
    for (size_t i = 0; i < n; i++)
        if (!((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= '0' && s[i] <= '9') || s[i] == '_')) return 0;
    return 1;
}

static int parse_port(const char *s) {
    if (!s || !*s) return -1;
    char *e;
    long v = strtol(s, &e, 10);
    if (*e || v < 1 || v > 65535) return -1;
    return (int)v;
}

// constant-time comparison, so the token can't be guessed byte by byte
static int token_ok(const char *a, const char *b) {
    size_t na = strlen(a), nb = strlen(b);
    unsigned char d = (unsigned char)(na != nb);
    for (size_t i = 0; i < na && i < nb; i++) d |= (unsigned char)(a[i] ^ b[i]);
    return d == 0 && nb > 0;
}

// reconcile running world threads with the desired set
static void apply_worlds(agent_state *ag, char **specs, int n) {
    int want_port[MAX_WORLDS];
    char want_game[MAX_WORLDS][17];
    int nw = 0;
    for (int i = 0; i < n && nw < MAX_WORLDS; i++) {
        char *colon = strchr(specs[i], ':');
        if (!colon) continue;
        *colon = 0;
        int port = parse_port(colon + 1);
        if (port < 0 || !valid_game_id(specs[i]) || !find_adapter(specs[i])) {
            emit_error("bad_world", specs[i]);
            continue;
        }
        want_port[nw] = port;
        snprintf(want_game[nw], sizeof want_game[nw], "%.16s", specs[i]);
        nw++;
    }
    // stop what is no longer wanted (or changed game)
    for (int s = 0; s < MAX_WORLDS; s++) {
        world *w = ag->slots[s];
        if (!w) continue;
        int keep = 0;
        for (int i = 0; i < nw; i++) if (want_port[i] == w->port && !strcmp(want_game[i], w->game)) keep = 1;
        if (!keep) { w->stop = 1; ag->slots[s] = NULL; }
    }
    // start what is new
    for (int i = 0; i < nw; i++) {
        int have = 0;
        for (int s = 0; s < MAX_WORLDS; s++)
            if (ag->slots[s] && ag->slots[s]->port == want_port[i] && !strcmp(ag->slots[s]->game, want_game[i])) have = 1;
        if (have) continue;
        int free_slot = -1;
        for (int s = 0; s < MAX_WORLDS && free_slot < 0; s++) if (!ag->slots[s]) free_slot = s;
        if (free_slot < 0) { emit_error("too_many_worlds", NULL); break; }
        world *w = calloc(1, sizeof(world));
        if (!w) break;
        w->port = want_port[i];
        memcpy(w->game, want_game[i], sizeof w->game);
        w->base_ms = 5000;
        ag->slots[free_slot] = w;
        if (!thread_start(world_thread, w)) { ag->slots[free_slot] = NULL; free(w); emit_error("thread", NULL); }
    }
}

static void handle_command(agent_state *ag, char *line) {
    char *parts[MAX_WORLDS + 4];
    int n = 0;
    char *p = line;
    while (n < (int)(sizeof parts / sizeof parts[0])) {
        parts[n++] = p;
        char *t = strchr(p, '\t');
        if (!t) break;
        *t = 0;
        p = t + 1;
    }
    if (n < 2 || !token_ok(parts[0], ag->token)) { emit_error("bad_token", NULL); return; }
    const char *cmd = parts[1];
    if (!strcmp(cmd, "worlds") && n >= 3) {
        char *e;
        long seq = strtol(parts[2], &e, 10);
        if (*e || seq <= ag->seq) return; // stale or repeated: the newest desired state already applied
        ag->seq = seq;
        apply_worlds(ag, parts + 3, n - 3);
        char a[48];
        snprintf(a, sizeof a, "ack\tseq=%ld", seq);
        out_line(a);
    } else if (!strcmp(cmd, "clip") && n >= 3) {
        emit_clip(parts[2]);
    } else if (!strcmp(cmd, "ping")) {
        out_line("pong");
    } else if (!strcmp(cmd, "quit")) {
        g_quit = 1;
    } else {
        emit_error("bad_command", cmd);
    }
}

static int mode_agent(const char *port_s, const char *token) {
    agent_state ag;
    memset(&ag, 0, sizeof ag);
    int port = parse_port(port_s);
    if (port < 0 || !token || strlen(token) < 16 || strlen(token) > 64) { emit_error("bad_args", NULL); return 2; }
    snprintf(ag.token, sizeof ag.token, "%s", token);
    if (!net_init()) { emit_error("socket", NULL); return 3; }

    sock_t ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (ls == BAD_SOCK) { emit_error("socket", NULL); return 3; }
#ifdef _WIN32
    { BOOL ex = TRUE; setsockopt(ls, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&ex, sizeof ex); }
#endif
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = htonl(0x7F000001); // loopback only: nothing outside this PC can reach it
    if (bind(ls, (struct sockaddr *)&a, sizeof a) != 0 || listen(ls, 8) != 0) {
        CLOSESOCK(ls);
        emit_error("bind", NULL);
        return 3;
    }

    {
        sbuf l = {0};
        sb_put(&l, "hello");
        sb_field_int(&l, "proto", AGENT_PROTO);
        sb_field(&l, "version", PROBE_VERSION);
#ifdef _WIN32
        sb_field(&l, "caps", "clip,lan");
#else
        sb_field(&l, "caps", "");
#endif
        out_line(sb_str(&l));
        sb_free(&l);
    }
    thread_start(lan_thread, NULL);
    {
        char r[32];
        snprintf(r, sizeof r, "ready\tport=%d", port);
        out_line(r);
    }

    while (!g_quit && g_out_ok) {
        fd_set rd;
        FD_ZERO(&rd);
        FD_SET(ls, &rd);
        struct timeval tv = { 1, 0 }; // wake up every second to notice quit / Porthole gone
        int r = select((int)ls + 1, &rd, NULL, NULL, &tv);
        if (r <= 0) continue;
        sock_t c = accept(ls, NULL, NULL);
        if (c == BAD_SOCK) continue;
        set_timeouts(c, 2000);
        // one tcp_send = one short connection; read until the peer closes (max 64 KB)
        sbuf in = {0};
        char buf[4096];
        for (;;) {
            int got = recv(c, buf, sizeof buf, 0);
            if (got <= 0) break;
            sb_putn(&in, buf, (size_t)got);
            if (in.n > 65536) break;
        }
        CLOSESOCK(c);
        char *s = in.p;
        while (s && *s) {
            char *nl = strchr(s, '\n');
            if (nl) *nl = 0;
            size_t len = strlen(s);
            if (len && s[len - 1] == '\r') s[len - 1] = 0;
            if (*s) handle_command(&ag, s);
            if (!nl) break;
            s = nl + 1;
        }
        sb_free(&in);
    }
    g_quit = 1;
    for (int s = 0; s < MAX_WORLDS; s++) if (ag.slots[s]) ag.slots[s]->stop = 1;
    CLOSESOCK(ls);
    return 0;
}

// ======================================================================
// Minecraft LAN announcements (multicast 224.0.2.60:4445) — diagnostics, used by 0.2.1
// ======================================================================

static void join_group_on(sock_t s, unsigned long iface_be) {
    struct ip_mreq m;
    memset(&m, 0, sizeof m);
    m.imr_multiaddr.s_addr = inet_addr("224.0.2.60");
    m.imr_interface.s_addr = iface_be;
    setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP, (const char *)&m, sizeof m);
}

static int mode_mc_listen(const char *seconds_s) {
    int seconds = seconds_s ? atoi(seconds_s) : 10;
    if (seconds < 1) seconds = 1;
    if (seconds > 600) seconds = 600;
    if (!net_init()) { emit_error("socket", NULL); return 1; }
    sock_t s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == BAD_SOCK) { emit_error("socket", NULL); return 1; }
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char *)&yes, sizeof yes);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(4445);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(s, (struct sockaddr *)&a, sizeof a) != 0) { emit_error("bind", NULL); CLOSESOCK(s); return 1; }
    join_group_on(s, htonl(INADDR_ANY));
#ifdef _WIN32
    {
        ULONG size = 16 * 1024;
        IP_ADAPTER_ADDRESSES *list = malloc(size);
        if (list && GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
                                         NULL, list, &size) == NO_ERROR) {
            for (IP_ADAPTER_ADDRESSES *ad = list; ad; ad = ad->Next) {
                if (ad->OperStatus != IfOperStatusUp) continue;
                for (IP_ADAPTER_UNICAST_ADDRESS *u = ad->FirstUnicastAddress; u; u = u->Next)
                    if (u->Address.lpSockaddr->sa_family == AF_INET)
                        join_group_on(s, ((struct sockaddr_in *)u->Address.lpSockaddr)->sin_addr.s_addr);
            }
        }
        free(list);
    }
#endif
    set_timeouts(s, 500);
    int got = 0;
    for (int i = 0; i < seconds * 2 && g_out_ok; i++) {
        char buf[1024];
        struct sockaddr_in from;
#ifdef _WIN32
        int fl = sizeof from;
#else
        socklen_t fl = sizeof from;
#endif
        int n = recvfrom(s, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
        if (n <= 0) continue;
        buf[n] = 0;
        got++;
        char *m1 = strstr(buf, "[MOTD]"), *m2 = strstr(buf, "[/MOTD]");
        char *a1 = strstr(buf, "[AD]"), *a2 = strstr(buf, "[/AD]");
        sbuf l = {0};
        char ab[32];
        addr_str(from.sin_addr.s_addr, ab, sizeof ab);
        sb_put(&l, "mcannounce");
        sb_field(&l, "from", ab);
        if (m1 && m2 && a1 && a2 && m2 > m1 && a2 > a1) {
            *m2 = 0;
            *a2 = 0;
            sb_field(&l, "ad", a1 + 4);
            sb_field(&l, "motd", m1 + 6);
        } else {
            sb_field(&l, "raw", buf);
        }
        out_line(sb_str(&l));
        sb_free(&l);
    }
    char d[48];
    snprintf(d, sizeof d, "done\tpackets=%d", got);
    out_line(d);
    CLOSESOCK(s);
    return 0;
}

// ======================================================================
// CLI modes and entry point
// ======================================================================

static int mode_status(const char *game, const char *port_s) {
    const adapter *ad = find_adapter(game);
    int port = parse_port(port_s);
    if (!ad) { emit_error("unknown_game", game); return 2; }
    if (port < 0) { emit_error("bad_port", NULL); return 2; }
    void *st = ad->create();
    char *l = ad->poll(st, port);
    if (!is_status(l) && ad->interval_ms(st, 0) > 0) {
        // reached over a LAN address: the first try found where the world lives; wait out the throttle
        free(l);
        sleep_ms(ad->interval_ms(st, 0));
        l = ad->poll(st, port);
    }
    out_line(l);
    free(l);
    ad->destroy(st);
    return 0;
}

static int mode_watch(const char *game, const char *port_s, const char *interval_s) {
    if (!find_adapter(game)) { emit_error("unknown_game", game); return 2; }
    int port = parse_port(port_s);
    if (port < 0) { emit_error("bad_port", NULL); return 2; }
    world *w = calloc(1, sizeof(world));
    w->port = port;
    snprintf(w->game, sizeof w->game, "%.16s", game);
    int iv = interval_s ? atoi(interval_s) : 5;
    w->base_ms = (iv < 2 ? 2 : iv > 120 ? 120 : iv) * 1000;
    world_thread(w); // runs until stdout breaks
    return 0;
}

#ifdef _WIN32
__declspec(dllexport)
#endif
int porthole_native_main(int argc, char **argv) {
    static int inited = 0;
    if (!inited) { mutex_init(&g_out_lock); inited = 1; }
    int i = 0;
    if (argc > 0 && argv[0] && argv[0][0] != '-') i = 1; // tolerate a program name
    for (;;) {
        if (i < argc && !strcmp(argv[i], "--debug")) { g_debug = 1; i++; continue; }
        if (i + 1 < argc && !strcmp(argv[i], "--try-addr")) { g_extra_addr = inet_addr(argv[i + 1]); i += 2; continue; }
        break;
    }
    if (i >= argc) { emit_error("no_mode", NULL); return 2; }
    const char *m = argv[i];
    const char *a1 = i + 1 < argc ? argv[i + 1] : NULL;
    const char *a2 = i + 2 < argc ? argv[i + 2] : NULL;
    const char *a3 = i + 3 < argc ? argv[i + 3] : NULL;
    if (!strcmp(m, "--agent") && a1 && a2) return mode_agent(a1, a2);
    if (!strcmp(m, "--status") && a1 && a2) return mode_status(a1, a2);
    if (!strcmp(m, "--watch") && a1 && a2) return mode_watch(a1, a2, a3);
    if (!strcmp(m, "--clip") && a1) { emit_clip(a1); return 0; }
    if (!strcmp(m, "--lan-addr")) { char a[32]; find_lan_addr(a, sizeof a); emit_lan(a); return 0; }
    if (!strcmp(m, "--mc-listen")) return mode_mc_listen(a1);
    if (!strcmp(m, "--hello")) {
        sbuf l = {0};
        sb_put(&l, "hello");
        sb_field_int(&l, "proto", AGENT_PROTO);
        sb_field(&l, "version", PROBE_VERSION);
        out_line(sb_str(&l));
        sb_free(&l);
        return 0;
    }
    emit_error("bad_args", m);
    return 2;
}

#if defined(TEST_MAIN) || defined(CLI_MAIN)
int main(int argc, char **argv) { return porthole_native_main(argc - 1, argv + 1); }
#endif
