#!/bin/bash
# setup.sh — One-time setup for optidoom-test
#
# Run this once after cloning (or just run ./build.sh which calls this automatically).
#
# It:
#   1. Verifies the 3do-devkit is installed
#   2. Builds and installs the patched Opera libretro core
#   3. Builds iso/v24_base.iso (v24 OS donor, built from 3do-hello-world)
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
armcc -vsn 2>&1 | head -1

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
    # Build from 3do-hello-world — produces proper NEWKNEWNEWGNUBOOT boot code
    # and the v24.225 retail OS. The devkit's 3doiso alone generates the wrong boot sectors.
    # Check common locations first before cloning.
    HW_ISO=""
    for candidate in \
        "$HOME/3do-dev/hello-world/iso/helloworld.iso" \
        "$HOME/3do-dev/3do-hello-world/iso/helloworld.iso" \
        "$HOME/3do-dev/3do-hello-world/helloworld.iso"; do
        if [[ -f "$candidate" ]]; then
            HW_ISO="$candidate"
            echo "    Found hello-world ISO: $HW_ISO"
            break
        fi
    done
    if [[ -z "$HW_ISO" ]]; then
        HW_DIR="$HOME/3do-dev/3do-hello-world"
        if [[ ! -d "$HW_DIR" ]]; then
            echo "    Cloning 3do-hello-world..."
            git clone https://github.com/trapexit/3do-hello-world.git "$HW_DIR"
        fi
        echo "    Building hello-world ISO..."
        (cd "$HW_DIR" && make)
        HW_ISO=$(find "$HW_DIR" -name "*.iso" | head -1)
    fi
    if [[ -z "$HW_ISO" ]]; then
        echo "ERROR: Could not find or build a hello-world ISO. Provide one at:"
        echo "  $HOME/3do-dev/hello-world/iso/helloworld.iso"
        exit 1
    fi
    cp "$HW_ISO" "$V24_ISO"
    echo "    v24 OS ISO ready: $V24_ISO"
fi

echo ""
if [[ ! -f "$SCRIPT_DIR/iso/optidoom.iso" ]]; then
    echo "==> Place your Doom 3DO disc image at: $SCRIPT_DIR/iso/optidoom.iso"
fi

echo ""
echo "==> Setup complete."
echo "    Once iso/optidoom.iso is in place, run: ./build.sh"
