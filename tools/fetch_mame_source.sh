#!/bin/bash
#
# Fetches the MAME files the board generator and the CPS-2 research read.
# They land in testdata/, which is gitignored: MAME's driver is not part of
# this emulator and is never linked into it. What ships is boards/, which is
# committed — running this is only needed to rewrite that.
#
# The release is pinned and every file is checksummed, because the board files
# in the repo are a transcription of exactly this revision of these tables and
# a diff after regenerating should be a real change to them, not a drive-by
# edit somewhere upstream.

set -euo pipefail

commit=f34f02505e32c1993c6a782b6814232cbfc74e36 # mame0289
base=https://raw.githubusercontent.com/mamedev/mame/$commit
into=$(cd "$(dirname "$0")/.." && pwd)/testdata/mame

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
4605223d48fbaa720e0b619ea0d761b8e2856d383d8cb33949b96a5125762c99  src/mame/capcom/cps1.cpp
f899193fb52dd715bf98f056472dc2cb88bdd79eebf6de70de1d43f61cb23115  src/mame/capcom/cps1_v.cpp
620f5f1eafe31cef8abeca54d03dba6fbcfa6bb903d900920b4bd158e9947a6a  src/mame/capcom/kabuki.cpp
a8c09ef83841d75b81a4b2ee8ac029ebf8eecb6a743b016abb33e3d46e861602  src/mame/capcom/cps2.cpp
c0f9ef55059fc48c5507a5f0ab1122826b44c98210adfe197e9b356d86a9a5e5  src/mame/capcom/cps2crypt.cpp
60e9b2e1e0832d74696a9a0317693bb6cbe317747caad589a338e2c7636933e4  COPYING"

mkdir -p "$into"
while read -r sum path; do
    name=$(basename "$path")
    echo "fetching $name"
    curl -fsSL "$base/$path" -o "$into/$name.part"
    if [ "$(digest "$into/$name.part")" != "$sum" ]; then
        rm -f "$into/$name.part"
        echo "checksum mismatch on $name: refusing it" >&2
        exit 1
    fi
    mv "$into/$name.part" "$into/$name"
done <<< "$sums"

echo
echo "MAME $commit is in $into"
echo "run: zig build boards -- testdata/mame"
