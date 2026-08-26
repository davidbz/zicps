#!/bin/bash
#
# Fetches nukeykt's Nuked-OPM, the reference the YM2151 core is diffed against.
# It lands in testdata/, which is gitignored: this is a
# test-only dependency and never part of the emulator.
#
# The commit is pinned and every file is checksummed, so what the diff runs
# against is the same code the deviation table was measured on.
# Nothing here is required for a fresh checkout to be green — `zig build test`
# skips the differential step when testdata/ is absent.

set -euo pipefail

commit=f209e6ed3712032b641d53ce8fb24824eae6adc3
base=https://raw.githubusercontent.com/nukeykt/Nuked-OPM/$commit
into=$(cd "$(dirname "$0")/.." && pwd)/testdata/Nuked-OPM

# macOS has no sha256sum and Git Bash on Windows does, so ask for whichever
# is here rather than assuming coreutils.
digest() {
    if command -v sha256sum > /dev/null; then
        sha256sum "$1" | cut -d " " -f 1
    else
        shasum -a 256 "$1" | cut -d " " -f 1
    fi
}

sums="\
983beecc471aebd8884fcc3aa48c50b1a26d4280ddbf1025b5196b540cf24188  opm.c
186e042d1cd80c8fdf2e1a07d7c123bbe9a0d42e39518c50889db140a9ec4c39  opm.h
20c17d8b8c48a600800dfd14f95d5cb9ff47066a9641ddeab48dc54aec96e331  LICENSE"

mkdir -p "$into"
while read -r sum name; do
    echo "fetching $name"
    curl -fsSL "$base/$name" -o "$into/$name.part"
    if [ "$(digest "$into/$name.part")" != "$sum" ]; then
        rm -f "$into/$name.part"
        echo "checksum mismatch on $name: refusing it" >&2
        exit 1
    fi
    mv "$into/$name.part" "$into/$name"
done <<< "$sums"

echo
echo "Nuked-OPM $commit is in $into"
echo "run: zig build opm-ref"
