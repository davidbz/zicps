#!/bin/bash
#
# Fetches ctr's qsound-hle, the reference the QSound core is diffed against
# (DESIGN.md §9 M4). It lands in testdata/, which is gitignored: this is a
# test-only dependency and never part of the emulator.
#
# The commit is pinned and every file is checksummed, so what the diff runs
# against is the same code the deviation table in DESIGN.md was measured on.
# Nothing here is required for a fresh checkout to be green — `zig build test`
# skips the differential step when testdata/ is absent.

set -euo pipefail

commit=68e63be325ddce6288adc3f571a4647f634046fb
base=https://raw.githubusercontent.com/ValleyBell/qsound-hle/$commit
into=$(cd "$(dirname "$0")/.." && pwd)/testdata/qsound-hle

sums="\
d3f60b342cdedad77f9d50fc40e0aadd364e5130cd0ed2ded9964974a38fec2e  qsound.c
ebd8b6b54b464d61eae9cc3b144b502713ce4255369134ae3c044d64c4a3af56  qsound.h
08e10c0dad9aea0ca411015741e5d7cd6e7bf37d27ba19d7aff91860b69af0c6  LICENSE"

mkdir -p "$into"
while read -r sum name; do
    echo "fetching $name"
    curl -fsSL "$base/$name" -o "$into/$name.part"
    echo "$sum  $into/$name.part" | sha256sum --check --status || {
        rm -f "$into/$name.part"
        echo "checksum mismatch on $name: refusing it" >&2
        exit 1
    }
    mv "$into/$name.part" "$into/$name"
done <<< "$sums"

echo
echo "qsound-hle $commit is in $into"
echo "run: zig build qsound-ref"
