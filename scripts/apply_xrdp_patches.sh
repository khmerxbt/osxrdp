#!/bin/sh
# Apply to a fresh XRDP 0.10.6.1 release tree with bundled librfxcodec sources.
set -eu
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /path/to/fresh/xrdp-0.10.6.1" >&2
    exit 2
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_dir=$(CDPATH= cd -- "$1" && pwd)
# Validate both dependencies before changing either tree.
patch -d "$source_dir" -p1 --dry-run < "$script_dir/xrdp_patch.patch"
patch -d "$source_dir/librfxcodec" -p1 --dry-run < "$script_dir/librfxcodec_neon.patch"
patch -d "$source_dir" -p1 < "$script_dir/xrdp_patch.patch"
patch -d "$source_dir/librfxcodec" -p1 < "$script_dir/librfxcodec_neon.patch"
