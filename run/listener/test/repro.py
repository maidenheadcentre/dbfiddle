#!/usr/bin/env python3
"""Reproduces the outage: send the CONNECT handshake reply and the first payload bytes
in ONE write, so perl's readline buffers ahead past the "OK" line. sysread then bypasses
that buffer and silently loses everything already in it. The original listener used
buffered <$c> for both, so it never lost anything."""
import os, socket, sys

root, nbytes, together = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "together"
path = os.path.join(root, "v.sock")
if os.path.exists(path):
    os.unlink(path)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(8)
print("READY", flush=True)

payload = b"x" * nbytes
for i in range(4):
    c, _ = srv.accept()
    line = b""
    while not line.endswith(b"\n"):
        b = c.recv(1)
        if not b:
            break
        line += b
    port = line.decode().strip().split()[-1] if line else "?"
    if port == "9002":
        if together:
            c.sendall(b"OK 1234\n" + payload)      # one write - triggers readahead
        else:
            c.sendall(b"OK 1234\n")
            c.sendall(payload)
        c.close()
    else:
        c.sendall(b"OK 1234\n")
        while c.recv(65536):
            pass
        c.close()
srv.close()
os.unlink(path)
