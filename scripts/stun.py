"""Minimal STUN binding client: the public (mapped) address each server sees for us over UDP.

Resolution uses the system resolver, as a browser's WebRTC stack would.
Usage: python3 -I stun.py [--json] [host:port ...]
"""
import json
import os
import socket
import struct
import sys

DEFAULT = [
    "stun.l.google.com:19302",
    "stun.cloudflare.com:3478",
    "global.stun.twilio.com:3478",
    "stun.nextcloud.com:443",
]
MAGIC = 0x2112A442


def query(host, port, timeout=3.0):
    try:
        ip = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_DGRAM)[0][4][0]
    except OSError as e:
        return None, None, f"resolve failed: {e}"
    req = struct.pack("!HHI12s", 0x0001, 0, MAGIC, os.urandom(12))
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    data = None
    try:
        for _ in range(2):
            s.sendto(req, (ip, port))
            try:
                data, _ = s.recvfrom(2048)
                break
            except socket.timeout:
                pass
    finally:
        s.close()
    if not data:
        return ip, None, "timeout (UDP blocked/dropped)"
    pos = 20
    while pos + 4 <= len(data):
        atype, alen = struct.unpack("!HH", data[pos:pos + 4])
        val = data[pos + 4:pos + 4 + alen]
        if atype in (0x0020, 0x0001) and len(val) >= 8 and val[1] == 0x01:
            p = struct.unpack("!H", val[2:4])[0]
            a = struct.unpack("!I", val[4:8])[0]
            if atype == 0x0020:
                p ^= MAGIC >> 16
                a ^= MAGIC
            return ip, socket.inet_ntoa(struct.pack("!I", a)), f"port {p}"
        pos += 4 + alen + ((4 - alen % 4) % 4)
    return ip, None, "no mapped address"


args = sys.argv[1:]
as_json = "--json" in args
targets = [a for a in args if a != "--json"] or DEFAULT
results = []
for t in targets:
    h, p = t.rsplit(":", 1)
    dst, mapped, note = query(h, int(p))
    results.append({"server": t, "dst": dst, "mapped": mapped, "note": note})
if as_json:
    print(json.dumps(results))
else:
    for r in results:
        print(f"{r['server']:32} -> dst {r['dst']}: {r['mapped'] or ''} {r['note']}")
