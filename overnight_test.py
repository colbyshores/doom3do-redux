#!/usr/bin/env python3
"""Overnight 3DO Doom diagnostic — runs Opera core via libretro.py.

No RetroArch needed. Loads the core in-process, runs frames, monitors
dbgStage in emulated RAM, captures video frames, and saves the first
frame that shows the red crash rectangle.

Usage:  python3 overnight_test.py [iso_path]
"""

import sys, os, time, struct, math
from pathlib import Path
from PIL import Image
import numpy as np

import libretro
from libretro import (
    SessionBuilder, ContentData,
    ArrayVideoDriver, ArrayAudioDriver,
    PixelFormat,
)

CORE_PATH = os.path.expanduser("~/.config/retroarch/cores/opera_libretro.so")
BIOS_DIR  = os.path.expanduser("~/.config/retroarch/system")
RESULTS   = Path("/tmp/overnight_results")
RESULTS.mkdir(exist_ok=True)

# dbgStage markers from threedo.c/tick.c/dmain.c/phase6.c
STAGE_NAMES = {
    0:  "boot/init",
    1:  "Init: past startModMenu",
    2:  "Init: complete",
    3:  "DEBUG_SKIP: past modmenu",
    4:  "DEBUG_SKIP: G_InitNew about to run",
    5:  "DEBUG_SKIP: G_InitNew done",
    6:  "DEBUG_SKIP: G_RunGame about to run",
    7:  "P_Start entered",
    8:  "P_Start: G_DoLoadLevel about to run",
    9:  "P_Start: G_DoLoadLevel done",
    10: "P_Drawer entered",
    11: "SegCommands entered",
    12: "SegCommands: DrawBackground done",
    13: "SegCommands: StartSegLoop done",
    14: "SegCommands: DrawWalls done",
    15: "SegCommands: DrawPlanes done",
}

def find_dbg_stage_addr(session):
    """Search emulated RAM for the DEADBEEF...dbgStage...CAFEBABE pattern."""
    try:
        mem = session.core.get_memory(libretro.MemoryType.SYSTEM_RAM)
        if mem is None or len(mem) == 0:
            return None
        data = bytes(mem)
        # Search for DEADBEEF marker (big-endian in ARM memory)
        marker = b'\xDE\xAD\xBE\xEF'
        idx = data.find(marker)
        while idx >= 0:
            # dbgStage is 4 bytes after the marker (uint8 at offset +4)
            # CAFEBABE should be at offset +5 (after 1-byte dbgStage + padding)
            # Actually: uint32 magic1, uint8 dbgStage, padding, uint32 magic2
            # With ARM alignment: magic1 at +0, dbgStage at +4, magic2 at +8
            if idx + 12 <= len(data):
                magic2 = struct.unpack('>I', data[idx+8:idx+12])[0]
                if magic2 == 0xCAFEBABE:
                    return idx + 4  # dbgStage byte offset in RAM
            idx = data.find(marker, idx + 1)
    except Exception as e:
        print(f"  Memory search error: {e}")
    return None

def read_dbg_stage(session, addr):
    """Read dbgStage byte from emulated RAM."""
    try:
        mem = session.core.get_memory(libretro.MemoryType.SYSTEM_RAM)
        if mem is not None and addr < len(mem):
            return mem[addr]
    except:
        pass
    return None

def frame_to_image(video_driver):
    """Convert the current video frame to a PIL Image."""
    try:
        fb = video_driver.screenshot()
        if fb is not None:
            return fb
    except:
        pass
    return None

def check_red_rectangle(img):
    """Check if image contains a red rectangle (crash indicator)."""
    arr = np.array(img)
    if arr.ndim < 3:
        return False, 0.0
    r, g, b = arr[:,:,0], arr[:,:,1], arr[:,:,2]
    red_mask = (r > 150) & (g < 50) & (b < 50)
    red_pct = 100.0 * red_mask.sum() / max(red_mask.size, 1)
    return red_pct > 3.0, red_pct

def run_test(iso_path, name):
    """Run one ISO through the Opera core and monitor for crashes."""
    test_dir = RESULTS / name
    test_dir.mkdir(exist_ok=True)
    log_path = test_dir / "log.txt"

    print(f"\n{'='*60}")
    print(f" TEST: {name}")
    print(f" ISO:  {iso_path}")
    print(f"{'='*60}")

    if not os.path.exists(iso_path):
        print(f"  SKIP: ISO not found")
        return

    with open(log_path, 'w') as logf:
        def log(msg):
            ts = time.strftime('%H:%M:%S')
            line = f"[{ts}] {msg}"
            print(f"  {line}")
            logf.write(line + '\n')
            logf.flush()

        try:
            # Build session
            video = ArrayVideoDriver()
            audio = ArrayAudioDriver()

            session = SessionBuilder() \
                .with_core(CORE_PATH) \
                .with_content(ContentData(Path(iso_path))) \
                .with_video(video) \
                .with_audio(audio) \
                .with_system_dir(BIOS_DIR) \
                .build()

            log("Session created, core loaded")

        except Exception as e:
            log(f"FAILED to create session: {e}")
            return

        with session:
            # Find dbgStage in memory (run a few frames first for init)
            log("Running initial frames...")
            for i in range(120):  # ~2 seconds at 60fps
                session.run()

            dbg_addr = find_dbg_stage_addr(session)
            if dbg_addr is not None:
                log(f"Found dbgStage at RAM offset 0x{dbg_addr:06x}")
            else:
                log("dbgStage marker NOT found in RAM (no debug build?)")

            # Run frames and monitor
            last_stage = None
            frame_num = 0
            max_frames = 60 * 180  # 3 minutes at 60fps
            red_detected = False
            save_interval = 300  # save a frame every 300 frames (~5 sec)

            log("Starting frame loop...")
            t0 = time.time()

            for frame_num in range(max_frames):
                try:
                    session.run()
                except libretro.CoreShutDownException:
                    log(f"CORE SHUTDOWN at frame {frame_num}")
                    break
                except Exception as e:
                    log(f"EXCEPTION at frame {frame_num}: {e}")
                    break

                # Check dbgStage
                if dbg_addr is not None and frame_num % 15 == 0:
                    stage = read_dbg_stage(session, dbg_addr)
                    if stage is not None and stage != last_stage:
                        elapsed = time.time() - t0
                        sname = STAGE_NAMES.get(stage, f"unknown 0x{stage:02x}")
                        log(f"frame {frame_num} ({elapsed:.1f}s): dbgStage={stage} — {sname}")
                        last_stage = stage

                # Capture video periodically + check for red rectangle
                if frame_num % 30 == 0:  # every 0.5 sec
                    img = frame_to_image(video)
                    if img is not None:
                        is_red, red_pct = check_red_rectangle(img)
                        if is_red:
                            log(f"*** RED RECTANGLE at frame {frame_num}! ({red_pct:.1f}% red) ***")
                            img.save(str(test_dir / f"RED_frame_{frame_num}.png"))
                            red_detected = True
                            # Run a few more frames to capture the full crash
                            for extra in range(60):
                                try:
                                    session.run()
                                except:
                                    break
                                if extra % 10 == 0:
                                    img2 = frame_to_image(video)
                                    if img2 is not None:
                                        img2.save(str(test_dir / f"RED_extra_{extra}.png"))
                            break

                        # Save periodic frames
                        if frame_num % save_interval == 0:
                            img.save(str(test_dir / f"frame_{frame_num:06d}.png"))
                            arr = np.array(img)
                            log(f"frame {frame_num}: mean_brightness={arr.mean():.1f}")

            elapsed = time.time() - t0
            if red_detected:
                log(f"RESULT: RED RECTANGLE CRASH detected (last dbgStage={last_stage})")
            elif frame_num >= max_frames - 1:
                log(f"RESULT: Ran {max_frames} frames ({elapsed:.0f}s) without crash")
            else:
                log(f"RESULT: Exited at frame {frame_num} ({elapsed:.0f}s), last dbgStage={last_stage}")

            # Save final frame
            img = frame_to_image(video)
            if img is not None:
                img.save(str(test_dir / "final_frame.png"))

            # Dump memory region around dbgStage
            if dbg_addr is not None:
                try:
                    mem = session.core.get_memory(libretro.MemoryType.SYSTEM_RAM)
                    if mem is not None:
                        start = max(0, dbg_addr - 16)
                        end = min(len(mem), dbg_addr + 32)
                        hexdump = ' '.join(f'{mem[i]:02x}' for i in range(start, end))
                        log(f"RAM around dbgStage: {hexdump}")
                except:
                    pass

    print(f"  Results in: {test_dir}/")


def main():
    script_dir = Path(__file__).parent

    if len(sys.argv) > 1:
        # Test a specific ISO
        run_test(sys.argv[1], "custom")
        return

    print(f"Opera core: {CORE_PATH}")
    print(f"BIOS dir:   {BIOS_DIR}")
    print(f"Results:    {RESULTS}/")

    # Test 1: Original unmodified base ISO
    run_test(str(script_dir / "optidoom3do" / "optidoom.iso"), "1_original")

    # Test 2: Clean cell-accell
    run_test("/tmp/optidoom_clean_cellaccell.iso", "2_clean_cellaccell")

    # Test 3: DEBUG_SKIP_MENU build
    run_test("/tmp/optidoom_test.iso", "3_debug_skip")

    print(f"\n{'='*60}")
    print(f" ALL TESTS COMPLETE")
    print(f" Results: {RESULTS}/")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
