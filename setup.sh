#!/bin/bash
# setup.sh — One-time setup for optidoom-test
#
# Run this once after cloning (or just run ./build.sh which calls this automatically).
#
# It:
#   1. Verifies the 3do-devkit is installed
#   2. Builds and installs the patched Opera libretro core
#   3. Builds iso/v24_base.iso (v24 OS components, no commercial content)
#   4. Creates the iso/ directory for the base ISO
#
# After setup, place iso/optidoom.iso (your Doom 3DO disc image) then run:
#   ./build.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Checking 3do-devkit..."
set +e; source ~/3do-dev/3do-devkit/activate-env; set -e
if ! command -v armcc &>/dev/null; then
    echo ""
    echo "ERROR: armcc not found. Install the 3do-devkit first:"
    echo "  mkdir -p ~/3do-dev && cd ~/3do-dev"
    echo "  git clone https://github.com/trapexit/3do-devkit.git"
    echo "  set +e; source ~/3do-dev/3do-devkit/activate-env; set -e"
    exit 1
fi
armcc --vsn 2>&1 | head -1

echo ""
echo "==> Building patched Opera libretro core..."
"$SCRIPT_DIR/build_opera_core.sh"

echo ""
echo "==> Building v24 OS donor ISO..."
mkdir -p "$SCRIPT_DIR/iso"
V24_ISO="$SCRIPT_DIR/iso/v24_base.iso"
if [[ -f "$V24_ISO" ]]; then
    echo "    Already present: $V24_ISO"
else
    HW_DIR="$HOME/3do-dev/hello-world"
    if [[ ! -d "$HW_DIR" ]]; then
        echo "    Cloning 3do-hello-world (pre-built binaries, no compilation)..."
        git clone --depth=1 https://github.com/trapexit/3do-hello-world.git "$HW_DIR"
    fi
    echo "    Running 3doiso..."
    3doiso -in "$HW_DIR/takeme" -out "$V24_ISO"
    echo "    v24 OS ISO ready: $V24_ISO"
fi

echo ""
if [[ ! -f "$SCRIPT_DIR/iso/optidoom.iso" ]]; then
    echo "==> Place your Doom 3DO disc image at: $SCRIPT_DIR/iso/optidoom.iso"
fi

echo ""
echo "==> Setup complete."
echo "    Once iso/optidoom.iso is in place, run: ./build.sh"
