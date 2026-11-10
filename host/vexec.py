#!/usr/bin/env python3
# vexec.py <vm> <command> — run a shell command in a tenant VM over vsock (a test client for weaver-guest).
import json, socket, struct, sys
vm, cmd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
s.connect(f"/opt/weaver/vms/{vm}/vsock.sock")
s.sendall(b"CONNECT 1024\n")
f = s.makefile("rb")
assert f.readline().startswith(b"OK"), "guest refused"
def send(t, b): s.sendall(struct.pack(">I", len(b) + 1) + t + b)
send(b"x", json.dumps({"argv": ["sh", "-c", cmd]}).encode())
send(b"e", b"")
while True:
    n, = struct.unpack(">I", f.read(4)); t, b = f.read(1), f.read(n - 1)
    if t == b"o": sys.stdout.buffer.write(b)
    elif t == b"r": sys.stderr.buffer.write(b)
    elif t == b"q": sys.exit(struct.unpack(">I", b)[0])
    elif t == b"f": sys.exit("failed: " + b.decode())
