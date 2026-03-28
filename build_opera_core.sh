#!/bin/bash
# build_opera_core.sh — Build patched Opera libretro core with MADAM joypad fix
#
# The stock Opera core does not write joypad state to the MADAM register at
# 0x033006FC. Optidoom reads input from that address directly, so the player
# cannot move without this patch.
#
# The patch adds a single block to lr_input_poll_joypad() that converts the
# libretro joypad state to 3DO ControlPad bit format and writes it to
# opera_madam_poke(0x6FC, bits) after the normal PBUS joypad processing.
#
# Upstream: https://github.com/libretro/opera-libretro.git
# Patched at commit: 1eee72f640e4da6f1b8ca68f70b51db22cc474c8
#
# Usage:
#   ./build_opera_core.sh
#
# Output: ~/.config/retroarch/cores/opera_libretro.so (replaces stock core)
#
# Requirements: gcc, make, git

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH="$SCRIPT_DIR/opera-patch/madam_joypad.patch"
BUILD_DIR="/tmp/opera-libretro-build"
UPSTREAM="https://github.com/libretro/opera-libretro.git"
UPSTREAM_COMMIT="1eee72f640e4da6f1b8ca68f70b51db22cc474c8"
CORE_DEST="$HOME/.config/retroarch/cores/opera_libretro.so"

echo "==> Cloning Opera libretro..."
rm -rf "$BUILD_DIR"
git clone "$UPSTREAM" "$BUILD_DIR"
git -C "$BUILD_DIR" checkout "$UPSTREAM_COMMIT"

echo "==> Applying MADAM joypad patch..."
git -C "$BUILD_DIR" apply "$PATCH"

echo "==> Building..."
make -C "$BUILD_DIR" -j"$(nproc)"

echo "==> Installing to $CORE_DEST..."
cp "$BUILD_DIR/opera_libretro.so" "$CORE_DEST"

echo ""
echo "==> Done. Patched Opera core installed."
echo "    Test: retroarch -L $CORE_DEST /tmp/optidoom_test.iso"
