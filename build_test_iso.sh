#!/bin/bash
# build_test_iso.sh — Build a test ISO that boots directly to E1M1 (no menus)
#
# Usage:
#   ./build_test_iso.sh           # builds test ISO → /tmp/optidoom_test.iso
#   ./build_test_iso.sh --normal  # builds normal ISO (with menus) → /tmp/optidoom_test.iso
#
# Uses binary-patch approach: injects new LaunchMe directly into original ISO
# at sector 1183, preserving all original signatures/boot_code validation.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/optidoom3do/source"
BASE_ISO="$SCRIPT_DIR/optidoom3do/optidoom.iso"
OUT_ISO="/tmp/optidoom_test.iso"
LAUNCHME_SECTOR=1183  # confirmed: launchme lives at sector 1183 in the base ISO

source ~/3do-dev/3do-devkit/activate-env

BASE_CFLAGS="-O1 -bigend -za1 -zi4 -fpu none -arch 3 -apcs 3/32/nofp"

if [[ "$1" == "--normal" ]]; then
    echo "==> Building NORMAL ISO (with menus)"
    EXTRA=
else
    echo "==> Building TEST ISO (DEBUG_SKIP_MENU — boots directly to E1M1)"
    EXTRA="-DDEBUG_SKIP_MENU"
fi

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

with open(NEW_LAUNCHME, 'rb') as f:
    new_lm = f.read()
new_lm_sectors = math.ceil(len(new_lm) / 2048)
print(f'  LaunchMe: {len(new_lm)} bytes = {new_lm_sectors} sectors')

# Copy base ISO
shutil.copy2(BASE_ISO, OUT_ISO)

with open(OUT_ISO, 'r+b') as f:
    # Write LaunchMe (zero-padded to sector boundary)
    lm_padded = new_lm + b'\x00' * (new_lm_sectors * 2048 - len(new_lm))
    f.seek(LAUNCHME_SECTOR * 2048)
    f.write(lm_padded)

    # Update BLOCKS_ALWAYS in ROM tags to use new sector count
    f.seek(0x800)
    tags = bytearray(f.read(192))
    for i in range(0, 192, 32):
        if tags[i] == 0x0f and tags[i+1] == 0x02:
            old_sz = struct.unpack('>I', tags[i+12:i+16])[0]
            struct.pack_into('>I', tags, i+12, new_lm_sectors)
            print(f'  BLOCKS_ALWAYS: sector=1183 (unchanged), size {old_sz}->{new_lm_sectors} sectors')
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
echo "    Use ralph_wiggum.sh to test"
