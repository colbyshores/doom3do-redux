#!/bin/bash
# build_test_iso.sh — Build a test ISO that boots directly to E1M1 (no menus)
#
# Usage:
#   ./build_test_iso.sh           # builds test ISO → /tmp/optidoom_test.iso
#   ./build_test_iso.sh --normal  # builds normal ISO (with menus) → /tmp/optidoom_test.iso
#
# Binary-patch approach: patches new LaunchMe + v24 OS components into base ISO.
#
# KEY DISCOVERY: optidoom_working_backup.iso has a v20 developer OS that silently
# fails to launch the LaunchMe. Fix: replace boot code, kernel, and system folios
# from hello_world.iso (which carries the v24 retail OS). The v24 OS correctly
# finds and launches LaunchMe via BLOCKS_ALWAYS ROM tag at sector 1183.
# Sector 4 from hello_world is also required as a permissive boot validator —
# the original optidoom sector 4 fails the BIOS boot check.
#
# Required: /home/coleshores/3do-dev/hello-world/iso/helloworld.iso (v24 OS donor)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/optidoom3do/source"
BASE_ISO="$SCRIPT_DIR/optidoom3do/optidoom_working_backup.iso"
OUT_ISO="/tmp/optidoom_test.iso"
LAUNCHME_SECTOR=1183  # confirmed: launchme lives at sector 1183 in the base ISO

set +e; source ~/3do-dev/3do-devkit/activate-env; set -e

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
HELLO_ISO = '/home/coleshores/3do-dev/hello-world/iso/helloworld.iso'

with open(NEW_LAUNCHME, 'rb') as f:
    new_lm = f.read()
new_lm_sectors = math.ceil(len(new_lm) / 2048)
print(f'  LaunchMe: {len(new_lm)} bytes = {new_lm_sectors} sectors')

# Read v24 OS components from hello_world
with open(HELLO_ISO, 'rb') as hf:
    hf.seek(4 * 2048);   hello_sector4 = hf.read(2048)      # boot validator
    hf.seek(1 * 2048);   hello_bootcode = hf.read(3 * 2048)  # NEWKNEWNEWGNUBOOT (3 sectors)
    hf.seek(5 * 2048);   hello_kernel   = hf.read(57 * 2048) # OS kernel v24 (115520 bytes)
    hf.seek(226 * 2048); hello_folios   = hf.read(76 * 2048) # system folios v24 (153688 bytes)
print(f'  OS donor: {HELLO_ISO}')

# Copy base ISO
shutil.copy2(BASE_ISO, OUT_ISO)

with open(OUT_ISO, 'r+b') as f:
    # Patch sector 4 (boot validator) — original optidoom sector 4 fails BIOS check
    f.seek(4 * 2048);   f.write(hello_sector4)
    print(f'  Patched sector 4 (permissive boot validator)')

    # Replace v20 developer OS with v24 retail OS from hello_world
    # v20 OS silently fails to launch LaunchMe; v24 OS launches correctly
    f.seek(1 * 2048);   f.write(hello_bootcode)
    print(f'  Replaced boot code (sectors 1-3, v24)')
    f.seek(5 * 2048);   f.write(hello_kernel)
    print(f'  Replaced OS kernel (sectors 5-61, v24.225)')
    f.seek(226 * 2048); f.write(hello_folios)
    print(f'  Replaced system folios (sector 226, v24.225)')

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
