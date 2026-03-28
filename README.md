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

- **CEL-rendered floors and ceilings** — Floors and ceilings rendered via the 3DO's hardware CEL
  engine using span-based texture mapping. The CEL engine handles all pixel output, freeing the
  ARM CPU for game logic and BSP work.
- **Working streaming music in emulation** — The original used `SoundFilePlayer` through the
  Portfolio filesystem, which works on hardware but is completely silent in Opera emulation
  (Opera's 4-read-per-file limit breaks it). Replaced with raw CDROM sector reads via
  `FindAndOpenDevice("CD-ROM")`, bypassing the filesystem entirely. Zero audio CPU cost — SDX2
  stereo is decoded in hardware by the DSP chain.
- **ARM assembly inner loops** — Wall column renderer, floor/ceiling span renderer, sprite
  silhouette clipping, visplane segloops, BSP helpers — hand-written ARM assembly replacing C
  loops that Norcroft armcc couldn't optimize well.
- **Double-CCB wall renderer** — Two linked CCBs per logical column replace the original offscreen
  blit pass, eliminating the blit buffer and all associated DRAM traffic.
- **Distance-based wall LOD** — Far walls rendered as flat colour fills instead of textured CEL
  columns, cutting CEL engine load in open areas.
- **Floor/ceiling mipmaps** — Precomputed 16×16 and 32×32 mipmap levels chosen per visplane by
  distance. Fewer DRAM reads per pixel on distant floors.
- **Sprite distance culling** — Decorations culled at 1024 units, monsters/items at 1536 units,
  before any resource loading or projection.
- **Hashed visplane lookup** — O(1) FindPlane replaces O(n) linear scan.
- **Patched Opera libretro core** — The stock core never writes joypad state to the MADAM
  register at `0x033006FC`, which OptiDoom reads directly (the Portfolio EventBroker is broken in
  emulation). `opera-patch/madam_joypad.patch` adds one block to `lr_input_poll_joypad()` to fix
  this. Built and installed automatically on first run.
- **User-configurable rendering quality** — Wall quality, floor quality, and max visplanes
  adjustable from the in-game menu.
- **Real-time profiler** — Per-subsystem millisecond timings viewable in-game.

---

## CEL Floor and Ceiling Architecture

The original Doom 3DO and OptidoomV3 had no textured floors or ceilings at all — just solid
fills. This project adds them using the same CEL-strip approach the original used for walls,
rotated 90 degrees.

**Walls** use vertical 1-pixel-wide column CELs — one CCB per screen column, each containing
a perspective-projected vertical slice of the wall texture.

**Floors and ceilings** use horizontal 1-pixel-tall span CELs — one CCB per scanline, each
containing a perspective-correct horizontal slice of the flat texture. The 3DO hardware sees
a linked list of pre-rendered bitmap CCBs either way. All the math runs on the ARM CPU; the
CEL engine just blits.

### Visplane discovery

During wall scanning, visible floor/ceiling regions are collected into `visplane_t` structs.
Each has an `open[]` array encoding `top<<8 | bottom` for every screen column — the Y range
visible at each X. Planes with identical height, texture, light, and special effects are merged.

### Projection math

`InitMathTables()` in `rdata.c` precomputes two key tables used to turn screen pixels into
world-space texture coordinates:

- `yslope[y]` — distance factor per row: `StretchWidth / abs(y - CenterY)`
- `distscale[x]` — perspective correction per column: `1 / abs(cos(viewangle_for_column_x))`

### Span generation

`DrawVisPlaneHorizontal()` in `phase7.c` walks each visplane column by column. When `open[]`
changes, it emits a horizontal span. For each span at scanline `y`:

```c
distance = (yslope[y] * PlaneHeight) >> 12;
angle    = (xtoviewangle[x] + viewangle) >> ANGLETOFINESHIFT;
length   = (distscale[x] * distance) >> 14;
xfrac    = ((finecosine[angle] >> 1) * length >> 4) + viewx;
yfrac    = planey - ((finesine[angle] >> 1) * length >> 4);
```

This gives the world-space texture coordinate for the span start, plus per-pixel step values
`ds_xstep` / `ds_ystep`.

### Texture sampling (assembly)

`DrawASpan` in `blitasm.s` runs the inner loop. Per pixel:

1. Combines upper bits of `yfrac` and `xfrac` into a 10-bit index into the 64×64 texture
   (6 bits each)
2. `LDRB pixel, [textureBase, index]`
3. Increments both fractional coordinates
4. Stores to `SpanArray`

### CEL CCB setup

Each rendered span becomes a 1-pixel-tall CEL strip. `MapPlane()` allocates a CCB from
`CCBArrayPlane[]`, points its source at the rendered pixels in `SpanArray`, and sets:

- `ccb_XPos` / `ccb_YPos` — screen position
- `ccb_PRE1` — strip width encoded as `(count - 1)`
- `ccb_PIXC` — light/shade value for this distance

CCBs are linked into a chain and submitted in one `DrawCels()` call per visplane.

### Flat and dithered modes

For lower quality settings, no texture sampling occurs. Each scanline becomes a solid-colour
rectangle CCB with `ccb_PLUTPtr` set to the flat colour. The dithered variant alternates
between two PIXC shading values based on distance for a checkerboard depth-shading effect.

---

## Prerequisites

### 3DO Devkit

```bash
mkdir -p ~/3do-dev && cd ~/3do-dev
git clone https://github.com/trapexit/3do-devkit.git
```

Ships pre-built Linux binaries — no compilation. Activate it (add to `~/.bashrc`):

```bash
set +e; source ~/3do-dev/3do-devkit/activate-env; set -e
```

### System packages

```bash
sudo apt install gcc make python3 git retroarch
```

### Base ISO (required — not included)

You must own a legitimate copy of **Doom for 3DO**. Place the disc image at:

```
iso/optidoom.iso
```

The build script patches in a v24.225 OS layer, but the original game content must come
from your own disc.

---

## Building

```bash
./build.sh                  # TEST: boots to E1M1, music enabled
./build.sh --normal         # NORMAL: shows mod menu, music enabled
./build.sh --no-music       # TEST: E1M1 auto-boot, no music
./build.sh --hardware       # Build + sign for real 3DO hardware
```

On the first run, `build.sh` automatically verifies the devkit, builds the patched Opera
core, and fetches the v24.225 OS components. Subsequent builds go straight to compilation.

**Emulator output:** `/tmp/optidoom_test.iso`
Load it in RetroArch with the Opera core. Set `opera_mem_capacity = "21"` — the default
of `"3"` causes crashes.

**Hardware output** (`--hardware`): `/tmp/optidoom_hw.iso`
Signed with `3DOEncrypt genromtags`. Burn to CD-R (Mode 1, 2048-byte sectors) or use an ODE.
Can be combined: `./build.sh --normal --hardware`

---

## Disc Layout Reference

| Sector | Content |
|--------|---------|
| 1–3 | Boot code (v24, from v24_base.iso) |
| 4 | Boot validator (permissive, from v24_base.iso) |
| 5–61 | OS kernel v24.225 |
| 226 | System folios v24.225 |
| 1183 | LaunchMe (compiled binary) |
| 4340+ | Song files (AIFF-C SDX2 stereo) |
| 79446–79574 | 3DO filesystem root |

`iso/v24_base.iso` is built automatically from the 3do-devkit's v24 OS files. No commercial
content. Music is streamed by physical sector address (`logical + 150` pregap), bypassing the
Portfolio filesystem to avoid Opera's per-file read limit.

---

## Optimization Changelog

### ARM Assembly — New Files

#### `wallloop.s` — Textured Wall Column Inner Loop

**Replaces:** C inner loop in `phase6_2.c` (`DrawWallSegment`)

The original C loop suffered from register pressure under `armcc -O1`: the compiler spilled
`CCBPtr`, `DestPtr`, and per-column intermediate values to the stack each iteration.

Two entry points:

- `DrawWallInnerDouble_ASM` — 2×1 scaled path. Writes two CCBs per logical column
  (`xPos*2` and `xPos*2+1`). 40 instructions per column.
- `DrawWallInner1x_ASM` — 1×1 path. 32 instructions per column.

All 7 per-column CCB fields are written in a single pass. Loop invariants are kept in
`v1`–`v8` across iterations, eliminating all reload overhead.

---

#### `planeclip.s` — Floor and Ceiling Visplane Span Setup

**Replaces:** C per-column loops in the floor/ceiling clipping code

Three entry points:

- `SegLoopFloor_ASM` — floor-only
- `SegLoopCeiling_ASM` — ceiling-only
- `SegLoopFloorCeiling_ASM` — fused floor + ceiling in a single pass

The fused variant halves the per-column overhead for walls that expose both a floor and a
ceiling opening (the common case). Per-column scale is computed from a linear
`LeftScale + ScaleStep` accumulator, avoiding the multiply-every-column pattern in the
original code.

---

#### `silclip.s` — Sprite Silhouette Clipping

**Replaces:** C sprite silhouette clip loops

Three entry points mirroring the planeclip structure:

- `SegLoopSpriteClipsBottom`
- `SegLoopSpriteClipsTop`
- `SegLoopSpriteClipsBoth` — fused single pass when all four clip bits are set

The fused path (`AC_BOTTOMSIL | AC_NEWFLOOR | AC_TOPSIL | AC_NEWCEILING`) is the hot
path in dense scenes, replacing two sequential loops with one.

---

#### `colstore.s` — Per-Column Scale and Light Storage (`ColStoreFused_ASM`)

**Replaces:** C per-column loop in `phase6_2.c` (`prepColumnStoreData`)

Keeps the loop state (`scalefrac`, `lightcoef`, pointers) in registers throughout.
`lightmax` stays in `v8` across all iterations so the clamp comparison never touches memory.

---

#### `blitasm.s`, `blitasm2.s`, `blitasm3.s`, `blitasm4.s` — Floor/Ceiling Span Renderers

**Replaces:** The original single `DrawASpan` function

Four dedicated span renderers for different texture resolutions:

| Function | Texture | Sampling |
|---|---|---|
| `DrawASpan` | 64×64 | Full resolution, 1:1 pixel |
| `DrawASpanLo` | 64×64 | Half vertical resolution |
| `DrawASpanLo32` | 32×32 mipmap | |
| `DrawASpanLo16` | 16×16 mipmap | |

The mipmap renderers use a jump table on entry to jump into an unrolled loop body, eliminating
the per-pixel conditional branch a generic renderer would need. Bit masks and shifts are baked
in as immediates per variant.

---

#### `approxdist.s` — Approximate 2D Distance

**Replaces:** C `GetApproxDistance` with branches

Computes `max(|dx|,|dy|) + min(|dx|,|dy|)/2` using fully branchless ARM conditional execution.
The original C version had four branch-based abs/min/max operations; each taken branch on the
ARM60 costs 3 pipeline flush cycles. The ASM uses `CMP`/`RSBMI` for abs and
`CMP`/`MOVLT`/`MOVGT` for min/max — no taken branches in the hot path.

---

#### `pointangle.s` — Two-Point Angle Calculation (`PointToAngle`)

**Replaces:** C `PointToAngle` with explicit octant if/else chains

- Inlines the `SlopeAngle` table lookup to avoid a function call
- Dispatches octant via `ADD pc, v2, v2, LSL #2` (2 instructions)
- Replaces all octant comparisons with `MOVHI`/`MOVLS` conditional moves

---

#### `pointside.s` — Point-on-Line Side Test (`PointOnVectorSide`)

**Replaces:** C `PointOnVectorSide` from BSP traversal

The cross-product `dy*(px-x) - dx*(py-y)` is short-circuited for:

- Vertical lines (`dx == 0`): one `EOR` + sign check
- Horizontal lines (`dy == 0`): symmetric early out
- Sign-matching cases: `EOR` chain of four sign bits

Only the uncommon non-axis-aligned case performs the full multiply.

---

### C-Level Optimizations

#### Distance-Based Wall LOD (`phase6.c` — `prepHeuristicSegInfo`)

Each visible wall segment is classified before drawing:

| Class | Distance | Rendering |
|---|---|---|
| `VW_DISCARD` | Any, width < 2px | Flat colour fill (skipping would leave gaps) |
| `VW_FAR` | > 768 units | Flat colour fill |
| `VW_MID` | 384–768 units | Optional LOD |
| `VW_CLOSE` | < 384 units | Full textured |

`VW_DISCARD` walls are filled with the wall's average colour rather than skipped. Skipping
entirely would cause Hall-of-Mirrors artifacts because the 3DO framebuffer is not pre-cleared
each frame.

---

#### Fused Floor+Ceiling Segloop Dispatch (`phase6_1.c`)

When a wall segment exposes both a floor and a ceiling (the common case), the original code
made two separate passes. A dispatch check now selects `SegLoopFloorCeiling_ASM`, processing
both in one pass and halving per-wall column loop overhead.

---

#### Eliminated `segloops[]` Intermediate Array (`phase6_1.c`)

Results are written directly to `clipboundtop[]` / `clipboundbottom[]` in-place. The
intermediate array and second read-back pass are gone.

---

#### `PrepareSegLoop` Pointer-Based Count-Down Loop (`phase6_1.c`)

```c
// Before:
for (i = 0; i < ScreenWidth; i++) { clipboundtop[i] = -1; clipboundbottom[i] = ScreenHeight; }

// After:
do { *top++ = -1; *bot++ = ScreenHeight; } while (--count);
```

The `SUBS`+`BNE` pattern is tighter than `ADD`+`CMP`+`BLE` on ARM. Runs once per frame at
320 iterations.

---

#### Double-CCB Wall Renderer for 2× Horizontal Scaling (`phase6_2.c`)

The original 2×1 scaling wrote every wall column twice via an offscreen blit. Replaced with
two pre-computed linked CCBs per logical column (`xPos*2` and `xPos*2+1`) submitted in a
single `DrawCels` call. Eliminates the offscreen buffer and all associated DRAM traffic.

---

#### `MapPlane` Table Pointer Caching (`phase7.c`)

```c
// Cached as const locals before the span loop:
const Word    *ds    = distscale;
const angle_t *xtova = xtoviewangle;
const Fixed   *fcos  = finecosine;
const Fixed   *fsin  = finesine;
const angle_t  va    = viewangle;
const SpanDrawFn drawFunc = spanDrawFunc;
```

Under `armcc -O1`, global reads are not CSE'd across function calls (the compiler can't prove
`drawFunc` doesn't mutate globals). `const` locals give it the evidence to keep them in
registers.

---

#### Span Init Count-Down Loops (`phase7.c` — `initVisplaneSpanData*`)

All four `initVisplaneSpanData` variants converted to pointer-based count-down loops for the
same reason as `PrepareSegLoop`.

---

#### Multi-Resolution Floor/Ceiling Mipmaps (`phase7.c`)

`DrawVisPlaneHorizontal` selects the smallest acceptable texture before rendering each visplane:

| Height threshold (default / medium quality) | Texture | Renderer |
|---|---|---|
| < 12 / 24 | 16×16 mipmap | `DrawASpanLo16` |
| < 40 / 60 | 32×32 mipmap | `DrawASpanLo32` |
| Otherwise | 64×64 full | `DrawASpanLo` |

The 3DO has no data cache — DRAM bandwidth is the primary bottleneck in `DrawASpan*`. A 16×16
mipmap reads 1/16th the texture data of a full 64×64 per pixel. Mipmaps are precomputed at
level-load time, stored contiguous with the full texture for spatial locality.

---

#### Visplane Minimum Height Cull (`phase7.c` / `phase6.c`)

Visplanes covering fewer than 2 rows are discarded before entering `DrawVisPlaneHorizontal`.
The per-visplane setup cost on 3DO is high enough that very thin planes cost more to configure
than they contribute visually.

---

#### Hashed `FindPlane` with Pre-Allocated Visplane Pool (`phase6_1.c`)

`FindPlane` is called for every wall segment that exposes a floor or ceiling during BSP
traversal. A hash on `(texnum, height, light)` reduces the average lookup from O(n) to O(1).

---

#### `CalcLine` Lookup Table (`rmain.c`)

A precomputed table maps screen-x column to the reciprocal-of-cosine needed for the column
scale calculation, eliminating a `FixedDiv` per wall column during BSP add-line processing.
`FixedDiv` is a software division — expensive on ARM with no hardware divide.

---

#### Global View Variable Caching Across BSP (`rmain.c`)

`viewx`, `viewy`, `viewangle`, `viewcos`, `viewsin` are cached as `const` locals at the top
of BSP traversal. They don't change mid-frame; `const` locals let `armcc -O1` keep them in
registers for the full traversal rather than reloading from globals.

---

#### Sprite Distance Culling (`phase1.c`)

All sprite objects are tested against a distance threshold before any CCB setup or resource
loading:

| Object class | Cull distance |
|---|---|
| Decorations | 1024 units |
| Monsters / items / barrels | 1536 units |
| Projectiles | never culled |

Projectiles are exempt because they affect gameplay regardless of visibility. Culling fires
before `LoadAResourceHandle` — the earliest possible rejection point in the sprite pipeline.

---

#### Line-of-Sight Ray Precomputation (`sight.c`)

`PS_SightCrossLine` previously recomputed `sightdx = t2x - t1x` and `sightdy = t2y - t1y`
on every entry. These are constant for a given sight check. Computed once in `CheckSight`,
stored in `sightdx` / `sightdy` before traversal.

---

#### `ScaleFromGlobalAngle` Inlining

Inlined at the `AddLine` call site so the compiler keeps intermediate values in registers
across the wall processing sequence rather than round-tripping through the function call ABI.

---

### Streaming Music

#### Raw CDROM Sector Streaming (`sound.c`)

**Replaces:** `SoundFilePlayer` via Portfolio filesystem, which works on hardware but is silent
in Opera emulation due to the 4-read-per-file limit

- `FindAndOpenDevice("CD-ROM")` + `CMD_READ` — unlimited sequential reads, no per-file limit.
  Physical sector addressing (`logical_sector + 150` pregap) bypasses the Portfolio filesystem.
- `dcsqxdstereo.dsp` → `directout.dsp` DSP chain — SDX2 stereo decoded in hardware at zero
  ARM CPU cost.
- Non-blocking per-frame poll via `GetCurrentSignals()` + `WaitSignal()` + `ssplProcessSignals()`.
- Gated at compile time with `#ifdef ENABLE_MUSIC`. Build with `--no-music` if no disc is present.

---

### Profiling Infrastructure

#### Real-Time Per-Subsystem Profiler (`bench.c`, `bench.h`)

Accessible from the mod options menu:

- `startProfiling(seconds)` — begin a timed accumulation window
- `startBenchPeriod(idx, name)` / `endBenchPeriod(idx)` — bracket any code path
- `updateBench()` — draws labelled bars and millisecond timings each frame

Twelve measurement points: BSP, StartSegLoop, DrawWalls, DrawPlanes, DrawSprites, ColStore,
FloorPlane, CeilPlane, SpriteSil, Sky, PlaneInit, PlaneSpans.

---

## In-Game Quality Options (Added by This Project)

| Option | Values | Effect |
|---|---|---|
| Wall quality | Hi / Lo | Hi: full textured. Lo: flat colour fill (near-zero CCB cost) |
| Plane quality | Hi / Lo | Hi: full-res `DrawASpan`. Lo: half-res `DrawASpanLo` |
| Max visplanes | 16–96 | Caps plane count; lowers memory and segloop cost in open areas |
