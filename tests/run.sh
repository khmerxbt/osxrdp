#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output=$(mktemp -d "${TMPDIR:-/tmp}/osxrdp-tests.XXXXXX")
trap 'rm -rf "$output"' EXIT HUP INT TERM
cd "$root"
"${CC:-clang}" -g -fsanitize=address,undefined -fno-omit-frame-pointer tests/test_display_control_fragments.c -o "$output/display-control"
"$output/display-control"
"${CXX:-clang++}" -std=c++17 -g -fsanitize=address,undefined -fno-omit-frame-pointer -I. tests/test_rdp_audio.cpp -o "$output/audio"
"$output/audio"
if [ "$#" -gt 0 ]; then
    products=$(CDPATH= cd -- "$1" && pwd)
    export DYLD_LIBRARY_PATH="$products${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    for name in test_rfx_tiles test_audio_channel test_resize; do
        "${CXX:-clang++}" -std=c++17 -I. -IScreenMirrorLib "tests/$name.cpp" -L"$products" -losxup -o "$output/$name"
        "$output/$name"
    done
fi
