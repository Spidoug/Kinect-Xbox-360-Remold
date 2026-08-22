#!/usr/bin/env python3
"""Conservative reference-firmware analyzer for clean-room work.

It never patches or redistributes firmware. It reports entropy, ASCII/UTF-16
strings, candidate ARM branch density, and uploader-known load/entry addresses.
The goal is to build a hardware map from observations rather than guessed MMIO.
"""
from __future__ import annotations
import argparse, collections, hashlib, json, math, pathlib, re, struct


def entropy(data: bytes) -> float:
    c = collections.Counter(data)
    n = len(data)
    return -sum((v/n) * math.log2(v/n) for v in c.values()) if n else 0.0


def ascii_strings(data: bytes, min_len: int = 6):
    pat = rb"[\x20-\x7e]{%d,}" % min_len
    return [(m.start(), m.group().decode('ascii', 'replace')) for m in re.finditer(pat, data)]


def utf16le_strings(data: bytes, min_chars: int = 6):
    out=[]
    pat = re.compile((rb"(?:[\x20-\x7e]\x00){%d,}" % min_chars))
    for m in pat.finditer(data):
        out.append((m.start(), m.group().decode('utf-16le','replace')))
    return out


def arm_word_stats(data: bytes):
    words = len(data)//4
    arm_branch=0
    arm_dp=0
    for i in range(words):
        w=struct.unpack_from('<I', data, i*4)[0]
        if (w & 0x0E000000)==0x0A000000: arm_branch += 1
        if (w & 0x0C000000)==0x00000000: arm_dp += 1
    return {
        'word_count': words,
        'arm_branch_like_ratio': arm_branch/words if words else 0,
        'arm_data_processing_like_ratio': arm_dp/words if words else 0,
    }


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('input', type=pathlib.Path)
    ap.add_argument('--json', type=pathlib.Path)
    args=ap.parse_args()
    data=args.input.read_bytes()
    report={
        'file': str(args.input),
        'bytes': len(data),
        'sha256': hashlib.sha256(data).hexdigest(),
        'entropy_bits_per_byte': entropy(data),
        'known_upload_load_address': '0x00080000',
        'known_uac_entry_address': '0x00080030',
        'architecture_heuristics': arm_word_stats(data),
        'ascii_strings': ascii_strings(data)[:200],
        'utf16le_strings': utf16le_strings(data)[:200],
    }
    text=json.dumps(report, indent=2, ensure_ascii=False)
    print(text)
    if args.json: args.json.write_text(text+'\n', encoding='utf-8')

if __name__=='__main__': main()
