# Agent protocol test: starts game_probe --agent, plays the role of Porthole's tcp_send,
# checks events. Usage: python3 tests/agent_test.py <probe_binary>
import socket, subprocess, sys, time, threading, os

PROBE = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN = "abcdef0123456789abcdef0123456789"

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def send(port, text):  # like porthole.tcp_send: connect, send, close
    c = socket.create_connection(("127.0.0.1", port)); c.sendall(text.encode()); c.close()

events = []
def reader(proc):
    for line in proc.stdout:
        events.append(line.rstrip("\n"))

def wait_for(pred, timeout=10):
    t = time.time()
    while time.time() - t < timeout:
        for e in list(events):
            if pred(e): return e
        time.sleep(0.05)
    return None

def check(name, ok):
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        global failed; failed = True

failed = False
ap = free_port()
proc = subprocess.Popen([PROBE, "--agent", str(ap), TOKEN], stdout=subprocess.PIPE, text=True, encoding="utf-8")
threading.Thread(target=reader, args=(proc,), daemon=True).start()

check("hello with proto=1", wait_for(lambda e: e.startswith("hello\tproto=1")) is not None)
check("ready", wait_for(lambda e: e.startswith("ready\tport=")) is not None)

# two fake worlds
w1, w2 = free_port(), free_port()
srv = [subprocess.Popen([sys.executable, os.path.join(HERE, "fake_mc.py"), "lan", str(w1), "100"]),
       subprocess.Popen([sys.executable, os.path.join(HERE, "fake_mc.py"), "legacy16", str(w2), "100"])]
time.sleep(0.5)

send(ap, "wrongtoken0000000000000000000000\tworlds\t1\tminecraft:%d\n" % w1)
check("bad token rejected", wait_for(lambda e: e.startswith("error\treason=bad_token")) is not None)

send(ap, "%s\tworlds\t5\tminecraft:%d\tminecraft:%d\n" % (TOKEN, w1, w2))
check("ack seq=5", wait_for(lambda e: e == "ack\tseq=5") is not None)
check("status world 1 (modern)", wait_for(lambda e: e.startswith("status") and ("port=%d\t" % w1) in e and "ping=modern" in e) is not None)
check("status world 2 (legacy)", wait_for(lambda e: e.startswith("status") and ("port=%d\t" % w2) in e and "ping=legacy" in e) is not None)

# stale seq must be ignored
n_before = len([e for e in events if e.startswith("ack")])
send(ap, "%s\tworlds\t3\n" % TOKEN)
time.sleep(0.5)
check("stale seq ignored", len([e for e in events if e.startswith("ack")]) == n_before)

# remove world 2 -> no more events for it
send(ap, "%s\tworlds\t6\tminecraft:%d\n" % (TOKEN, w1))
check("ack seq=6", wait_for(lambda e: e == "ack\tseq=6") is not None)
mark = len(events)
srv[1].kill()  # if the agent still watched it, we'd see "offline" for w2
time.sleep(7)
check("removed world is silent", not any(("port=%d\t" % w2) in e for e in events[mark:]))

# bad world spec
send(ap, "%s\tworlds\t7\tminecraft:99999\tnosuchgame:1234\n" % TOKEN)
check("bad world reported", wait_for(lambda e: e.startswith("error\treason=bad_world")) is not None)

send(ap, "%s\tping\n" % TOKEN)
check("pong", wait_for(lambda e: e == "pong") is not None)

# two commands in one send
send(ap, "%s\tping\n%s\tworlds\t9\n" % (TOKEN, TOKEN))
check("two commands in one send", wait_for(lambda e: e == "ack\tseq=9") is not None)

# bind conflict: a second agent on the same port must say error reason=bind
p2 = subprocess.run([PROBE, "--agent", str(ap), TOKEN], capture_output=True, text=True, timeout=5)
check("bind conflict -> error reason=bind", "error\treason=bind" in p2.stdout)

send(ap, "%s\tquit\n" % TOKEN)
try:
    proc.wait(timeout=4); quit_ok = True
except subprocess.TimeoutExpired:
    proc.kill(); quit_ok = False
check("quit stops the agent", quit_ok)
for s in srv: s.kill()
print("ALL PASSED" if not failed else "SOME FAILED")
sys.exit(1 if failed else 0)
