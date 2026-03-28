#!/bin/bash
# build.sh — Build an OptiDoom 3DO ISO
#
# Usage:
#   ./build.sh                  # TEST build: boots to E1M1, music enabled
#   ./build.sh --normal         # NORMAL build: mod menu, music enabled
#   ./build.sh --no-music       # TEST build: no music (no disc drive required)
#   ./build.sh --hardware       # Build + sign ISO for real 3DO hardware
#   ./build.sh --setup          # Run first-time setup only (no build)
#
# Output:
#   /tmp/optidoom_test.iso      # Emulator build (RetroArch/Opera)
#   /tmp/optidoom_hw.iso        # Hardware build (--hardware only, signed)
#
# Required files (not in repo):
#   iso/optidoom.iso            — Your original Doom 3DO disc image
#
# Everything else (3do-devkit, Opera core, v24 OS components) is handled
# automatically on first run.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/optidoom3do/source"
BASE_ISO="$SCRIPT_DIR/iso/optidoom.iso"
V24_ISO="$SCRIPT_DIR/iso/v24_base.iso"
OUT_ISO="/tmp/optidoom_test.iso"
LAUNCHME_SECTOR=1183

# ─────────────────────────────────────────────────────────────────────────────
# Parse flags
# ─────────────────────────────────────────────────────────────────────────────

BUILD_MODE=""
DO_HARDWARE=0
SETUP_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --normal)    BUILD_MODE="normal" ;;
        --no-music)  BUILD_MODE="no-music" ;;
        --hardware)  DO_HARDWARE=1 ;;
        --setup)     SETUP_ONLY=1 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Setup helpers
# ─────────────────────────────────────────────────────────────────────────────

setup_devkit() {
    set +e; source ~/3do-dev/3do-devkit/activate-env 2>/dev/null; set -e
    if ! command -v armcc &>/dev/null; then
        echo ""
        echo "ERROR: armcc not found. Install the 3do-devkit first:"
        echo "  mkdir -p ~/3do-dev && cd ~/3do-dev"
        echo "  git clone https://github.com/trapexit/3do-devkit.git"
        exit 1
    fi
}

setup_opera_core() {
    CORE="$HOME/.config/retroarch/cores/opera_libretro.so"
    if [[ ! -f "$CORE" ]]; then
        echo "==> Building patched Opera libretro core (first time only)..."
        "$SCRIPT_DIR/build_opera_core.sh"
    fi
}

setup_v24_iso() {
    if [[ -f "$V24_ISO" ]]; then
        return
    fi
    echo "==> Building v24 OS donor ISO (first time only)..."
    mkdir -p "$SCRIPT_DIR/iso"
    HW_DIR="$HOME/3do-dev/hello-world"
    if [[ ! -d "$HW_DIR" ]]; then
        echo "    Cloning 3do-hello-world (no compilation needed)..."
        git clone --depth=1 https://github.com/trapexit/3do-hello-world.git "$HW_DIR"
    fi
    3doiso -in "$HW_DIR/takeme" -out "$V24_ISO"
    echo "    v24 OS ISO ready: $V24_ISO"
}

run_setup() {
    echo "==> Checking 3do-devkit..."
    setup_devkit
    armcc --vsn 2>&1 | head -1

    echo ""
    setup_opera_core

    echo ""
    setup_v24_iso

    echo ""
    mkdir -p "$SCRIPT_DIR/iso"
    if [[ ! -f "$BASE_ISO" ]]; then
        echo "==> Place your Doom 3DO disc image at: $BASE_ISO"
    fi

    echo ""
    echo "==> Setup complete."
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup-only mode
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$SETUP_ONLY" == "1" ]]; then
    run_setup
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Auto-setup: run any missing setup steps before building
# ─────────────────────────────────────────────────────────────────────────────

setup_devkit

CORE="$HOME/.config/retroarch/cores/opera_libretro.so"
if [[ ! -f "$CORE" ]]; then
    echo "==> Patched Opera core not found — building (one-time setup)..."
    "$SCRIPT_DIR/build_opera_core.sh"
fi

if [[ ! -f "$V24_ISO" ]]; then
    setup_v24_iso
fi

# ─────────────────────────────────────────────────────────────────────────────
# Verify base ISO exists
# ─────────────────────────────────────────────────────────────────────────────

if [[ ! -f "$BASE_ISO" ]]; then
    echo "ERROR: $BASE_ISO not found."
    echo "       Place your original Doom 3DO disc image there and re-run."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Determine build flags
# ─────────────────────────────────────────────────────────────────────────────

BASE_CFLAGS="-O1 -bigend -za1 -zi4 -fpu none -arch 3 -apcs 3/32/nofp"

case "$BUILD_MODE" in
    normal)
        echo "==> Building NORMAL ISO (mod menu, music enabled)"
        EXTRA="-DENABLE_MUSIC"
        ;;
    no-music)
        echo "==> Building TEST ISO (E1M1 auto-boot, no music)"
        EXTRA="-DDEBUG_SKIP_MENU"
        ;;
    *)
        echo "==> Building TEST ISO (E1M1 auto-boot, music enabled)"
        EXTRA="-DDEBUG_SKIP_MENU -DENABLE_MUSIC"
        ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Compile
# ─────────────────────────────────────────────────────────────────────────────

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

# ─────────────────────────────────────────────────────────────────────────────
# Patch ISO
# ─────────────────────────────────────────────────────────────────────────────

echo "==> Binary-patching LaunchMe + v24 OS into base ISO..."
python3 - <<EOF
import struct, math, shutil

BASE_ISO      = '$BASE_ISO'
NEW_LAUNCHME  = '$LAUNCHME'
OUT_ISO       = '$OUT_ISO'
V24_ISO       = '$V24_ISO'
LAUNCHME_SECTOR = $LAUNCHME_SECTOR

with open(NEW_LAUNCHME, 'rb') as f:
    new_lm = f.read()
new_lm_sectors = math.ceil(len(new_lm) / 2048)
print(f'  LaunchMe: {len(new_lm)} bytes = {new_lm_sectors} sectors')

# Read v24 OS components
with open(V24_ISO, 'rb') as hf:
    hf.seek(4 * 2048);   v24_sector4   = hf.read(2048)        # boot validator
    hf.seek(1 * 2048);   v24_bootcode  = hf.read(3 * 2048)    # boot code (3 sectors)
    hf.seek(5 * 2048);   v24_kernel    = hf.read(57 * 2048)   # OS kernel v24
    hf.seek(226 * 2048); v24_folios    = hf.read(76 * 2048)   # system folios v24
print(f'  v24 OS source: {V24_ISO}')

# Copy base ISO
shutil.copy2(BASE_ISO, OUT_ISO)

with open(OUT_ISO, 'r+b') as f:
    # Replace v20 developer OS with v24 retail OS
    f.seek(4 * 2048);   f.write(v24_sector4)
    print(f'  Patched sector 4 (permissive boot validator)')
    f.seek(1 * 2048);   f.write(v24_bootcode)
    print(f'  Replaced boot code (sectors 1-3, v24)')
    f.seek(5 * 2048);   f.write(v24_kernel)
    print(f'  Replaced OS kernel (sectors 5-61, v24)')
    f.seek(226 * 2048); f.write(v24_folios)
    print(f'  Replaced system folios (sector 226, v24)')

    # Write LaunchMe (zero-padded to sector boundary)
    lm_padded = new_lm + b'\\x00' * (new_lm_sectors * 2048 - len(new_lm))
    f.seek(LAUNCHME_SECTOR * 2048)
    f.write(lm_padded)

    # Update BLOCKS_ALWAYS ROM tag
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

    # Verify
    f.seek(LAUNCHME_SECTOR * 2048)
    hdr = f.read(4)
    if hdr == b'\\xe1\\xa0\\x00\\x00':
        print('  AIF header verified at sector 1183')
    else:
        print(f'  WARNING: unexpected header {hdr.hex()}')

print(f'  Done: {OUT_ISO}')
EOF

# ─────────────────────────────────────────────────────────────────────────────
# Hardware signing (optional)
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$DO_HARDWARE" == "1" ]]; then
    HW_ISO="/tmp/optidoom_hw.iso"
    echo ""
    echo "==> Signing ISO for real 3DO hardware..."
    cp "$OUT_ISO" "$HW_ISO"
    3DOEncrypt genromtags "$HW_ISO"
    echo ""
    echo "==> Hardware ISO: $HW_ISO"
    echo "    Burn to CD-R (2048-byte sectors, Mode 1) or use an ODE."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "==> Done: $OUT_ISO"
echo "    Run: retroarch -L ~/.config/retroarch/cores/opera_libretro.so $OUT_ISO"
