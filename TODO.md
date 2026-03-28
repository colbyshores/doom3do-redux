# optidoom-test — Optimization TODO

---

## 1. ASM inner loop for `DrawWallSegment` (wallloop.s)

**Status:** File exists (`optidoom3do/source/wallloop.s`), called from `phase6_2.c`.
**Known bug fixed:** `viscol_t` struct size was assumed to be 8 bytes; `Word = unsigned int = 32 bits`, so the actual size is 12 bytes (`scale` int@0, `column` Word@4, `light` Word@8). The struct stride and field loads in the ASM have been corrected.
**Current state:** ASM is wired in and builds clean. Has not been re-validated visually since the CCB-corruption regression was the main rendering issue obscuring the result.

### What to validate
- Boot in RetroArch with `WALL_QUALITY_HI` and verify walls render correctly.
- Compare visual output against the pre-ASM C baseline (`git show 2ecee33`).

### If still broken
The assembly loop (`DblLoop` / `Sgl1xLoop`) may still have a subtle issue. Fallback: restore the original two-function split (`DrawWallSegment` + `PrepWallSegmentTexCol`) from commit `2ecee33` and re-derive the ASM from that known-correct C.

---

## 2. Flat-color DISCARD wall fallback (anti-HOM feature)

**Status:** Implemented via Option A. Needs visual validation.

### What was done
- `computeTexAvgColor()` added to `phase6_2.c` — computes a weighted average RGB of all texels in a texture using its 4-bit PLUT. Result is cached in `tex->color`. This function is correct and stays in the codebase.
- Lazy computation of `tex->color` added in `DrawSegAny` before the flat/textured branch. Harmless — stays in the codebase.
- `DrawWalls()` in `phase6.c` was extended to call `DrawSegFlat` for `VW_DISCARD` walls instead of skipping them. **This was reverted.**

### Root cause of the revert
`DrawWallSegmentFlat` is designed around CCBs pre-initialized by `initCCBarrayWallFlat()` (used in `WALL_QUALITY_LO` mode), which sets `ccb_HDX`, `ccb_VDX`, `ccb_VDY`, `ccb_PRE0`, and `ccb_SourcePtr` for flat-texture rendering.

In `WALL_QUALITY_HI` mode, CCBs are initialized by `initCCBarrayWall()` with different values (`ccb_HDX=0`, `ccb_VDX=1<<16`, `ccb_VDY=0`). When `DrawWallSegmentFlat` was patched to write the flat-specific fields (`ccb_HDX=1<<20`, `ccb_VDX=0`) to those CCBs for DISCARD walls, those writes **persisted across frames** (the CCB array is not re-initialized each frame). On subsequent frames, any textured wall reusing those same CCB slots found corrupted `HDX`/`VDX`/`VDY` values, producing visual distortion of all textured walls.

### How to fix it properly
Two clean options:

**Option A — Write HDX/VDX/VDY in `DrawWallSegment`** (simplest):
In the textured wall inner loop, always explicitly write:
```c
CCBPtr->ccb_HDX = 0;
CCBPtr->ccb_VDX = 1 << 16;
CCBPtr->ccb_VDY = 0;
```
This restores the correct textured values every frame regardless of what a previous flat DISCARD render left behind. Cost: 3 extra stores per CCB (6 for the double-CCB path).

**Option B — Separate CCB array for DISCARD flat walls** (cleanest):
Allocate a small, dedicated CCB array (e.g., 8 CCBs) initialized by `initCCBarrayWallFlat()` for exclusive use by DISCARD flat rendering. No shared state, no cross-contamination.

Option A is simpler and should be tried first.

### What was done (Option A)
- In `wallloop.s` `DblLoop` and `Sgl1xLoop`: always write `CCB_HDX=0`, `CCB_VDX=1<<16`, `CCB_VDY=0` per column after PRE1, before SourcePtr. This restores textured CCB state every frame regardless of what a previous DISCARD flat draw left behind (7 instructions for double-CCB path, 5 for single).
- In `phase6.c` `DrawWalls()`: DISCARD walls now call `DrawSegFlat` instead of being skipped.

### Remaining
- Visual validation: boot in RetroArch, verify no HOM gaps on narrow walls and no distortion on textured walls.
- Poly renderer path (`RENDERER_DOOM != renderer`) still skips VW_DISCARD walls. Adding a fallback there requires tracking `columnStoreArrayIndex` in the poly loop — deferred.

---

## 3. Notes

- `tex->color == 0` is the sentinel for "uncomputed". `computeTexAvgColor` always returns ≥ 1 (bit 0 = opaque flag in 3DO RGB555). The `sDiscardFallbackColor = 0x3def` (medium grey) in `DrawSegAny` handles the rare case of unloaded texture data.
- The polygon renderer (`DrawSegPoly` / `phase6PL.c`) already uses `tex->color` for its own flat fallback path — the infrastructure is already there.
