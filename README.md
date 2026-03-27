# OptiDoom 3DO — Optimization Changelog

This document records every meaningful optimization in this codebase relative to
**OptidoomV3** (the community release by Optimus6128) and the original **Doom 3DO
source code** (released by Lobotomy Software / Rebecca Ann Heineman).

The 3DO runs a 12.5 MHz ARM60 with no hardware FPU, no data cache, and a
software-driven CEL engine for all 2D rendering. Every cycle saved is visible.

---

## ARM Assembly — New Files

### `wallloop.s` — Textured Wall Column Inner Loop

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

### `planeclip.s` — Floor and Ceiling Visplane Span Setup

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

### `silclip.s` — Sprite Silhouette Clipping

**Replaces:** C sprite silhouette clip loops

Three entry points mirror the planeclip structure:

- `SegLoopSpriteClipsBottom` — bottom silhouette only
- `SegLoopSpriteClipsTop` — top silhouette only
- `SegLoopSpriteClipsBoth` — fused single pass when all four clip bits are set

The fused path (`AC_BOTTOMSIL | AC_NEWFLOOR | AC_TOPSIL | AC_NEWCEILING`) is the
hot path in dense scenes. A single loop replaces two sequential loops, reducing
per-column overhead by roughly half for that case.

---

### `colstore.s` — Per-Column Scale and Light Storage (`ColStoreFused_ASM`)

**Replaces:** C per-column loop in `phase6_2.c` (`prepColumnStoreData`)

The wall renderer uses a two-pass approach: a first pass computes scale and
light per column and writes them to the `ColumnStore` array; a second pass reads
them back during actual CCB construction. `ColStoreFused_ASM` eliminates the C
loop overhead for the first pass by keeping the loop state (`scalefrac`,
`lightcoef`, pointers) in registers throughout.

`lightmax` is kept in `v8` across all iterations so the clamp comparison never
touches memory.

---

### `blitasm.s`, `blitasm2.s`, `blitasm3.s`, `blitasm4.s` — Floor/Ceiling Span Renderers

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

### `approxdist.s` — Approximate 2D Distance

**Replaces:** C `GetApproxDistance` with branches

Computes `max(|dx|,|dy|) + min(|dx|,|dy|)/2` (octagonal approximation) using
fully branchless ARM conditional execution. The original C version had four
branch-based absolute value and min/max operations; each branch on the ARM60
costs 3 pipeline flush cycles. The ASM uses `CMP`/`RSBMI` for absolute value and
`CMP`/`MOVLT`/`MOVGT` for the min/max selection — no taken branches in the hot
path.

---

### `pointangle.s` — Two-Point Angle Calculation (`PointToAngle`)

**Replaces:** C `PointToAngle` called frequently from BSP and sprite code

The original C version went through a slope-angle lookup with explicit octant
if/else chains. The ASM version:

- Inlines the `SlopeAngle` slope-to-angle table lookup to avoid a function call
- Uses an 8-entry branch table dispatched via `ADD pc, v2, v2, LSL #2` (2
  instructions) for octant selection
- Replaces all `if/else` octant comparisons with `MOVHI`/`MOVLS` conditional
  moves — no pipeline flushes on common octants

---

### `pointside.s` — Point-on-Line Side Test (`PointOnVectorSide`)

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

## C-Level Optimizations

### Distance-Based Wall LOD (`phase6.c` — `prepHeuristicSegInfo`)

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

This single pre-pass classification means the per-wall draw path never needs to
recompute distance; the `renderKind` field is read once per wall during the draw
loop.

---

### Fused Floor+Ceiling Segloop Dispatch (`phase6_1.c`)

**Replaces:** Separate sequential floor and ceiling passes per wall segment

When a wall segment contributes both a floor opening and a ceiling opening (the
common case in enclosed rooms), the original code made two separate passes over
the same column range. A dispatch check at the `SegLoop` call site now selects
the fused `SegLoopFloorCeiling_ASM` variant, processing both in one pass and
cutting the per-wall column loop overhead in half for that case.

---

### Eliminated `segloops[]` Intermediate Array (`phase6_1.c`)

**Was:** Each segloop recorded results into a temporary `segloops[]` array which
was then read back by a second pass.

**Now:** Results are written directly to `clipboundtop[]` / `clipboundbottom[]`
in-place. The intermediate array and the second read-back pass are gone, saving
both the write-then-read round-trip and the array storage.

---

### `PrepareSegLoop` Pointer-Based Count-Down Loop (`phase6_1.c`)

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

### Double-CCB Wall Renderer for 2× Horizontal Scaling (`phase6_2.c`)

**Replaces:** An offscreen blit that rendered each logical column to a temporary
buffer and then blitted it to two adjacent screen columns

The original 2x1 scaling approach (making the 280-column game fill a 320-column
screen) required writing every wall column twice via a blit. The replacement
pre-computes two linked CCBs per logical column — one at `xPos*2`, one at
`xPos*2+1` — and submits both to the CEL engine in a single `DrawCels` call.
This eliminates the offscreen buffer, the blit pass, and all the associated
DRAM traffic.

---

### `MapPlane` Table Pointer Caching (`phase7.c`)

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

### Span Init Count-Down Loops (`phase7.c` — `initVisplaneSpanData*`)

**Replaces:** Index-based count-up loops in all four `initVisplaneSpanData`
variants

All four functions (`initVisplaneSpanDataTextured`,
`initVisplaneSpanDataTexturedUnshaded`, `initVisplaneSpanDataFlat`,
`initVisplaneSpanDataFlatDithered`) were converted to pointer-based count-down
loops for the same reason as `PrepareSegLoop` above: tighter `SUBS`+`BNE` ARM
loop control.

---

### Multi-Resolution Floor/Ceiling Mipmaps (`phase7.c`)

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

### Visplane Minimum Height Cull (`phase7.c` / `phase6.c`)

**New; not present in original or OptidoomV3**

Visplanes covering fewer than 2 rows are discarded before entering
`DrawVisPlaneHorizontal`. On the 3DO, the per-visplane setup cost (CEL array
configuration, palette upload) is high enough that very thin planes cost more to
set up than they contribute visually.

The check was hoisted to the `DrawVisPlane` call site so the function is never
entered for empty planes, eliminating the function-call and branch overhead
entirely for that case.

---

### Hashed `FindPlane` with Pre-Allocated Visplane Pool (`phase6_1.c` / BSP)

**Replaces:** Linear O(n) scan through the visplane array on every `AddLine` call

`FindPlane` is called for every wall segment that exposes a floor or ceiling
during BSP traversal — potentially hundreds of calls per frame. A hash on the
`(texnum, height, light)` key reduces the average lookup from O(n) to O(1) for
the common case where the same plane has already been opened.

---

### PSX Doom BSP Front-Child Optimisation (`rmain.c`)

**Backported from:** PSX Doom source

Before recursing into the BSP tree to render a node's children, the renderer now
checks whether the *front child's bounding box* is even visible before
descending. If the front subtree is entirely behind the player or outside the
view frustum, the recursion is skipped entirely. This prunes large subtrees in
scenes with many back-facing BSP nodes.

---

### `CalcLine` Lookup Table (`rmain.c` / wall setup)

**Replaces:** Per-wall `FixedDiv` calls computing column scale from angle

A precomputed lookup table maps screen-x column to the reciprocal-of-cosine
value needed for the column scale calculation. Eliminates a `FixedDiv` (software
division — expensive on ARM with no hardware divide) per wall column during BSP
add-line processing.

---

### Global View Variable Caching Across BSP (`rmain.c`)

**Replaces:** Repeated `viewx`, `viewy`, `viewangle`, `viewcos`, `viewsin`
global reads inside tight BSP loops

View parameters do not change during a single frame's BSP traversal. Caching
them as `const` locals at the top of the traversal function allows `armcc -O1`
to keep them in registers for the duration of the traversal, eliminating dozens
of redundant global loads per frame.

---

### Decoration Sprite Distance Cull

**New; not present in original or OptidoomV3**

Non-interactive decoration sprites (lamps, corpses, etc.) are culled when
further than 1024 map units from the player. These objects contribute no
gameplay information at distance and are often not distinguishable from the
background at the 3DO's resolution. Culling them reduces the sprite sort and
silhouette-clip lists, improving both BSP and segloop performance.

---

### `ScaleFromGlobalAngle` Inlining

**Replaces:** Function call to `ScaleFromGlobalAngle` per wall segment

`ScaleFromGlobalAngle` computes the reciprocal-depth scale for a wall column
from the global view angle and the wall's normal angle. It was inlined at the
`AddLine` call site so the compiler can keep intermediate values in registers
across the wall processing sequence rather than round-tripping through the
function call ABI.

---

### Sound Resource Pinning

**New; not in original**

Sound effect lumps are pinned in DRAM after first load rather than being paged
out and reloaded from disc. The 3DO's Opera disc drive is slow; re-reading a
sound lump mid-combat causes a visible stutter. Pinning keeps all commonly-used
SFX resident at the cost of a fixed DRAM allocation.

---

## Profiling Infrastructure

### Real-Time Per-Subsystem Profiler (`bench.c`, `bench.h`)

**New; not present in original or OptidoomV3**

An always-available profiling overlay accessible from the mod options menu:

- `startProfiling(seconds)` begins a timed accumulation window
- `startBenchPeriod(idx, name)` / `endBenchPeriod(idx)` bracket any code path
- `updateBench()` draws the results on-screen each frame as labelled bars and
  millisecond timings
- Automatically starts on game launch (10-second window) for immediate feedback
  without menu navigation

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

---

## Build Notes

- Compiler: Norcroft ARM C v4.91 (`armcc`) with `-O1 -bigend -arch 3 -apcs 3/32/nofp`
- All assembly uses `armasm` with matching flags; no Thumb, no FPU, no ARMv4+
  instructions
- `DEBUG_SKIP_MENU` bypasses the mod options screen and starts directly at E1M1
  (build script default for development)
- Base ISO: `optidoom_working_backup.iso` patched with v24.225 OS from a
  hello-world donor disc (v20 developer OS silently fails to launch the binary)
