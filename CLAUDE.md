# optidoom-test — Complete Development Environment Guide

---

## 1. Prerequisites

### System packages

```bash
sudo apt install gcc make python3 python3-pillow git libdl-dev
# python3-numpy optional (for overnight_test.py)
```

### RetroArch

Version 1.18.0 is installed. Install via your distro package manager or from https://www.retroarch.com.

```bash
sudo apt install retroarch
# or snap/flatpak — but the core path below assumes native install
```

---

## 2. 3DO Devkit Installation

The devkit is at `~/3do-dev/3do-devkit/` and comes from:
https://github.com/trapexit/3do-devkit

```bash
mkdir -p ~/3do-dev
cd ~/3do-dev
git clone https://github.com/trapexit/3do-devkit.git
```

That's it. No compilation needed — the repo includes pre-built Linux binaries for:
- `armcc` / `armlink` / `armasm` — Norcroft ARM C v4.91 (ARM SDT 2.51, Build 130)
- `modbin` — sets 3DO AIF header fields
- `3DOEncrypt` — signs disc images with 3DO homebrew RSA keys
- `3it`, `3dt`, `3ct` — image/disc/compression tools

### Activate the environment

```bash
# ALWAYS use this pattern — NOT just `source activate-env`
# activate-env runs `which armcc` to check PATH; if armcc isn't in PATH yet,
# `which` returns exit code 1, which kills the script under set -e.
set +e; source ~/3do-dev/3do-devkit/activate-env; set -e
```

After activation, `armcc`, `armlink`, `modbin`, `3DOEncrypt` etc. are in PATH.
`$TDO_DEVKIT_PATH` is set to `~/3do-dev/3do-devkit`.

To make it permanent, add to `~/.bashrc`:
```bash
set +e; source ~/3do-dev/3do-devkit/activate-env; set -e
```

### Verify compiler works

```bash
armcc --vsn 2>&1 | head -3
# Expected: Norcroft ARM C v4.91 (ARM Ltd SDT2.51) [Build number 130]
```

---

## 3. Hello World ISO (Required as OS Donor)

The `hello-world` project is at `~/3do-dev/hello-world/` and its ISO at
`~/3do-dev/hello-world/iso/helloworld.iso` is **required** by `build_test_iso.sh`.

It supplies the v24.225 retail OS that replaces the broken v20 developer OS
in optidoom_working_backup.iso. Without it, the build script fails.

The hello-world project is NOT in a git repo on this machine. If it needs to be
re-acquired, it can be cloned from: https://github.com/trapexit/3do-hello-world
(or equivalent community project). What matters is only the compiled ISO —
any 3DO disc that boots with v24.225 OS will work as the donor.

**To verify the donor ISO is correct:**
```bash
python3 -c "
import struct
with open('$HOME/3do-dev/hello-world/iso/helloworld.iso','rb') as f:
    f.seek(0x800); tags = f.read(192)
# Kernel tag (0x0f/0x07): loc should be 5, size 115520
for i in range(0,192,32):
    if tags[i]==0x0f and tags[i+1]==0x07:
        loc = struct.unpack('>I',tags[i+8:i+12])[0]
        sz  = struct.unpack('>I',tags[i+12:i+16])[0]
        print(f'kernel: loc={loc} size={sz}')  # expect loc=5 size=115520
"
```

---

## 4. BIOS Files

Place in `~/.config/retroarch/system/`:

| File | MD5 | Notes |
|------|-----|-------|
| `panafz10-norsa.bin` | `1477bda80dc33731a65468c1f5bcbee9` | **Primary BIOS** — RSA checks disabled. Used by build harness and RetroArch. |
| `panafz10.bin` | `1477bda80dc33731a65468c1f5bcbee9` | **Identical to above** on this machine. |
| `panafz10-jp.bin` | `20706f726c22d79d3c385e215d7428e2` | Japanese BIOS, not used. |

**Note:** `panafz10.bin` and `panafz10-norsa.bin` are the same file here (same MD5).
The "retail" panafz10 is not present. This is fine — the norsa BIOS works correctly
for development.

Source: archived 3DO BIOS dumps, widely available in the 3DO community.

---

## 5. Opera Libretro Core

Core at: `~/.config/retroarch/cores/opera_libretro.so`
Current MD5: `4dcbffbfa5b131c5c21e83fca21286c1`

Backups:
- `.backup` — MD5 `b872517c37ac2282b3af21de01b2fc9b` (older version)
- `.mar22` — MD5 `4dcbffbfa5b131c5c21e83fca21286c1` (same as current)
- `.mar24` — MD5 `6e433d989d549ae047a5a3c4b6dfa5f8` (different version)

Install/update via RetroArch's Online Updater → Core Downloader → "3DO (Opera)".

### Required RetroArch core options (Opera.opt)

Stored at `~/.config/retroarch/config/Opera/Opera.opt`. Key settings:

```
opera_bios = "panafz10.bin"
opera_mem_capacity = "21"       # CRITICAL — "3" causes crashes
opera_cpu_overclock = "1.0x (12.50Mhz)"
opera_region = "ntsc"
opera_kprint = "enabled"        # Shows 3DO OS debug output in RetroArch log
opera_madam_matrix_engine = "hardware"
opera_dsp_threaded = "disabled"
opera_swi_hle = "disabled"
opera_nvram_storage = "per game"
opera_active_devices = "1"
```

`opera_mem_capacity = "21"` means 2MB RAM. The game crashes with the default "3" (512KB).

---

## 6. Building a Test ISO

```bash
# From the repo root:
./build_test_iso.sh           # DEBUG_SKIP_MENU → boots straight to E1M1
./build_test_iso.sh --normal  # Normal build, shows mod options menu
# Output: /tmp/optidoom_test.iso
```

### What the build script does

1. Sources the devkit environment (`set +e; source activate-env; set -e`)
2. Compiles all `.c` and `.s` sources in `optidoom3do/source/` with `armcc`
3. Links with `armlink` → `optidoom3do/takeme/LaunchMe`
4. Runs `modbin` to set the 3DO AIF header (name, stack size, timestamp)
5. Patches the base ISO (`optidoom_working_backup.iso`) with Python:
   - Copies sector 4 from `helloworld.iso` (permissive boot validator)
   - Copies boot code (sectors 1–3) from `helloworld.iso` (v24 OS loader)
   - Copies OS kernel (sectors 5–61) from `helloworld.iso` (v24.225)
   - Copies system folios (sector 226) from `helloworld.iso` (v24.225)
   - Writes new LaunchMe at sector 1183
   - Updates BLOCKS_ALWAYS ROM tag size to new sector count

### Compiler flags

```makefile
CFLAGS = -O1 -bigend -za1 -zi4 -fpu none -arch 3 -apcs "3/32/nofp"
# -bigend: big-endian ARM (3DO is big-endian)
# -za1: strict aliasing
# -zi4: integer size = 4 bytes
# -fpu none: no FPU (3DO has no hardware FPU)
# -arch 3: ARM architecture v3 (ARM60 CPU)
# -apcs 3/32/nofp: 32-bit APCS, no frame pointer
```

Assembly files use:
```makefile
ASFLAGS = -bigend -fpu none -arch 3 -apcs "3/32/nofp"
```

---

## 7. Testing Without a Display

The C test harness at `/tmp/test_opera.c` loads the Opera libretro core in-process,
runs frames, and checks for non-black video — no RetroArch, no window needed.

```bash
# Build the harness (only needed once or after /tmp is cleared):
gcc -g -O0 -o /tmp/test_opera /tmp/test_opera.c -ldl

# Run:
/tmp/test_opera /tmp/optidoom_test.iso 2>/tmp/kprint.log
# NOTE: if BIOS fails to load, pass system dir explicitly:
# /tmp/test_opera /tmp/optidoom_test.iso /home/coleshores/.config/retroarch/system/3DO
# (the parent system dir may contain only symlinks that Opera can't follow)

# Watch kprint (3DO OS debug output):
cat /tmp/kprint.log | strings
```

Expected output on success:
```
FIRST NON-BLACK FRAME at frame 146 (320x240)
...
Sherry  v24.225
Operator  v24.225
...
NTSC system detected
...
$c/lmadm: (ram, 3, 0) is CLEAN
eventbroker  v24.225
```

---

## 8. Critical Disc Structure Facts

### The disc layout (optidoom_working_backup.iso as base)

| Sector | Content | Source |
|--------|---------|--------|
| 0 | 3DO disc label (root dir avatars at sectors 79446, 79510, 79574) | original |
| 1–3 | NEWKNEWNEWGNUBOOT boot code | **hello_world** (v24) |
| 4 | Boot validator | **hello_world** (permissive) |
| 5–61 | OS kernel | **hello_world** (v24.225, 115520 bytes) |
| 69 | Signatures/misc | original |
| 226 | System folios | **hello_world** (v24.225, 153688 bytes) |
| 1183 | LaunchMe (current build) | **compiled** |
| 79446–79574 | 3DO filesystem root directory (3 avatars) | original |

Bold = patched by `build_test_iso.sh`.

### ROM tags (sector 1, offset 0x800) — field layout

Each tag is 32 bytes, big-endian:
- Bytes 0–1: SubSysType / Type (e.g., `0x0f/0x02`)
- Bytes 2–3: Version / Revision
- Bytes 4–7: reserved (zero)
- Bytes 8–11: **loc** (disc sector number)
- Bytes 12–15: **size** (bytes for most tags; **sectors** for BLOCKS_ALWAYS `0x0f/0x02`)
- Bytes 16–31: zero

| Tag | loc | size | Meaning |
|-----|-----|------|---------|
| `0f/0d` | 1 | 5996 bytes | NEWKNEWNEWGNUBOOT boot code |
| `0f/07` | 5 | 115520 bytes | OS kernel |
| `0f/0c` | `0xACBFF792` | 0 | Sentinel / end marker |
| `0f/02` | 1183 | **148 sectors** | BLOCKS_ALWAYS — LaunchMe location |
| `0f/10` | 69 | 2908 bytes | Misc/signatures |
| `0f/14` | 226 | 153688 bytes | System folios |

**BLOCKS_ALWAYS size is in SECTORS for optidoom-format discs**, not bytes.
(hello_world uses bytes; optidoom uses sectors. The formats differ.)

### 3DO filesystem directory entry for LaunchMe

Located in the root dir block at sector 79446, the entry for `launchme` (lowercase):
- ByteCount: must match actual LaunchMe size in bytes
- BlockCount: must match actual LaunchMe size in sectors
- Avatar[0]: 1183 (sector on disc)

`build_test_iso.sh` does NOT currently update the filesystem entry — it updates only
the ROM tag. The v24 `$c/lmadm` uses BLOCKS_ALWAYS (not the filesystem) to launch,
so this has not caused issues. If you switch back to v20 OS, you would need to also
update the filesystem entry.

---

## 9. Why the Boot Was Broken (Root Cause Analysis)

### Problem 1: Sector 4 — Boot Validator

`optidoom_working_backup.iso` sector 4 contains a boot validator that the BIOS
rejects during disc authentication. Result: zero kprint output, pure black screen.

The BIOS reads sector 4 as part of the boot signature validation sequence.
Optidoom's sector 4 is similar to the retail version (first 1836 bytes identical)
but has 64 bytes that differ at the end, causing validation failure.

`hello_world/symanim` use a completely different, permissive sector 4 that
accepts any disc. Replacing sector 4 from hello_world fixes this.

**The key discovery was found via binary search**: replacing sectors 0–999, 0–500,
0–250, 0–125, 0–63, 0–32, 0–5, and finally sector 4 alone to isolate the culprit.

### Problem 2: v20 Developer OS — Silent Launch Failure

After fixing sector 4, the disc booted but showed the 3DO storage manager
("Insert CD") instead of Doom. The v20 developer OS (Operamath 20.53,
"Release for developer system") boots successfully (kprint shows full startup
sequence) but `$programs/lmadm` silently fails to launch the LaunchMe.

No error is printed. The disc's filesystem (3DO format, root at sector 79446)
was validated as CLEAN. The BLOCKS_ALWAYS ROM tag correctly pointed to sector 1183.
The LaunchMe AIF header was valid. Nothing explains the failure from the outside —
the v20 lmadm simply does not launch the app.

**Fix**: Replace the entire v20 OS with the v24.225 OS from hello_world:
boot code (sectors 1–3), kernel (sectors 5–61), system folios (sector 226).
The v24 `$c/lmadm` correctly launches the LaunchMe.

**Why this works**: The v24 OS and the v20 OS use different launch mechanisms.
The v24 lmadm reads BLOCKS_ALWAYS and loads the LaunchMe from sector 1183 directly.
The v20 lmadm appears to require something additional (possibly a specific filesystem
layout or a developer-mode authentication token) that is not present.

**Why full v24 OS replacement previously failed**: Earlier attempts to swap in
the v24 OS used the wrong sector 4 (retail/optidoom instead of hello_world's
permissive validator) AND did not include the boot code replacement, causing
the v20 boot code to load the new kernel but fail to initialize it correctly.

### Problem 3: optidoom.iso vs optidoom_working_backup.iso

`optidoom3do/optidoom.iso` was corrupted by a previous bad build that wrote
incorrect BLOCKS_ALWAYS values (loc=1182, size=313284 bytes instead of sectors).
Since that ISO was used as the source for patching, each rebuild propagated
the corruption further.

**Always use `optidoom_working_backup.iso` as the base ISO.** It has the correct
`loc=1183, size=153 sectors`.

---

## 10. DEBUG_SKIP_MENU

Defined at compile time with `-DDEBUG_SKIP_MENU`. Two effects:

**In `modmenu.c` — skips the mod options screen:**
```c
#ifdef DEBUG_SKIP_MENU
    exit = true;  // auto-exit with default options
#else
    do { updateInput(); controlModMenu(); renderModMenu(); } while(!exit);
#endif
```

**In `dmain.c` — skips to E1M1:**
Without DEBUG_SKIP_MENU, the game shows the Doom start screen and waits for
player input. With it, `G_InitNew(1, 1, sk_medium)` is called directly.

---

## 11. Joypad Input (Known Limitation)

The stock Opera libretro core does not write the 3DO joypad state to ARM
address `0x033006FC` (MADAM register). Optidoom reads input from this address.
Result: game runs but player cannot move.

A patched core was previously built from source and stored at
`~/opera_bug_fix/` (the patch adds a single write to MADAM register 0x6FC on
each input poll). The compiled `.so` was lost on reboot.

**To rebuild the patched core:**
- Source is at `~/opera_bug_fix/` (verify this still exists)
- The patch adds `madam->regs[0x6FC/4] = joypad_state;` in the input handler
- Build with `make` in the Opera libretro directory
- Install: `cp opera_libretro.so ~/.config/retroarch/cores/opera_libretro.so`

With `DEBUG_SKIP_MENU`, the game reaches E1M1 without any input required —
the joypad patch is only needed for actual gameplay testing.

---

## 12. Profiling

`PROFILE_ON` is defined in `optidoom3do/source/bench.h`. When defined:
- `startBenchPeriod(idx, name)` / `endBenchPeriod(idx)` bracket timing regions
- `updateBench()` accumulates results per frame
- `startProfiling(seconds)` / `stopProfiling()` trigger a timed profile dump

Profile output goes to kprint (stderr in the C harness, RetroArch log in RA).

Sub-profiling points exist in `DrawPlanes` (per-visplane breakdown) and the
main render path. See `bench.c` for the implementation.

---

## 13. Quick Reference

```bash
# Full rebuild + test ISO
./build_test_iso.sh

# Launch in RetroArch
retroarch -L ~/.config/retroarch/cores/opera_libretro.so /tmp/optidoom_test.iso

# Headless test (captures first non-black frame to /tmp/opera_first_frame.rgb565)
gcc -g -O0 -o /tmp/test_opera /tmp/test_opera.c -ldl
/tmp/test_opera /tmp/optidoom_test.iso 2>/tmp/kprint.log

# Verify ISO boots to game (not Insert CD screen)
# Look for in kprint.log: "Sherry v24.225" and "eventbroker v24.225"
# If you see "Operamath folio 20.53" the v20 OS patch is missing

# Check BLOCKS_ALWAYS in any ISO
python3 -c "
import struct
with open('/tmp/optidoom_test.iso','rb') as f:
    f.seek(0x800); tags = f.read(192)
for i in range(0,192,32):
    if tags[i]==0x0f and tags[i+1]==0x02:
        loc = struct.unpack('>I',tags[i+8:i+12])[0]
        sz  = struct.unpack('>I',tags[i+12:i+16])[0]
        print(f'BLOCKS_ALWAYS: loc={loc} (sector) size={sz} (sectors)')
"

# Rebuild devkit environment from scratch
cd ~/3do-dev && git clone https://github.com/trapexit/3do-devkit.git
set +e; source ~/3do-dev/3do-devkit/activate-env; set -e
armcc --vsn 2>&1 | head -1  # verify

# Normal build (with mod options menu, for manual testing)
./build_test_iso.sh --normal
```
