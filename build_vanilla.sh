#!/bin/bash
# build_vanilla.sh — Build vanilla optidoom ISO for benchmarking
#
# Builds Optimus6128's unmodified optidoom3do with profiling enabled,
# using the same ISO patching pipeline as build.sh.
#
# Output: /tmp/optidoom_vanilla.iso
#
# Usage:
#   ./build_vanilla.sh              # boots to E1M1 (DEBUG_SKIP_MENU)
#   ./build_vanilla.sh --normal     # normal build with mod menu

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/vanilla_optidoom/source"
BASE_ISO="$SCRIPT_DIR/iso/optidoom.iso"
V24_ISO="$SCRIPT_DIR/iso/v24_base.iso"
OUT_ISO="/tmp/optidoom_vanilla.iso"
LAUNCHME_SECTOR=1183

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "ERROR: vanilla_optidoom/ not found. Run from the benchmark/vanilla branch."
    exit 1
fi

set +e; source ~/3do-dev/3do-devkit/activate-env; set -e

if [[ ! -f "$BASE_ISO" ]]; then
    echo "ERROR: $BASE_ISO not found."
    exit 1
fi

if [[ ! -f "$V24_ISO" ]]; then
    echo "ERROR: $V24_ISO not found. Run ./build.sh --setup first."
    exit 1
fi

BASE_CFLAGS="-O2 -Otime -bigend -zps1 -za1 -wn -ff -fa -fpu none -arch 3 -apcs 3/32/nofp"

if [[ "$1" == "--normal" ]]; then
    echo "==> Building vanilla NORMAL ISO (mod menu)"
    EXTRA=""
else
    echo "==> Building vanilla TEST ISO (E1M1 auto-boot, profiling enabled)"
    EXTRA="-DDEBUG_SKIP_MENU"
fi

echo "==> Staging internal libs..."
mkdir -p /tmp/vanilla-libs
cp "$SCRIPT_DIR/vanilla_optidoom/lib/burger/burger.lib"   /tmp/vanilla-libs/
cp "$SCRIPT_DIR/vanilla_optidoom/lib/intmath/intmath.lib" /tmp/vanilla-libs/
cp "$SCRIPT_DIR/vanilla_optidoom/lib/string/string.lib"   /tmp/vanilla-libs/

echo "==> Compiling vanilla optidoom..."
cd "$SOURCE_DIR"
make clean
make CFLAGS="$BASE_CFLAGS $EXTRA"

LAUNCHME="$SOURCE_DIR/../takeme/LaunchMe"
LAUNCHME_SIZE=$(stat -c%s "$LAUNCHME")
echo "==> LaunchMe: $LAUNCHME_SIZE bytes"

echo "==> Patching ISO..."
python3 - <<EOF
import struct, math, shutil

BASE_ISO        = '$BASE_ISO'
NEW_LAUNCHME    = '$LAUNCHME'
OUT_ISO         = '$OUT_ISO'
V24_ISO         = '$V24_ISO'
LAUNCHME_SECTOR = $LAUNCHME_SECTOR

with open(NEW_LAUNCHME, 'rb') as f:
    new_lm = f.read()
new_lm_sectors = math.ceil(len(new_lm) / 2048)
print(f'  LaunchMe: {len(new_lm)} bytes = {new_lm_sectors} sectors')

with open(V24_ISO, 'rb') as hf:
    hf.seek(4 * 2048);   v24_sector4   = hf.read(2048)
    hf.seek(1 * 2048);   v24_bootcode  = hf.read(3 * 2048)
    hf.seek(5 * 2048);   v24_kernel    = hf.read(57 * 2048)
    hf.seek(226 * 2048); v24_sector226 = hf.read(76 * 2048)

shutil.copy2(BASE_ISO, OUT_ISO)

with open(OUT_ISO, 'r+b') as f:
    f.seek(4 * 2048);   f.write(v24_sector4)
    f.seek(1 * 2048);   f.write(v24_bootcode)
    f.seek(5 * 2048);   f.write(v24_kernel)
    f.seek(226 * 2048); f.write(v24_sector226)
    print(f'  Patched v24 OS sectors')

    lm_padded = new_lm + b'\\x00' * (new_lm_sectors * 2048 - len(new_lm))
    f.seek(LAUNCHME_SECTOR * 2048)
    f.write(lm_padded)

    f.seek(0x800)
    tags = bytearray(f.read(192))
    for i in range(0, 192, 32):
        if tags[i] == 0x0f and tags[i+1] == 0x02:
            old_loc = struct.unpack('>I', tags[i+8:i+12])[0]
            old_sz  = struct.unpack('>I', tags[i+12:i+16])[0]
            struct.pack_into('>I', tags, i+8,  LAUNCHME_SECTOR)
            struct.pack_into('>I', tags, i+12, new_lm_sectors)
            print(f'  BLOCKS_ALWAYS: loc {old_loc}->{LAUNCHME_SECTOR}, size {old_sz}->{new_lm_sectors}')
    f.seek(0x800)
    f.write(bytes(tags))

    f.seek(LAUNCHME_SECTOR * 2048)
    hdr = f.read(4)
    if hdr == b'\\xe1\\xa0\\x00\\x00':
        print('  AIF header verified')
    else:
        print(f'  WARNING: unexpected header {hdr.hex()}')

print(f'  Done: {OUT_ISO}')
EOF

echo ""
echo "==> Done: $OUT_ISO"
echo "    Run: retroarch -L ~/.config/retroarch/cores/opera_libretro.so $OUT_ISO"
