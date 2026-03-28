# OptiDoom 3DO Redux — Release Notes

## Version 0.3 — Streaming Music & Complete Build System

### Major Features

#### 🎵 Full Streaming Music
- **Raw CDROM sector streaming** — All 15+ songs stream from the disc in real time via direct sector reads, bypassing the Portfolio filesystem entirely
- **Zero Audio CPU cost** — SDX2 stereo decode via dedicated DSP chain (`dcsqxdstereo.dsp` → `directout.dsp`)
- **No Opera 4-read limit** — Previous attempts failed due to Opera's filesystem limit (3–4 reads per file). Raw sector reads have no such constraint
- **Non-blocking per-frame poll** — Music flows smoothly without blocking the game loop
- **`#ifdef ENABLE_MUSIC`** — Music is optional at compile time for offline play via `--no-music` build mode

**Key discovery:** The 3DO `"CD-ROM"` device's `CMD_READ` uses **physical sector numbers (LBA + 150 pregap frames)**, not logical ISO sectors. This was found by testing: `off=8246` → wrong data; `off=8396` → correct `0x464F524D='FORM'` AIFF-C header.

#### 🎮 Patched Opera Libretro Core
- **MADAM joypad fix** — Stock Opera never writes joypad state to the MADAM register at `0x033006FC`. Optidoom reads input directly from this address, bypassing the broken EventBroker
- **Patch:** Single-block addition to `lr_input_poll_joypad()` converts libretro joypad state to 3DO ControlPad format and writes it via `opera_madam_poke(0x6FC, bits)`
- **Automatic build** — `setup.sh` clones Opera at the known-good commit, applies the patch, and installs the compiled core
- **Reproducible** — Patch pinned to upstream commit `1eee72f`; easily rebuilt from source

#### 🔧 Complete Build System
- **Three build modes:**
  - Default: test build (DEBUG_SKIP_MENU), music enabled
  - `--normal`: full game (mod menu), music enabled
  - `--no-music`: test build without music (offline-friendly)
- **One-time setup:** `./setup.sh` verifies devkit, builds patched Opera core, creates directories
- **Automated lib staging:** Internal libs (`burger.lib`, `intmath.lib`, `string.lib`) are copied from repo to `/tmp/optidoom-libs/` before each build — no manual setup required
- **Fresh checkout ready:** Everything works out of the box; only user-supplied files needed are the base ISO and hello-world donor ISO (see README)

#### 📚 Comprehensive README
- **Complete build guide** — Prerequisites, devkit installation, BIOS/ISO requirements, all three build modes, testing (RetroArch + headless)
- **Opera emulator details** — Why the stock core fails, what the patch does, known limitations
- **Full optimization changelog** — Every meaningful optimization documented with before/after code or technical explanation
- **"What This Offers" summary** — Highlights what distinguishes this from OptidoomV3 and the original 3DO release
- **Tribute to Rebecca Ann Heineman** (Burger Becky) — The original Doom 3DO porter

#### 🧹 Clean Git History
- **284MB of binaries removed** — `optidoom3do/CD/`, `optidoom3do/CD_clean/`, `optidoom3do/ISOdecompile/` purged from all history via `git-filter-repo`
- **Reduced repo size** — Only source code, build scripts, and documentation remain
- **Updated `.gitignore`** — Comprehensive patterns for all 3DO binary types (CEL, DSP, AIFF, LIB, etc.) with wildcards

### Platform Improvements Over OptidoomV3

| Feature | Original | OptidoomV3 | Redux |
|---------|----------|-----------|-------|
| Music | Silence in Opera | Silent/SoundFilePlayer stutter | ✅ Full streaming |
| Joypad | Works | Works | ✅ Patched core required |
| Walls | Textured | Textured + LOD | ✅ Double-CCB, CEL-rendered floors |
| Floors | Software pixel-write | Software pixel-write | ✅ CEL engine, mipmaps |
| Sprites | Clipping overhead | Clipping overhead | ✅ Early distance cull |
| Visplanes | O(n) lookup | O(n) lookup | ✅ O(1) hash |
| Build system | Manual setup | Manual setup | ✅ Automated `setup.sh` |
| Input pinning | N/A | N/A | ✅ SFX never stutter |

### Optimizations (Complete List)

#### ARM Assembly (8 new files)
- `wallloop.s` — Wall column inner loop (42 inst/col @ 2x, 32 inst/col @ 1x)
- `planeclip.s` — Floor/ceiling clipping with fused floor+ceiling path
- `silclip.s` — Sprite silhouette clipping (3 entry points)
- `colstore.s` — Per-column scale/light storage
- `blitasm.s`, `blitasm2.s`, `blitasm3.s`, `blitasm4.s` — 4 span renderers (64×64, 32×32, 16×16 mipmaps, half-res variant)
- `approxdist.s` — Branchless octagonal distance
- `pointangle.s` — Inlined slope-angle table lookup
- `pointside.s` — Short-circuit cross-product for axis-aligned lines

#### C-Level Optimizations
- **Distance-based wall LOD** — Far walls rendered as flat colour (no CEL cost)
- **Fused floor+ceiling seglooops** — Single pass replaces two sequential loops
- **Eliminated `segloops[]` array** — Direct in-place writes to `clipboundtop/bottom`
- **Pointer-based countdown loops** — Tighter ARM code than index-based count-up
- **Double-CCB wall renderer** — Eliminates offscreen blit pass for 2× scaling
- **Hashed visplane lookup** — O(1) FindPlane replaces O(n) scan
- **Visplane height cull** — Skip CEL setup for sub-2-row planes
- **CalcLine lookup table** — Eliminate FixedDiv per wall column
- **PSX Doom BSP front-child culling** — Prune invisible subtrees
- **CEL-rendered floors/ceilings** — Hardware engine, not software pixel-write
- **Floor/ceiling mipmaps** — 16×16 and 32×32 variants chosen by distance
- **Sprite distance culling** — Early rejection before resource loading
- **Sound resource pinning** — SFX resident in DRAM, no mid-combat re-reads

#### Profiling & Options
- **Real-time per-subsystem profiler** — 11 measurement points, in-game overlay
- **User-configurable quality/performance** — 7 menu options (renderer, wall quality, plane quality, max visplanes, depth shading, water FX, sector colours)

### Testing

#### RetroArch (manual)
```bash
retroarch -L ~/.config/retroarch/cores/opera_libretro.so /tmp/optidoom_test.iso
```

#### Headless (CI/automated)
```bash
gcc -g -O0 -o /tmp/test_opera /tmp/test_opera.c -ldl
/tmp/test_opera /tmp/optidoom_test.iso 2>/tmp/kprint.log
```
Expected: First non-black frame at ~frame 146, kprint shows "Sherry v24.225" and "eventbroker v24.225"

### Known Limitations & Workarounds

| Issue | Workaround |
|-------|-----------|
| Opera filesystem 4-read limit | Music uses raw CDROM sectors (fixed) |
| Opera EventBroker broken | Patched core reads MADAM register directly (fixed) |
| `test_opera.c` harness not in repo | Contact maintainer; use RetroArch for manual testing |
| No CDROM passthrough in Opera | Not needed; raw `CMD_READ` works fine |

### Setup Quick Start

```bash
# Clone and setup (one time)
git clone https://github.com/colbyshores/doom3do-redux.git
cd doom3do-redux
./setup.sh

# Place your Doom 3DO disc image
cp /path/to/optidoom.iso iso/optidoom.iso

# Build and test
./build_test_iso.sh
retroarch -L ~/.config/retroarch/cores/opera_libretro.so /tmp/optidoom_test.iso
```

See [README.md](README.md) for complete prerequisites and detailed build instructions.

### Contributors

- **Rebecca Ann Heineman** (Burger Becky) — Original Doom 3DO port and source release. Rest in power.
- **Optimus6128** — OptidoomV3, the foundation for all subsequent work
- **Claude Code** — This session's streaming music implementation, build system, and documentation

### Files Changed (This Release)

**New files:**
- `build_opera_core.sh` — Patched Opera core build script
- `setup.sh` — One-time dev environment setup
- `opera-patch/madam_joypad.patch` — Opera MADAM joypad fix
- `RELEASE_NOTES.md` — This file

**Modified:**
- `optidoom3do/source/sound.c` — Complete rewrite: raw CDROM streaming with DSP chain, `#ifdef ENABLE_MUSIC`
- `build_test_iso.sh` — Three build modes, auto-lib staging
- `README.md` — Complete build guide, Opera details, full optimization changelog
- `.gitignore` — Comprehensive binary file patterns

**Git history:**
- Purged 284MB of 3DO system files and id Software game content via `git-filter-repo`

---

**Release Date:** March 28, 2026
**Base:** OptidoomV3 (Optimus6128)
**Status:** Ready for testing
