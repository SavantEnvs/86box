#!/usr/bin/env python3
"""Regenerate the tiny CHD seeds in testsuite/ (chdman is not available in the build image).

The same files double as known-answer fixtures for mayhem/kat/chd_kat.c, so the byte patterns
below are part of the oracle: changing them requires regenerating mayhem/kat/expected.txt.
"""
import hashlib
import os
import struct
import sys
import zlib

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "testsuite")


def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def pattern(hunk, n, kind):
    if kind == "text":
        base = (b"86Box CHD seed hunk %03d. " % hunk)
        return (base * (n // len(base) + 1))[:n]
    return bytes(((hunk * 131 + j * 7 + (j >> 8)) & 0xFF) for j in range(n))


def meta_chain(entries, first_offset):
    blob, off = b"", first_offset
    for i, (tag, data) in enumerate(entries):
        nxt = off + 16 + len(data) if i + 1 < len(entries) else 0
        blob += tag + struct.pack(">I", len(data) | (0x01 << 24)) + struct.pack(">Q", nxt) + data
        off += 16 + len(data)
    return blob


class Bits:
    def __init__(self):
        self.v, self.n = 0, 0

    def put(self, value, nbits):
        self.v = (self.v << nbits) | (value & ((1 << nbits) - 1))
        self.n += nbits

    def bytes(self):
        pad = (-self.n) % 8
        return (self.v << pad).to_bytes((self.n + pad) // 8, "big")


def v5_header(comp, logical, mapoff, metaoff, hunkbytes, unitbytes, rawsha1):
    tags = b"".join((c if c else b"\0\0\0\0") for c in (list(comp) + [None] * 4)[:4])
    return (b"MComprHD" + struct.pack(">II", 124, 5) + tags +
            struct.pack(">QQQII", logical, mapoff, metaoff, hunkbytes, unitbytes) +
            rawsha1 + rawsha1 + b"\0" * 20)


def build_v5(hunks, hunkbytes, unitbytes, meta, codec=None):
    raw = b"".join(hunks)
    sha = hashlib.sha1(raw).digest()
    n = len(hunks)
    if codec is None:
        mapoff = 124
        first = -(-(mapoff + 4 * n) // hunkbytes)
        mapblob = b"".join(struct.pack(">I", first + i) for i in range(n))
        pad = first * hunkbytes - (mapoff + len(mapblob))
        data = raw
        metaoff = first * hunkbytes + len(data)
        body = mapblob + b"\0" * pad + data
    else:
        # zlib codec; odd hunks are stored uncompressed (map type 4) to cover both paths
        blobs, types = [], []
        for i, h in enumerate(hunks):
            c = zlib.compressobj(9, zlib.DEFLATED, -15)
            z = c.compress(h) + c.flush()
            if i % 2 == 0 and len(z) < len(h):
                blobs.append(z); types.append(0)
            else:
                blobs.append(h); types.append(4)
        lengthbits = 16
        bits = Bits()
        for _ in range(16):
            bits.put(4, 4)          # 16 codes, each 4 bits long -> canonical code == value
        for t in types:
            bits.put(t, 4)
        for i, t in enumerate(types):
            if t == 0:
                bits.put(len(blobs[i]), lengthbits)
            bits.put(crc16(hunks[i]), 16)
        # CRC covers the expanded 12-byte entries, with the real file offsets filled in below
        mapoff = 124
        packed = bits.bytes()
        first = mapoff + 16 + len(packed)
        exp = bytearray()
        cur = first
        for i, t in enumerate(types):
            ln = len(blobs[i])
            exp += bytes([t]) + (ln).to_bytes(3, "big") + cur.to_bytes(6, "big") + crc16(hunks[i]).to_bytes(2, "big")
            cur += ln
        maphdr = struct.pack(">I", len(packed)) + first.to_bytes(6, "big") + struct.pack(">H", crc16(bytes(exp))) + bytes([lengthbits, 0, 0, 0])
        body = maphdr + packed + b"".join(blobs)
        metaoff = mapoff + len(body)
    mblob = meta_chain(meta, metaoff) if meta else b""
    if not meta:
        metaoff = 0
    comp = [codec] if codec else []
    hdr = v5_header(comp, len(raw), mapoff, metaoff, hunkbytes, unitbytes, sha)
    return hdr + body + mblob


def build_v4_raw(hunks, hunkbytes, meta):
    raw = b"".join(hunks)
    sha = hashlib.sha1(raw).digest()
    n = len(hunks)
    mapsize = 16 * n + 16
    datastart = 108 + mapsize
    mapblob = b""
    for i, h in enumerate(hunks):
        mapblob += struct.pack(">Q", datastart + i * hunkbytes) + struct.pack(">I", zlib.crc32(h) & 0xFFFFFFFF)
        mapblob += struct.pack(">H", hunkbytes & 0xFFFF) + bytes([hunkbytes >> 16, 2])
    mapblob += b"EndOfListCookie\0"
    metaoff = datastart + len(raw)
    mblob = meta_chain(meta, metaoff) if meta else b""
    hdr = (b"MComprHD" + struct.pack(">IIII", 108, 4, 0, 0) + struct.pack(">I", n) +
           struct.pack(">QQI", len(raw), metaoff if meta else 0, hunkbytes) + sha + b"\0" * 20 + sha)
    return hdr + mapblob + raw + mblob


def main():
    os.makedirs(OUT, exist_ok=True)
    hd_meta = [(b"GDDD", b"CYLS:2,HEADS:2,SECS:2,BPS:512\0")]
    cd_meta = [(b"CHT2", b"TRACK:1 TYPE:MODE1_RAW SUBTYPE:NONE FRAMES:1 PREGAP:0 PGTYPE:MODE1 PGSUB:NONE POSTGAP:0\0")]
    hd = [pattern(i, 512, "bin") for i in range(8)]
    txt = [pattern(i, 512, "text") for i in range(8)]
    cd = [pattern(0, 2448, "bin")]
    files = {
        "v5_none_hd.chd": build_v5(hd, 512, 512, hd_meta),
        "v5_zlib_text.chd": build_v5(txt, 512, 512, hd_meta, b"zlib"),
        "v5_none_cd.chd": build_v5(cd, 2448, 2448, cd_meta),
        "v4_none_hd.chd": build_v4_raw(hd, 512, hd_meta),
    }
    for name, blob in files.items():
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(blob)
        print(name, len(blob))


main()
