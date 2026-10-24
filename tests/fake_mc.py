import socket, json, sys, threading
def varint(n):
    n &= 0xFFFFFFFF; out = b""
    while True:
        b = n & 0x7F; n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n: return out
def read_varint(c):
    v = 0
    for i in range(5):
        b = c.recv(1)[0]; v |= (b & 0x7F) << (7*i)
        if not b & 0x80: return v
def serve(port, payload, once_n):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port)); s.listen(5)
    for _ in range(once_n):
        c, _ = s.accept()
        L = read_varint(c); hs = c.recv(L)
        L2 = read_varint(c); c.recv(L2)
        body = varint(0) + varint(len(payload)) + payload
        c.sendall(varint(len(body)) + body); c.close()
    s.close()
lan = {"version":{"name":"26.3","protocol":800},"players":{"max":8,"online":2,
  "sample":[{"name":"Steve","id":"x"},{"name":"Alex","id":"y"}]},
  "description":{"text":"Steve - \u041f\u043e\u0434\u0437\u0435\u043c\u043d\u044b\u0439 \u0440\u044b\u043d\u043e\u043a"},
  "favicon":"data:image/png;base64," + "A"*20000}
fancy = {"version":{"name":"Paper 26.3"},"players":{"max":20,"online":0},
  "description":{"text":"","extra":[{"text":"\u00a7aЗелёный\tсервер "},"\u00a7lжирный",{"text":"!","extra":["?"]}]}}
def serve_legacy(port, text, n):
    # Minecraft 1.3-1.6: answers 0xFE with 0xFF + UTF-16BE string; drops anything else
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port)); s.listen(5)
    for _ in range(n):
        c, _ = s.accept()
        first = c.recv(1)
        if first == b"\xfe":
            data = text.encode("utf-16-be")
            c.sendall(b"\xff" + (len(text)).to_bytes(2, "big") + data)
        c.close()
    s.close()

def serve_legacy13_lan(bind, port, text, n):
    # like a real 1.3.2 LAN world: listens on the LAN address only, kicks non-FE packets,
    # silently drops a reconnect from the same non-loopback address within 5 s
    import time
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((bind, port)); s.listen(5)
    last = {}
    for _ in range(n):
        c, (addr, _) = s.accept()
        now = time.time()
        if addr != "127.0.0.1" and addr in last and now - last[addr] < 5:
            last[addr] = now
            print("throttled", flush=True)
            c.close(); continue
        last[addr] = now
        first = c.recv(1)
        if first == b"\xfe":
            data = text.encode("utf-16-be")
            c.sendall(b"\xff" + len(text).to_bytes(2, "big") + data)
            print("answered", flush=True)
        else:
            kick = "Protocol error"
            c.sendall(b"\xff" + len(kick).to_bytes(2, "big") + kick.encode("utf-16-be"))
            print("kicked", flush=True)
        c.close()
    s.close()

which = sys.argv[1]; port = int(sys.argv[2]); n = int(sys.argv[3])
if which == "legacy13lan":
    serve_legacy13_lan(sys.argv[4], port, "Ognik33 - Old LAN\u00a71\u00a78", n)
    sys.exit(0)
if which == "legacy13":
    serve_legacy(port, "Ognik33 - \u0421\u0442\u0430\u0440\u044b\u0439 \u043c\u0438\u0440\u00a71\u00a78", n)
elif which == "legacy16":
    serve_legacy(port, "\u00a71\x0078\x001.6.4\x00Ognik33 - Old World\x002\x008", n)
else:
    serve(port, json.dumps(lan if which=="lan" else fancy, ensure_ascii=(which=="lan")).encode(), n)
