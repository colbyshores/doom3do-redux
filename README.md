# OptiDoom 3DO Redux

A heavily optimized port of Doom for the 3DO Interactive Multiplayer, built on top of
[OptidoomV3](https://github.com/Optimus6128/optidoom3do) (by Optimus6128) and the original
[Doom 3DO source code](https://github.com/RebeccaAnn/doom3do) released by Rebecca Ann Heineman
of Logicware / Burger Becky.

**Rest in power, Burger Becky.** Rebecca Ann Heineman (1964–2025) reverse-engineered and ported
Doom to the 3DO almost singlehandedly. This project stands on her work.

---

## What This Offers

Over the **original Doom 3DO release** and **OptidoomV3**:

- **Full streaming music** — All 15+ songs stream from the disc in real time via raw CDROM sector
  reads, bypassing the Portfolio filesystem. Zero Audio CPU cost (SDX2 hardware decode via DSP
  chain). Music plays continuously without the Opera emulator's 4-read-per-file limit that
  silenced previous streaming attempts.
- **ARM assembly inner loops** — Wall column renderer, floor/ceiling span renderer, sprite
  silhouette clipping, visplane segloops, BSP helpers — all hand-written ARM assembly replacing
  C loops that Norcroft armcc couldn't optimize well.
- **Double-CCB wall renderer** — The original 2× horizontal scaling used an offscreen blit pass,
  writing every wall column twice via a separate blit. Replaced with two linked CCBs per logical
  column submitted in a single `DrawCels` call, eliminating the offscreen buffer and the entire
  blit pass.
- **Distance-based wall LOD** — Far walls rendered as flat colour fills instead of textured CEL
  columns, cutting CEL engine load in open areas.
- **CEL-rendered floors and ceilings** — Floors and ceilings are rendered via the 3DO's hardware
  CEL engine using span-based texture mapping, rather than the software pixel-write approach used
  by many contemporary ports. The CEL engine handles all pixel blending and output, freeing the
  ARM CPU for game logic and BSP work.
- **Floor/ceiling mipmaps** — Precomputed 16×16 and 32×32 mipmap levels chosen per visplane by
  distance. Fewer DRAM reads per pixel = measurable framerate improvement.
- **Sprite distance culling** — Decorations culled at 1024 units, monsters/items at 1536 units,
  before any resource loading or projection.
- **Hashed visplane lookup** — O(1) FindPlane replaces O(n) linear scan.
- **PSX Doom BSP front-child culling** — Subtree rejection before recursion.
- **Sound effect pinning** — SFX lumps are kept resident in DRAM after first load. The original
  re-read from the slow Opera drive mid-combat, causing visible stutter on every new sound.
- **User-configurable quality options** — Renderer mode, wall quality, floor quality, max
  visplanes, depth shading, water FX, sector colours — all adjustable from the in-game menu.
- **Real-time profiler** — Per-subsystem millisecond timings viewable in-game.

---

## Prerequisites

### System packages

```bash
sudo apt install gcc make python3 python3-pillow git
```

### 3DO Devkit

```bash
mkdir -p ~/3do-dev
cd ~/3do-dev
git clone https://github.com/trapexit/3do-devkit.git
```

No compilation needed — the repo ships pre-built Linux binaries for `armcc`, `armlink`,
`armasm`, `modbin`, and `3DOEncrypt`.

Activate the environment (add this to `~/.bashrc` to make it permanent):

```bash
set +e; source ~/3do-dev/3do-devkit/activate-env; set -e
```

Verify:

```bash
armcc --vsn 2>&1 | head -1
# Expected: Norcroft ARM C v4.91 (ARM Ltd SDT2.51) [Build number 130]
```

### RetroArch + Opera core (patched)

The stock Opera core does not write joypad state to the MADAM register that
Optidoom reads for input. You need the patched core — build it once from the
repo:

```bash
./build_opera_core.sh
```

This clones Opera libretro at the known-good commit, applies
`opera-patch/madam_joypad.patch`, builds it, and installs it to
`~/.config/retroarch/cores/opera_libretro.so`.

Requirements: `gcc`, `make`, `git` (already needed for the devkit).

**Required Opera options** (`~/.config/retroarch/config/Opera/Opera.opt`):

```
opera_bios = "panafz10.bin"
opera_mem_capacity = "21"        # CRITICAL — "3" (default) causes crashes
opera_kprint = "enabled"         # Shows 3DO debug output in RetroArch log
opera_madam_matrix_engine = "hardware"
opera_dsp_threaded = "disabled"
opera_swi_hle = "disabled"
```

### BIOS

Place `panafz10-norsa.bin` (RSA-disabled) in `~/.config/retroarch/system/`.
MD5: `1477bda80dc33731a65468c1f5bcbee9`

Available from 3DO community archives.

### Base ISO (required — not included)

You must own a legitimate copy of **Doom for 3DO**. Provide the disc image as:

```
iso/optidoom.iso
```

This file is gitignored. The build script patches it with a v24.225 OS layer but the
original game content (music, levels, graphics) must come from your own disc.

### v24.225 OS donor ISO

The build system needs a v24 OS source. Any 3DO homebrew disc compiled with the
v24.225 retail SDK works. The easiest option:

```bash
cd ~/3do-dev
git clone https://github.com/trapexit/3do-hello-world.git hello-world
cd hello-world
make   # or follow the repo's own build instructions
# Result: ~/3do-dev/hello-world/iso/helloworld.iso
```

Verify the donor is correct:

```bash
python3 -c "
import struct
with open('$HOME/3do-dev/hello-world/iso/helloworld.iso','rb') as f:
    f.seek(0x800); tags = f.read(192)
for i in range(0,192,32):
    if tags[i]==0x0f and tags[i+1]==0x07:
        loc  = struct.unpack('>I',tags[i+8:i+12])[0]
        sz   = struct.unpack('>I',tags[i+12:i+16])[0]
        print(f'kernel: loc={loc} size={sz}')  # expect loc=5 size=115520
"
```

---

## Building

```bash
# From the repo root:

./build_test_iso.sh             # TEST build: boots to E1M1, music enabled → /tmp/optidoom_test.iso
./build_test_iso.sh --normal    # NORMAL build: shows mod menu, music enabled → /tmp/optidoom_test.iso
./build_test_iso.sh --no-music  # TEST build: boots to E1M1, no music (no disc required)
```

The build script:
1. Sources the 3do-devkit environment
2. Copies `optidoom3do/lib/` libraries to `/tmp/optidoom-libs/`
3. Compiles all `.c` and `.s` sources with `armcc` / `armasm`
4. Links with `armlink` → `optidoom3do/takeme/LaunchMe`
5. Patches the base ISO with the v24.225 OS and the new LaunchMe binary

---

## Testing

### RetroArch (with display)

```bash
retroarch -L ~/.config/retroarch/cores/opera_libretro.so /tmp/optidoom_test.iso
```

### Headless (no display, CI/scripted testing)

```bash
# Build the harness once:
gcc -g -O0 -o /tmp/test_opera /tmp/test_opera.c -ldl

# Run and capture kprint output:
/tmp/test_opera /tmp/optidoom_test.iso 2>/tmp/kprint.log

# Check for successful boot:
grep -E "Sherry|eventbroker|NON-BLACK" /tmp/kprint.log
```

Expected kprint output on success:
```
Sherry  v24.225
...
eventbroker  v24.225
...
FIRST NON-BLACK FRAME at frame 146
```

If you see `Operamath folio 20.53` instead, the v24 OS patch did not apply — check
that your `helloworld.iso` donor has the correct kernel (see Prerequisites above).

---

## Compiler Flags

```
armcc -O1 -bigend -za1 -zi4 -fpu none -arch 3 -apcs "3/32/nofp"

-bigend       big-endian ARM (3DO is big-endian)
-za1          strict aliasing
-zi4          int = 4 bytes
-fpu none     no FPU (3DO ARM60 has none)
-arch 3       ARM architecture v3
-apcs 3/32/nofp  32-bit APCS, no frame pointer
```

---

## Disc Layout Reference

| Sector | Content |
|--------|---------|
| 1–3 | Boot code (v24, from donor ISO) |
| 4 | Boot validator (permissive, from donor ISO) |
| 5–61 | OS kernel v24.225 (from donor ISO) |
| 226 | System folios v24.225 (from donor ISO) |
| 1183 | LaunchMe (compiled binary) |
| 4340+ | Song files (AIFF-C SDX2 stereo) |
| 79446–79574 | 3DO filesystem root directory |

The music streaming code reads Songs directly by physical sector (logical sector + 150
pregap frames) via the raw `"CD-ROM"` device, bypassing the Portfolio filesystem.

---

## Optimization Changelog

Detailed notes on every optimization relative to OptidoomV3 and the original Doom 3DO source.

### ARM Assembly — New Files

#### `wallloop.s` — Textured Wall Column Inner Loop

**Replaces:** C inner loop in `phase6_2.c` (`DrawWallSegment`)

The original C loop suffered from register pressure under `armcc -O1`: the
compiler spilled `CCBPtr`, `DestPtr`, and per-column intermediate values to the
stack each iteration and reloaded them unnecessarily.

Two entry points cover both horizontal scaling modes:

- `DrawWallInnerDouble_ASM` — 2x1 scaled path (RENDERER_DOOM with 2× horizontal
  stretch). Writes two CCBs per logical column (at `xPos*2` and `xPos*2+1`).
  42 instructions per column.
- `DrawWallInner1x_ASM` — 1x1 path. Writes one CCB per column. 32 instructions
  per column.

All 7 per-column CCB fields (XPos, YPos, HDY, PIXC, PRE0, PRE1, SourcePtr) are
written in a single pass. Loop invariants (texBitmap, texWidth, texHeight,
screenCenterY, etc.) are kept in `v1`–`v8` across iterations, eliminating all
reload overhead.

---

#### `planeclip.s` — Floor and Ceiling Visplane Span Setup

**Replaces:** C per-column loops in the original floor/ceiling clipping code

Three entry points handle all clipping combinations without branching at the
call site:

- `SegLoopFloor_ASM` — floor-only
- `SegLoopCeiling_ASM` — ceiling-only
- `SegLoopFloorCeiling_ASM` — fused floor + ceiling in a single pass

The fused variant halves the per-column overhead for walls that contribute both
a floor and a ceiling opening (the common case in most rooms). The per-column
scale is computed from a linear `LeftScale + ScaleStep` accumulator, avoiding
the multiply-every-column pattern in the original code.

---

#### `silclip.s` — Sprite Silhouette Clipping

**Replaces:** C sprite silhouette clip loops

Three entry points mirror the planeclip structure:

- `SegLoopSpriteClipsBottom` — bottom silhouette only
- `SegLoopSpriteClipsTop` — top silhouette only
- `SegLoopSpriteClipsBoth` — fused single pass when all four clip bits are set

The fused path (`AC_BOTTOMSIL | AC_NEWFLOOR | AC_TOPSIL | AC_NEWCEILING`) is the
hot path in dense scenes. A single loop replaces two sequential loops, reducing
per-column overhead by roughly half for that case.

---

#### `colstore.s` — Per-Column Scale and Light Storage (`ColStoreFused_ASM`)

**Replaces:** C per-column loop in `phase6_2.c` (`prepColumnStoreData`)

The wall renderer uses a two-pass approach: a first pass computes scale and
light per column and writes them to the `ColumnStore` array; a second pass reads
them back during actual CCB construction. `ColStoreFused_ASM` eliminates the C
loop overhead for the first pass by keeping the loop state (`scalefrac`,
`lightcoef`, pointers) in registers throughout.

`lightmax` is kept in `v8` across all iterations so the clamp comparison never
touches memory.

---

#### `blitasm.s`, `blitasm2.s`, `blitasm3.s`, `blitasm4.s` — Floor/Ceiling Span Renderers

**Replaces:** The original single `DrawASpan` function

Four dedicated span renderers for different texture resolutions:

| Function | Texture | Sampling |
|---|---|---|
| `DrawASpan` | 64×64 | Full resolution, 1:1 pixel |
| `DrawASpanLo` | 64×64 | Half vertical resolution (skip alternate rows) |
| `DrawASpanLo32` | 32×32 mipmap | Quarter area vs full |
| `DrawASpanLo16` | 16×16 mipmap | 1/16th area vs full |

The mipmap renderers (`DrawASpanLo16`, `DrawASpanLo32`) use a jump table on
entry to jump directly into an unrolled loop body, eliminating the per-pixel
conditional branch that a single generic renderer would need. Bit masks and
shifts are baked in as immediates per variant.

The half-res `DrawASpanLo` renderer writes one pixel every two output pixels,
halving DRAM read bandwidth at the cost of visual resolution — a net win when
the floor is distant or the frame budget is tight.

---

#### `approxdist.s` — Approximate 2D Distance

**Replaces:** C `GetApproxDistance` with branches

Computes `max(|dx|,|dy|) + min(|dx|,|dy|)/2` (octagonal approximation) using
fully branchless ARM conditional execution. The original C version had four
branch-based absolute value and min/max operations; each branch on the ARM60
costs 3 pipeline flush cycles. The ASM uses `CMP`/`RSBMI` for absolute value and
`CMP`/`MOVLT`/`MOVGT` for the min/max selection — no taken branches in the hot
path.

---

#### `pointangle.s` — Two-Point Angle Calculation (`PointToAngle`)

**Replaces:** C `PointToAngle` called frequently from BSP and sprite code

The original C version went through a slope-angle lookup with explicit octant
if/else chains. The ASM version:

- Inlines the `SlopeAngle` slope-to-angle table lookup to avoid a function call
- Uses an 8-entry branch table dispatched via `ADD pc, v2, v2, LSL #2` (2
  instructions) for octant selection
- Replaces all `if/else` octant comparisons with `MOVHI`/`MOVLS` conditional
  moves — no pipeline flushes on common octants

---

#### `pointside.s` — Point-on-Line Side Test (`PointOnVectorSide`)

**Replaces:** C `PointOnVectorSide` called from BSP traversal every frame

The cross-product `dy*(px-x) - dx*(py-y)` can be short-circuited in common
cases:

- Vertical lines (`dx == 0`): result sign equals `dy * (px-x)` sign, testable
  with one `EOR` and a sign check
- Horizontal lines (`dy == 0`): symmetric early out
- Compound sign: an `EOR` chain of the four sign bits identifies cases where the
  full multiply is unnecessary

Only the uncommon case (non-axis-aligned segment, signs don't shortcut) performs
the full `(dy>>16)*(px>>16) - (dx>>16)*(py>>16)` multiplication. All branches
use ARM conditional execution to avoid pipeline stalls.

---

### C-Level Optimizations

#### Distance-Based Wall LOD (`phase6.c` — `prepHeuristicSegInfo`)

**New system; not present in original or OptidoomV3**

Before drawing any walls, each visible wall segment is classified by distance
from the player:

| Class | Distance | Meaning |
|---|---|---|
| `VW_DISCARD` | Any, width < 2px | Too narrow to render a CCB |
| `VW_FAR` | > 768 units | Distant — use flat colour fill |
| `VW_MID` | 384–768 units | Mid-range — optional LOD |
| `VW_CLOSE` | < 384 units | Near — full quality |

`VW_DISCARD` walls are filled with the wall's average colour rather than being
skipped entirely. Skipping them entirely would leave visible gaps (Hall of
Mirrors effect) because the 3DO framebuffer is not pre-cleared each frame.

---

#### Fused Floor+Ceiling Segloop Dispatch (`phase6_1.c`)

**Replaces:** Separate sequential floor and ceiling passes per wall segment

When a wall segment contributes both a floor opening and a ceiling opening (the
common case in enclosed rooms), the original code made two separate passes over
the same column range. A dispatch check at the `SegLoop` call site now selects
the fused `SegLoopFloorCeiling_ASM` variant, processing both in one pass and
cutting the per-wall column loop overhead in half for that case.

---

#### Eliminated `segloops[]` Intermediate Array (`phase6_1.c`)

**Was:** Each segloop recorded results into a temporary `segloops[]` array which
was then read back by a second pass.

**Now:** Results are written directly to `clipboundtop[]` / `clipboundbottom[]`
in-place. The intermediate array and the second read-back pass are gone, saving
both the write-then-read round-trip and the array storage.

---

#### `PrepareSegLoop` Pointer-Based Count-Down Loop (`phase6_1.c`)

**Replaces:** Index-based count-up loop initialising clip bound arrays

```c
// Before (index-based):
for (i = 0; i < ScreenWidth; i++) { clipboundtop[i] = -1; clipboundbottom[i] = ScreenHeight; }

// After (pointer-based count-down):
do { *top++ = -1; *bot++ = ScreenHeight; } while (--count);
```

The count-down `SUBS`+`BNE` pattern produces tighter ARM code than `ADD`+
`CMP`+`BLE`. A minor change but the loop runs once per frame at 320 iterations.

---

#### Double-CCB Wall Renderer for 2× Horizontal Scaling (`phase6_2.c`)

**Replaces:** An offscreen blit that rendered each logical column to a temporary
buffer and then blitted it to two adjacent screen columns

The original 2x1 scaling approach (making the 280-column game fill a 320-column
screen) required writing every wall column twice via a blit. The replacement
pre-computes two linked CCBs per logical column — one at `xPos*2`, one at
`xPos*2+1` — and submits both to the CEL engine in a single `DrawCels` call.
This eliminates the offscreen buffer, the blit pass, and all the associated
DRAM traffic.

---

#### `MapPlane` Table Pointer Caching (`phase7.c`)

**Replaces:** Repeated global variable loads inside the per-span loop

```c
// Before: each span iteration reloaded distscale, xtoviewangle, etc. from globals
// After: cached as const locals before the loop
const Word    *ds    = distscale;
const angle_t *xtova = xtoviewangle;
const Fixed   *fcos  = finecosine;
const Fixed   *fsin  = finesine;
const angle_t  va    = viewangle;
const SpanDrawFn drawFunc = spanDrawFunc;
```

Under `armcc -O1`, global variable reads are not always CSE'd across function
calls (the compiler cannot prove the `drawFunc` call doesn't mutate globals).
Caching them as `const` locals before the loop gives the compiler evidence to
keep them in registers.

---

#### Span Init Count-Down Loops (`phase7.c` — `initVisplaneSpanData*`)

**Replaces:** Index-based count-up loops in all four `initVisplaneSpanData`
variants

All four functions (`initVisplaneSpanDataTextured`,
`initVisplaneSpanDataTexturedUnshaded`, `initVisplaneSpanDataFlat`,
`initVisplaneSpanDataFlatDithered`) were converted to pointer-based count-down
loops for the same reason as `PrepareSegLoop` above: tighter `SUBS`+`BNE` ARM
loop control.

---

#### Multi-Resolution Floor/Ceiling Mipmaps (`phase7.c`)

**New system; not present in original or OptidoomV3**

Before rendering each visplane, `DrawVisPlaneHorizontal` checks the plane's
effective height (a proxy for distance) and selects the smallest texture that
still looks acceptable:

| Height threshold (default / medium quality) | Texture chosen | Renderer |
|---|---|---|
| < 12 / 24 | 16×16 mipmap | `DrawASpanLo16` |
| < 40 / 60 | 32×32 mipmap | `DrawASpanLo32` |
| Otherwise | 64×64 full texture | `DrawASpanLo` |

Smaller textures mean fewer DRAM reads per span pixel. Since the 3DO has no data
cache, DRAM bandwidth is the primary bottleneck in `DrawASpan*`. A 16×16 mipmap
reads 1/16th the texture data of a full 64×64 texture per pixel, giving a
substantial speed-up for distant floors with no visible quality degradation at
distance.

The mipmaps are precomputed at level-load time and stored as separate DRAM
allocations contiguous with the full texture so they benefit from spatial
locality.

---

#### Visplane Minimum Height Cull (`phase7.c` / `phase6.c`)

**New; not present in original or OptidoomV3**

Visplanes covering fewer than 2 rows are discarded before entering
`DrawVisPlaneHorizontal`. On the 3DO, the per-visplane setup cost (CEL array
configuration, palette upload) is high enough that very thin planes cost more to
set up than they contribute visually.

The check was hoisted to the `DrawVisPlane` call site so the function is never
entered for empty planes, eliminating the function-call and branch overhead
entirely for that case.

---

#### Hashed `FindPlane` with Pre-Allocated Visplane Pool (`phase6_1.c` / BSP)

**Replaces:** Linear O(n) scan through the visplane array on every `AddLine` call

`FindPlane` is called for every wall segment that exposes a floor or ceiling
during BSP traversal — potentially hundreds of calls per frame. A hash on the
`(texnum, height, light)` key reduces the average lookup from O(n) to O(1) for
the common case where the same plane has already been opened.

---

#### PSX Doom BSP Front-Child Optimisation (`rmain.c`)

**Backported from:** PSX Doom source

Before recursing into the BSP tree to render a node's children, the renderer now
checks whether the *front child's bounding box* is even visible before
descending. If the front subtree is entirely behind the player or outside the
view frustum, the recursion is skipped entirely. This prunes large subtrees in
scenes with many back-facing BSP nodes.

---

#### `CalcLine` Lookup Table (`rmain.c` / wall setup)

**Replaces:** Per-wall `FixedDiv` calls computing column scale from angle

A precomputed lookup table maps screen-x column to the reciprocal-of-cosine
value needed for the column scale calculation. Eliminates a `FixedDiv` (software
division — expensive on ARM with no hardware divide) per wall column during BSP
add-line processing.

---

#### Global View Variable Caching Across BSP (`rmain.c`)

**Replaces:** Repeated `viewx`, `viewy`, `viewangle`, `viewcos`, `viewsin`
global reads inside tight BSP loops

View parameters do not change during a single frame's BSP traversal. Caching
them as `const` locals at the top of the traversal function allows `armcc -O1`
to keep them in registers for the duration of the traversal, eliminating dozens
of redundant global loads per frame.

---

#### Sprite Distance Culling (`phase1.c`)

**New; not present in original or OptidoomV3**

All sprite objects are tested against a distance threshold before any CCB
setup or resource loading occurs (`PrepMObj`, lines 128–140):

| Object class | Flags tested | Cull distance |
|---|---|---|
| Decorations | none of the below | 1024 units |
| Monsters / items / barrels | `MF_SHOOTABLE`, `MF_COUNTKILL`, `MF_SPECIAL` | 1536 units |
| Projectiles | `MF_MISSILE` | never culled |

Projectiles are exempt because a fireball the player can't see but that can
still hit them must remain in the game simulation. Monsters and interactive
objects get a longer draw distance than pure decorations because they affect
gameplay. Both thresholds keep the objects well within the player's effective
engagement range — at 1536 units a monster is a handful of pixels tall and
at 1024 units a lamp is subpixel.

This culling fires before `LoadAResourceHandle`, so resource loading, sprite
frame lookup, projection, sort insertion, and silhouette clipping are all
avoided for culled objects. It is the earliest possible rejection point in
the sprite pipeline.

---

#### Line-of-Sight Ray Precomputation (`sight.c`)

**Replaces:** Per-call subtraction inside `PS_SightCrossLine`

`CheckSight` is called every game tic for every monster that is in the
"active" state (chasing or attacking). Each call invokes `PS_SightCrossLine`
once per BSP line segment crossed by the sight ray. In the original code,
`PS_SightCrossLine` recomputed `sightdx = t2x - t1x` and `sightdy = t2y - t1y`
on every entry even though these are constant for a given sight check.

They are now computed once in `CheckSight` and stored in globals `sightdx` /
`sightdy` before the traversal begins. Minor saving per call, meaningful in
aggregate when many monsters are active.

---

#### `ScaleFromGlobalAngle` Inlining

**Replaces:** Function call to `ScaleFromGlobalAngle` per wall segment

`ScaleFromGlobalAngle` computes the reciprocal-depth scale for a wall column
from the global view angle and the wall's normal angle. It was inlined at the
`AddLine` call site so the compiler can keep intermediate values in registers
across the wall processing sequence rather than round-tripping through the
function call ABI.

---

#### Sound Resource Pinning

**New; not in original**

Sound effect lumps are pinned in DRAM after first load rather than being paged
out and reloaded from disc. The 3DO's Opera disc drive is slow; re-reading a
sound lump mid-combat causes a visible stutter. Pinning keeps all commonly-used
SFX resident at the cost of a fixed DRAM allocation.

---

### Streaming Music

#### Raw CDROM Sector Streaming (`sound.c`)

**New; replaces silence in emulator and stuttering SoundFilePlayer approach**

All songs stream from the disc in real time:

- **"CD-ROM" device** — `FindAndOpenDevice("CD-ROM")` + `CMD_READ` gives
  unlimited sequential reads with no per-file limit. Physical sector addressing
  (`logical_sector + 150` pregap) bypasses the Portfolio filesystem entirely.
- **SDX2 hardware decode** — `dcsqxdstereo.dsp` → `directout.dsp` DSP chain.
  Compressed SDX2 stereo is decoded in hardware at zero ARM CPU cost.
- **Non-blocking per-frame poll** — `GetCurrentSignals()` + `WaitSignal()` +
  `ssplProcessSignals()` keeps music flowing without blocking the game loop.
- **`#ifdef ENABLE_MUSIC`** — Music is gated at compile time. Build with
  `--no-music` for an offline-friendly binary.

---

### Profiling Infrastructure

#### Real-Time Per-Subsystem Profiler (`bench.c`, `bench.h`)

**New; not present in original or OptidoomV3**

An always-available profiling overlay accessible from the mod options menu:

- `startProfiling(seconds)` begins a timed accumulation window
- `startBenchPeriod(idx, name)` / `endBenchPeriod(idx)` bracket any code path
- `updateBench()` draws the results on-screen each frame as labelled bars and
  millisecond timings

Eleven active measurement points: BSP, StartSegLoop, DrawWalls, DrawPlanes,
DrawSprites, ColStore, FloorPlane, CeilPlane, SpriteSil, Sky, PlaneInit,
PlaneSpans.

---

## User-Selectable Quality / Performance Options (Mod Menu)

| Option | Values | Effect |
|---|---|---|
| Renderer | DOOM / Polygon | DOOM: textured walls via ColumnStore+ASM. Polygon: flat-shaded polys, lower fidelity but faster at high wall counts |
| Wall quality | Hi / Lo | Hi: full textured walls. Lo: flat colour-filled walls (near-zero CCB cost) |
| Plane quality | Hi / Lo | Hi: full-res `DrawASpan`. Lo: half-res `DrawASpanLo` (skips alternate rows) |
| Max visplanes | 16–96 | Caps the floor/ceiling plane count; lowers memory and segloop cost in open areas |
| Depth shading | Off / On / Dithered | Per-distance lighting; Off is fastest |
| Water FX | On / Off | Warp scroll effect on liquid sectors |
| Sector colours | On / Off | PSX-style RGB sector tinting |
