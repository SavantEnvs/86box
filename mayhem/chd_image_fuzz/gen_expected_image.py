#!/usr/bin/env python3
"""Derive mayhem/kat/expected_image.txt: what an emulated CD-ROM drive must see for each fixture of
gen_seeds.py, computed from the fixtures' track tables and byte patterns with no 86Box or libchdr code.

Usage: gen_expected_image.py > ../kat/expected_image.txt
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.argv = sys.argv[:1]
from gen_seeds import fixtures  # noqa: E402

MODE2 = ("MODE2", "MODE2/2336", "MODE2_FORM1", "MODE2/2048", "MODE2_FORM2", "MODE2/2324", "MODE2_FORM_MIX",
         "MODE2_RAW", "MODE2/2352", "CDI/2352")


def fnv1a(b):
    h = 2166136261
    for x in b:
        h = ((h ^ x) * 16777619) & 0xFFFFFFFF
    return h


def msf(lba):
    pos = lba + 150
    return pos // 75 // 60, pos // 75 % 60, pos % 75


def bcd(v):
    return ((v // 10) << 4) | (v % 10)


def raw_sector(trk, frame, lba):
    """The first 2352 bytes the drive hands the guest for a sector of `trk` stored in CHD frame `frame`."""
    typ = trk["type"]
    if typ == "AUDIO":  # CHD stores audio big-endian; the drive wants little-endian 16-bit samples
        s = bytearray(frame[:2352])
        for i in range(0, 2352, 2):
            s[i], s[i + 1] = s[i + 1], s[i]
        return bytes(s)
    if typ in ("MODE1_RAW", "MODE2_RAW"):
        return frame[:2352]
    assert typ == "MODE1/2048", typ
    m, s, f = msf(lba)
    return b"\0" + b"\xff" * 10 + b"\0" + bytes([bcd(m), bcd(s), bcd(f), 1]) + frame[:2048]


def expected(fx):
    lines = []
    tr = fx["tracks"]
    hunks = fx["hunks"]
    if tr is None:  # DVD: one data track spanning every 2048-byte unit
        units = sum(len(h) for h in hunks) // 2048
        last = units - 1
        entries = [dict(point=1, adr=0x14, lba=0, audio=False, mode2=False)]
        end = last
    else:
        entries, off = [], 0
        for i, t in enumerate(tr):
            start = off
            off += t["frames"] + t["postgap"]
            if not t["pgtype"].startswith("V"):
                off += t["pregap"]
            audio = t["type"] == "AUDIO"
            entries.append(dict(point=t["num"], adr=0x10 if audio else 0x14, audio=audio,
                                lba=start + (t["pregap"] if i else 0), start=start, t=t,
                                mode2=t["type"] in MODE2))
        end = off - 1
        last = end
    any_mode2 = any(e["mode2"] for e in entries)
    has_audio = any(e["audio"] for e in entries)
    has_data = any(not e["audio"] for e in entries)
    lines.append("IMAGE %s: last_block=%d is_dvd=%d has_audio=%d has_data=%d" % (
        fx["name"], last, 1 if tr is None else 0, has_audio, has_data))
    first, lastn = min(e["point"] for e in entries), max(e["point"] for e in entries)
    toc = [(0x14, 0xA0, (first, 0x20 if any_mode2 else 0, 0)), (0x10, 0xA1, (lastn, 0, 0)),
           (0x10, 0xA2, msf(end + 1))]
    toc += [(e["adr"], e["point"], msf(e["lba"])) for e in entries]
    for i, (adr, point, m) in enumerate(toc):
        lines.append("toc %d: adr_ctl=%02x point=%02x pmsf=%02d:%02d:%02d" % ((i, adr, point) + m))
    for e in entries:
        lines.append("track %d: attr=%02x msf=%02d:%02d:%02d" % ((e["point"], e["adr"]) + msf(e["lba"])))
    # Sectors 0..3 sit in the first track, whose frames start at the beginning of the CHD data.
    for lba in range(min(last, 3) + 1):
        if tr is None:
            data = b"".join(hunks)[lba * 2048:(lba + 1) * 2048]
            m, s, f = msf(lba)
            sec = b"\0" + b"\xff" * 10 + b"\0" + bytes([bcd(m), bcd(s), bcd(f), 1]) + data
            typ, ln = 0x00, 2064
        else:
            e = entries[0]
            sec = raw_sector(e["t"], hunks[lba], lba)
            typ = 0x08 if e["audio"] else (0x20 if any_mode2 else 0x00)
            ln = 2352 if e["audio"] else 2064
        lines.append("sector %d: type=%02x ret=1 len=%d fnv=%08x" % (lba, typ, ln, fnv1a(sec[:ln])))
    return lines


for fx in sorted(fixtures(), key=lambda f: f["name"]):
    print("\n".join(expected(fx)))
