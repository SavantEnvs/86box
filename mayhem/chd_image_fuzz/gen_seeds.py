#!/usr/bin/env python3
"""Regenerate the seeds in testsuite/ for chd_image_fuzz (chdman is not available in the build image).

Reuses the CHD v5 builder from ../chdr_fuzz/gen_seeds.py. The fixtures are small zlib-compressed CD and
DVD images carrying the CHT2 track metadata (or the DVD tag) that src/cdrom/cdrom_chd.c parses. They are
also the known-answer fixtures of mayhem/kat/chd_image_kat.c: gen_expected_image.py derives the expected
output from the `tracks`/`hunks` below, so changing them means regenerating kat/expected_image.txt.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("chdr_gen_seeds", os.path.join(HERE, "..", "chdr_fuzz", "gen_seeds.py"))
_chdr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_chdr)
build_v5, pattern = _chdr.build_v5, _chdr.pattern

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "testsuite")
FRAME = 2448  # one raw CD frame: 2352 sector bytes + 96 subcode bytes


def cd_hunks(n, kind):
    """n one-frame hunks. 'data' frames look like MODE1 raw sectors (sync, header, 2048 bytes, EDC/ECC pad)."""
    out = []
    for lba in range(n):
        body = pattern(lba, 2048, "text")
        if kind == "audio":
            sector = pattern(lba, 2352, "bin")
        else:
            sector = b"\0" + b"\xff" * 10 + b"\0" + bytes([0, 2, lba % 75, 1]) + body + b"\0" * 288
        out.append(sector + b"\0" * 96)
    return out


def track(num, typ, sub, frames, pregap, pgtype, pgsub, postgap=0):
    return dict(num=num, type=typ, sub=sub, frames=frames, pregap=pregap, pgtype=pgtype, pgsub=pgsub,
                postgap=postgap)


def cht2(t):
    return (b"CHT2", ("TRACK:%d TYPE:%s SUBTYPE:%s FRAMES:%d PREGAP:%d PGTYPE:%s PGSUB:%s POSTGAP:%d\0" % (
        t["num"], t["type"], t["sub"], t["frames"], t["pregap"], t["pgtype"], t["pgsub"], t["postgap"])).encode())


def fixtures():
    """List of dicts: name, blob, hunks (decompressed), hunkbytes, tracks (None for DVD)."""
    data1 = track(1, "MODE1_RAW", "NONE", 4, 0, "MODE1", "NONE")
    audio_pg = track(2, "AUDIO", "NONE", 4, 150, "VAUDIO", "NONE")
    audio_rw = track(2, "AUDIO", "RW", 4, 0, "AUDIO", "RW_RAW")
    audio1 = track(1, "AUDIO", "NONE", 4, 0, "AUDIO", "NONE")
    mode2 = track(1, "MODE2_RAW", "NONE", 4, 0, "MODE2_RAW", "NONE")
    mode1_2048 = track(1, "MODE1/2048", "NONE", 4, 0, "MODE1", "NONE")
    specs = [
        ("cd_audio_only.chd", [audio1], cd_hunks(4, "audio"), True),
        ("cd_data_audio.chd", [data1, audio_pg], cd_hunks(4, "data") + cd_hunks(4, "audio"), True),
        ("cd_audio_rw.chd", [data1, audio_rw], cd_hunks(4, "data") + cd_hunks(4, "audio"), True),
        ("cd_mode2.chd", [mode2], cd_hunks(4, "data"), True),
        ("cd_mode1_2048.chd", [mode1_2048], cd_hunks(4, "data"), True),
        ("cd_raw_hunks.chd", [track(1, "MODE1_RAW", "NONE", 2, 0, "MODE1", "NONE")], cd_hunks(2, "data"), False),
    ]
    out = []
    for name, tracks, hunks, compress in specs:
        blob = build_v5(hunks, FRAME, FRAME, [cht2(t) for t in tracks], b"zlib" if compress else None, True)
        out.append(dict(name=name, blob=blob, hunks=hunks, hunkbytes=FRAME, tracks=tracks))
    dvd = [pattern(i, 4096, "text") for i in range(4)]
    out.append(dict(name="dvd.chd", blob=build_v5(dvd, 4096, 2048, [(b"DVD ", b"\0")], b"zlib", True),
                    hunks=dvd, hunkbytes=4096, tracks=None))
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in fixtures():
        with open(os.path.join(OUT, f["name"]), "wb") as fh:
            fh.write(f["blob"])
        print(f["name"], len(f["blob"]))


if __name__ == "__main__":
    main()
