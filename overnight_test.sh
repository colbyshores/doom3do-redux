#!/bin/bash
# overnight_test.sh — Automated overnight diagnostic for the red rectangle crash
#
# Run from YOUR terminal:  ./overnight_test.sh
#
# Takes rapid screenshots (every 1.5s) to catch the red rectangle crash frame.
# Results saved to /tmp/overnight_results/

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="/tmp/overnight_results"
RETROARCH_CORE=~/.config/retroarch/cores/opera_libretro.so
SCREENSHOT_DIR=~/.config/retroarch/screenshots
RA_NET_PORT=55355
TOTAL_WAIT=180     # total seconds to monitor per test

mkdir -p "$RESULTS_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$RESULTS_DIR/test.log"; }

run_test() {
    local NAME="$1"
    local ISO="$2"
    local TEST_DIR="$RESULTS_DIR/$NAME"
    mkdir -p "$TEST_DIR"

    log ""
    log "========================================================"
    log " TEST: $NAME"
    log "========================================================"
    log "ISO: $ISO"

    if [ ! -f "$ISO" ]; then
        log "SKIP: ISO not found"
        return
    fi

    # Kill any existing RetroArch
    killall retroarch 2>/dev/null || true
    sleep 2

    # Launch RetroArch
    retroarch -L "$RETROARCH_CORE" "$ISO" &
    RA_PID=$!
    log "RetroArch PID: $RA_PID"

    # Start dbgStage monitor
    python3 "$SCRIPT_DIR/poll_dbgstage.py" 200 > "$TEST_DIR/dbgstage.log" 2>&1 &
    DBG_PID=$!

    # Rapid-fire screenshot loop — every 1.5 seconds, keep ALL frames
    FRAME=0
    BEFORE=""
    for ((sec=0; sec<TOTAL_WAIT; sec+=2)); do
        sleep 1

        if ! kill -0 "$RA_PID" 2>/dev/null; then
            log "  RetroArch EXITED at ~${sec}s"
            # Take a few more screenshots in case the window is still visible
            for grab in 1 2 3; do
                echo -n "SCREENSHOT" | nc -u -w1 127.0.0.1 "$RA_NET_PORT" 2>/dev/null || true
                sleep 0.5
            done
            break
        fi

        # Fire screenshot command
        echo -n "SCREENSHOT" | nc -u -w1 127.0.0.1 "$RA_NET_PORT" 2>/dev/null || true
        sleep 0.8

        # Grab newest screenshot
        NEWEST=$(ls -t "$SCREENSHOT_DIR"/*.png 2>/dev/null | head -1)
        if [ -n "$NEWEST" ] && [ "$NEWEST" != "$BEFORE" ]; then
            BEFORE="$NEWEST"
            FRAME=$((FRAME+1))
            # Copy EVERY unique frame
            cp "$NEWEST" "$TEST_DIR/frame_$(printf '%03d' $FRAME)_${sec}s.png"

            # Quick brightness check
            BRIGHT=$(python3 -c "
from PIL import Image
img = Image.open('$NEWEST').convert('RGB')
w,h = img.size
pts = [img.getpixel((x,y)) for y in range(0,h,8) for x in range(0,w,8)]
lum = sum(0.299*r+0.587*g+0.114*b for r,g,b in pts)/max(len(pts),1)
# Check for red rectangle: high R, low G, low B
rpx = [p for p in pts if p[0] > 150 and p[1] < 50 and p[2] < 50]
red_pct = 100.0 * len(rpx) / max(len(pts),1)
print(f'{lum:.1f} red={red_pct:.1f}%')
" 2>/dev/null || echo "? red=?")
            log "  ${sec}s frame${FRAME}: brightness=${BRIGHT}"

            # Check for red rectangle specifically
            if echo "$BRIGHT" | grep -q "red=[1-9]"; then
                log "  *** RED RECTANGLE DETECTED at ${sec}s! ***"
                # Rapid-fire capture to get more frames of the crash
                for grab in $(seq 1 10); do
                    echo -n "SCREENSHOT" | nc -u -w1 127.0.0.1 "$RA_NET_PORT" 2>/dev/null || true
                    sleep 0.3
                    N2=$(ls -t "$SCREENSHOT_DIR"/*.png 2>/dev/null | head -1)
                    if [ -n "$N2" ] && [ "$N2" != "$BEFORE" ]; then
                        BEFORE="$N2"
                        cp "$N2" "$TEST_DIR/RED_frame_${grab}.png"
                    fi
                done
            fi
        fi
    done

    # Stop dbgStage monitor
    kill "$DBG_PID" 2>/dev/null || true
    wait "$DBG_PID" 2>/dev/null || true

    log "  --- dbgStage log ---"
    cat "$TEST_DIR/dbgstage.log" 2>/dev/null | tee -a "$RESULTS_DIR/test.log"
    log "  --- end ---"
    log "  Captured $FRAME unique frames in $TEST_DIR/"

    kill "$RA_PID" 2>/dev/null || true
    wait "$RA_PID" 2>/dev/null || true
    sleep 3
}

# ============================================================
rm -f "$RESULTS_DIR/test.log"
log "Overnight diagnostic started at $(date)"
log "Core: $(ls -la "$RETROARCH_CORE" 2>/dev/null)"
log "BIOS: $(readlink -f ~/.config/retroarch/system/panafz10.bin)"

# Test 1: Original unmodified base ISO
run_test "1_original_unmodified" "$SCRIPT_DIR/optidoom3do/optidoom.iso"

# Test 2: Clean committed cell-accell (no DEBUG_SKIP_MENU)
run_test "2_clean_cellaccell" "/tmp/optidoom_clean_cellaccell.iso"

# Test 3: Cell-accell with DEBUG_SKIP_MENU
run_test "3_debug_skip_menu" "/tmp/optidoom_test.iso"

log ""
log "========================================================"
log " ALL TESTS COMPLETE — $(date)"
log " Results: $RESULTS_DIR/"
log "========================================================"
