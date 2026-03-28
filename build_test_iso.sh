#!/bin/bash
# build_test_iso.sh — Build an optidoom ISO (legacy; use ./build.sh instead)
#
# Usage:
#   ./build_test_iso.sh             # test ISO: boots to E1M1, music enabled
#   ./build_test_iso.sh --normal    # normal ISO: shows mod menu, music enabled
#   ./build_test_iso.sh --no-music  # test ISO: boots to E1M1, no music (offline)
#
# Binary-patch approach: patches new LaunchMe + v24 OS components into base ISO.
#
# Required files (not in repo — see README.md):
#   iso/optidoom.iso        — original Doom 3DO disc
#   iso/v24_base.iso        — v24 OS donor (built automatically by setup.sh / build.sh)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/optidoom3do/source"
BASE_ISO="$SCRIPT_DIR/iso/optidoom.iso"
V24_ISO="$SCRIPT_DIR/iso/v24_base.iso"
OUT_ISO="/tmp/optidoom_test.iso"
LAUNCHME_SECTOR=1183  # confirmed: launchme lives at sector 1183 in the base ISO

# Verify v24 donor ISO exists (built by setup.sh / build.sh --setup)
if [[ ! -f "$V24_ISO" ]]; then
    echo "ERROR: $V24_ISO not found. Run ./build.sh --setup first."
    exit 1
fi

set +e; source ~/3do-dev/3do-devkit/activate-env; set -e

BASE_CFLAGS="-O1 -bigend -za1 -zi4 -fpu none -arch 3 -apcs 3/32/nofp"

if [[ "$1" == "--normal" ]]; then
    echo "==> Building NORMAL ISO (with menus, music enabled)"
    EXTRA="-DENABLE_MUSIC"
elif [[ "$1" == "--no-music" ]]; then
    echo "==> Building TEST ISO (DEBUG_SKIP_MENU, no music)"
    EXTRA="-DDEBUG_SKIP_MENU"
else
    echo "==> Building TEST ISO (DEBUG_SKIP_MENU, music enabled)"
    EXTRA="-DDEBUG_SKIP_MENU -DENABLE_MUSIC"
fi

# Copy internal libs to /tmp for Makefile INTERNAL_LIBS path
echo "==> Staging internal libs..."
mkdir -p /tmp/optidoom-libs
cp "$SCRIPT_DIR/optidoom3do/lib/burger/burger.lib"   /tmp/optidoom-libs/
cp "$SCRIPT_DIR/optidoom3do/lib/intmath/intmath.lib" /tmp/optidoom-libs/
cp "$SCRIPT_DIR/optidoom3do/lib/string/string.lib"   /tmp/optidoom-libs/

echo "==> Compiling..."
cd "$SOURCE_DIR"
make clean
make CFLAGS="$BASE_CFLAGS $EXTRA"

LAUNCHME="$SOURCE_DIR/../takeme/LaunchMe"
LAUNCHME_SIZE=$(stat -c%s "$LAUNCHME")
echo "==> LaunchMe: $LAUNCHME_SIZE bytes"

echo "==> Binary-patching LaunchMe into base ISO..."
python3 - <<EOF
import struct, math, shutil

BASE_ISO = '$BASE_ISO'
NEW_LAUNCHME = '$LAUNCHME'
OUT_ISO = '$OUT_ISO'
LAUNCHME_SECTOR = $LAUNCHME_SECTOR
HELLO_ISO = '$V24_ISO'

with open(NEW_LAUNCHME, 'rb') as f:
    new_lm = f.read()
new_lm_sectors = math.ceil(len(new_lm) / 2048)
print(f'  LaunchMe: {len(new_lm)} bytes = {new_lm_sectors} sectors')

# Read v24 OS components from hello_world
with open(HELLO_ISO, 'rb') as hf:
    hf.seek(4 * 2048);   hello_sector4  = hf.read(2048)       # boot validator
    hf.seek(1 * 2048);   hello_bootcode = hf.read(3 * 2048)  # boot code (3 sectors)
    hf.seek(5 * 2048);   hello_kernel   = hf.read(57 * 2048) # OS kernel v24 (115520 bytes)
print(f'  OS donor: {HELLO_ISO}')

# Copy base ISO
shutil.copy2(BASE_ISO, OUT_ISO)

with open(OUT_ISO, 'r+b') as f:
    # Patch sector 4 (boot validator) — original optidoom sector 4 fails BIOS check
    f.seek(4 * 2048);   f.write(hello_sector4)
    print(f'  Patched sector 4 (permissive boot validator)')
    f.seek(1 * 2048);   f.write(hello_bootcode)
    print(f'  Replaced boot code (sectors 1-3, v24)')
    f.seek(5 * 2048);   f.write(hello_kernel)
    print(f'  Replaced OS kernel (sectors 5-61, v24)')

    # Write LaunchMe (zero-padded to sector boundary)
    lm_padded = new_lm + b'\x00' * (new_lm_sectors * 2048 - len(new_lm))
    f.seek(LAUNCHME_SECTOR * 2048)
    f.write(lm_padded)

    # Update BLOCKS_ALWAYS in ROM tags to use new sector count
    f.seek(0x800)
    tags = bytearray(f.read(192))
    for i in range(0, 192, 32):
        if tags[i] == 0x0f and tags[i+1] == 0x02:
            old_loc = struct.unpack('>I', tags[i+8:i+12])[0]
            old_sz  = struct.unpack('>I', tags[i+12:i+16])[0]
            struct.pack_into('>I', tags, i+8,  LAUNCHME_SECTOR)   # loc: always sector 1183
            struct.pack_into('>I', tags, i+12, new_lm_sectors)    # size: new sector count
            print(f'  BLOCKS_ALWAYS: loc {old_loc}->{LAUNCHME_SECTOR}, size {old_sz}->{new_lm_sectors} sectors')
    f.seek(0x800)
    f.write(bytes(tags))

    # Verify
    f.seek(LAUNCHME_SECTOR * 2048)
    hdr = f.read(4)
    if hdr == b'\xe1\xa0\x00\x00':
        print('  AIF header verified at sector 1183')
    else:
        print(f'  WARNING: unexpected header {hdr.hex()}')

print(f'  Done: {OUT_ISO}')
EOF

echo ""
echo "==> Done: $OUT_ISO"
echo "    Run: retroarch -L ~/.config/retroarch/cores/opera_libretro.so $OUT_ISO"
