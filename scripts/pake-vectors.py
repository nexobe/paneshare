#!/usr/bin/env python3
"""Independent check of the pairing exchange in docs/ARCHITECTURE.md §4.2.

Written from the spec and the RFCs, not from the Swift code: RFC 7748 (X25519 ladder),
RFC 9380 §6.7.1 (Elligator 2 for Curve25519, Z = 2), RFC 5869 (HKDF) and RFC 2104 (HMAC).
It prints the fixed vectors that Tests/PaneshareCoreTests/PairingTests.swift expects.

Usage: python3 scripts/pake-vectors.py [label]   (default label: paneshare-pake-v1)
"""
import hashlib
import hmac
import sys

P = 2**255 - 19
A = 486662


def lv(b: bytes) -> bytes:
    return len(b).to_bytes(2, "big") + b


def is_square(x: int) -> bool:
    return x % P == 0 or pow(x, (P - 1) // 2, P) == 1


def elligator2(u: int) -> int:
    """RFC 9380 §6.7.1 with J = A, K = 1, Z = 2; returns the Montgomery u-coordinate."""
    tv = (1 + 2 * u * u) % P
    x1 = (-A * pow(tv, P - 2, P)) % P  # inv0(0) = 0
    if x1 == 0:
        x1 = -A % P
    gx1 = (x1 * x1 * x1 + A * x1 * x1 + x1) % P
    return x1 if is_square(gx1) else (-x1 - A) % P


def x25519(k: bytes, u: bytes) -> bytes:
    """RFC 7748 §5."""
    k = bytearray(k)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    scalar = int.from_bytes(k, "little")
    x1 = int.from_bytes(u, "little") & ((1 << 255) - 1)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in reversed(range(255)):
        bit = (scalar >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a, b = (x2 + z2) % P, (x2 - z2) % P
        aa, bb = a * a % P, b * b % P
        e = (aa - bb) % P
        c, d = (x3 + z3) % P, (x3 - z3) % P
        da, cb = d * a % P, c * b % P
        x3 = (da + cb) ** 2 % P
        z3 = x1 * (da - cb) ** 2 % P
        x2 = aa * bb % P
        z2 = e * (aa + 121665 * e) % P
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")


def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, block = b"", b""
    for i in range(1, -(-length // 32) + 1):
        block = hmac.new(prk, block + info + bytes([i]), hashlib.sha256).digest()
        out += block
    return out[:length]


def vectors(label: str) -> dict:
    code = b"482913"
    fp_host, fp_viewer = bytes(range(0, 32)), bytes(range(32, 64))
    nonce_v, nonce_h = bytes(range(64, 96)), bytes(range(96, 128))
    channel, session = fp_host + fp_viewer, nonce_v + nonce_h
    digest = hashlib.sha512(lv(label.encode()) + lv(code) + lv(channel) + lv(session)).digest()
    r = int.from_bytes(digest[:32], "little") & ((1 << 255) - 1)
    g = elligator2(r % P).to_bytes(32, "little")
    host_secret = bytes(0xA0 + i % 16 for i in range(32))
    viewer_secret = bytes(0xC0 + i % 16 for i in range(32))
    yh, yv = x25519(host_secret, g), x25519(viewer_secret, g)
    k = x25519(viewer_secret, yh)
    assert k == x25519(host_secret, yv) and any(k)
    transcript = lv(label.encode()) + lv(channel) + lv(session) + lv(yh) + lv(yv)
    keys = hkdf_sha256(k, hashlib.sha256(transcript).digest(), f"{label} confirm".encode(), 64)
    return {
        "generator": g.hex(),
        "hostShare": yh.hex(),
        "viewerShare": yv.hex(),
        "confirmViewer": hmac.new(keys[:32], b"viewer" + transcript, hashlib.sha256).hexdigest(),
        "confirmHost": hmac.new(keys[32:], b"host" + transcript, hashlib.sha256).hexdigest(),
    }


if __name__ == "__main__":
    for name, value in vectors(sys.argv[1] if len(sys.argv) > 1 else "paneshare-pake-v1").items():
        print(f"{name} {value}")
