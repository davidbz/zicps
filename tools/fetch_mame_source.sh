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
# The CPS-2 keys were in MAME's source until 0.178 moved them into the ROM
# sets, so the one thing 0.289 cannot say is what a dead board's battery held.
# That comes from the last release that still wrote it down.
old_commit=14e7367f7e1dd575754f8c59fcf74b956c91e87b # mame0176
base=https://raw.githubusercontent.com/mamedev/mame
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
4605223d48fbaa720e0b619ea0d761b8e2856d383d8cb33949b96a5125762c99  src/mame/capcom/cps1.cpp                cps1.cpp
f899193fb52dd715bf98f056472dc2cb88bdd79eebf6de70de1d43f61cb23115  src/mame/capcom/cps1_v.cpp              cps1_v.cpp
620f5f1eafe31cef8abeca54d03dba6fbcfa6bb903d900920b4bd158e9947a6a  src/mame/capcom/kabuki.cpp              kabuki.cpp
a8c09ef83841d75b81a4b2ee8ac029ebf8eecb6a743b016abb33e3d46e861602  src/mame/capcom/cps2.cpp                cps2.cpp
c0f9ef55059fc48c5507a5f0ab1122826b44c98210adfe197e9b356d86a9a5e5  src/mame/capcom/cps2crypt.cpp           cps2crypt.cpp
60e9b2e1e0832d74696a9a0317693bb6cbe317747caad589a338e2c7636933e4  COPYING                                 COPYING"

# The 0.176 pair, kept under names of their own: the driver has the same file
# name in both releases and they are not the same file.
old_sums="\
9c25c56ff00078db1b69f0c70d3b364f287becfa437b859fcebc358568457b7b  src/mame/machine/cps2crypt.h            cps2_keys.h
10e9713417c1f4ae49ff9e568e73ba9ba58bbb9110bee4a02e4ccfdc57f384fc  src/mame/drivers/cps2.cpp               cps2_keyed.cpp"

fetch() {
    local at=$1
    while read -r sum path name; do
        echo "fetching $name"
        curl -fsSL "$base/$at/$path" -o "$into/$name.part"
        if [ "$(digest "$into/$name.part")" != "$sum" ]; then
            rm -f "$into/$name.part"
            echo "checksum mismatch on $name: refusing it" >&2
            exit 1
        fi
        mv "$into/$name.part" "$into/$name"
    done
}

mkdir -p "$into"
fetch "$commit" <<< "$sums"
fetch "$old_commit" <<< "$old_sums"

echo
echo "MAME $commit (and $old_commit for the keys) is in $into"
echo "run: zig build boards -- testdata/mame"
