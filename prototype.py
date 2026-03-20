import struct
import math
import random
import pygame
from collections import defaultdict

# ---------------------------------------------------------------------------
# WAD parsing
# ---------------------------------------------------------------------------

def load_wad_lump(wad_path, lump_name):
    with open(wad_path, "rb") as f:
        f.seek(4)
        num_lumps = struct.unpack("<I", f.read(4))[0]
        dir_ptr  = struct.unpack("<I", f.read(4))[0]
        f.seek(dir_ptr)
        for _ in range(num_lumps):
            lump_pos  = struct.unpack("<I", f.read(4))[0]
            lump_size = struct.unpack("<I", f.read(4))[0]
            name = f.read(8).decode("ascii", errors="ignore").rstrip("\x00").upper()
            if name == lump_name.upper():
                f.seek(lump_pos)
                return f.read(lump_size)
    return None


def get_doom_palette(wad_path):
    data = load_wad_lump(wad_path, "PLAYPAL")
    if data is None:
        return None
    return [(data[i*3], data[i*3+1], data[i*3+2]) for i in range(256)]


def get_doom_flat(wad_path, flat_name):
    target = flat_name.upper()
    with open(wad_path, "rb") as f:
        f.seek(4)
        num_lumps = struct.unpack("<I", f.read(4))[0]
        dir_ptr  = struct.unpack("<I", f.read(4))[0]
        f.seek(dir_ptr)
        in_flats = False
        for _ in range(num_lumps):
            lump_pos  = struct.unpack("<I", f.read(4))[0]
            lump_size = struct.unpack("<I", f.read(4))[0]
            name = f.read(8).decode("ascii", errors="ignore").rstrip("\x00").upper()
            if name in ("F_START", "FF_START", "F1_START", "F2_START"):
                in_flats = True;  continue
            if name in ("F_END",   "FF_END",   "F1_END",   "F2_END"):
                in_flats = False; continue
            if in_flats and name == target and lump_size == 4096:
                f.seek(lump_pos)
                return list(f.read(4096))
    return None


# ---------------------------------------------------------------------------
# Oval-ish boundary — distance-based interpolation, no Bezier
# ---------------------------------------------------------------------------

def generate_boundary(cx, cy, num_points, min_r, max_r, seed=42):
    rng = random.Random(seed)
    angles = sorted(rng.uniform(0, 2 * math.pi) for _ in range(num_points))
    radii  = [rng.randint(min_r, max_r) for _ in range(num_points)]

    outline = []
    n = len(angles)
    for i in range(n):
        a0, r0 = angles[i], radii[i]
        a1, r1 = angles[(i+1) % n], radii[(i+1) % n]
        if a1 <= a0:
            a1 += 2 * math.pi
        steps = max(int((a1 - a0) * ((r0 + r1) >> 1)), 2)
        for s in range(steps):
            t_fp = (s * 65536) // steps
            a = a0 + (a1 - a0) * s / steps
            r = (r0 * (65536 - t_fp) + r1 * t_fp) >> 16
            outline.append((cx + int(r * math.cos(a)),
                            cy + int(r * math.sin(a))))
    return outline


# ---------------------------------------------------------------------------
# Scanline span table — even-odd fill, multiple spans per row
#
# Returns: dict[y] -> list of (x_min, x_max) sorted left to right.
# Crossings are rounded INWARD (ceiling for left edge, floor for right edge)
# so no filled pixel ever lies outside the polygon boundary.
# ---------------------------------------------------------------------------

def build_span_table(outline, screen_w, screen_h):
    crossings = defaultdict(list)   # y -> [floor_x, ...]  (one per edge crossing)

    n = len(outline)
    for i in range(n):
        x0, y0 = outline[i]
        x1, y1 = outline[(i + 1) % n]

        if y0 == y1:
            continue                # skip horizontal edges

        if y0 > y1:                 # orient top-to-bottom
            x0, y0, x1, y1 = x1, y1, x0, y0

        dx = x1 - x0
        dy = y1 - y0               # always > 0

        # top-inclusive / bottom-exclusive avoids double-counting at vertices
        for y in range(max(y0, 0), min(y1, screen_h)):
            num      = dx * (y - y0)
            floor_ix = x0 + num // dy
            rem      = num - (num // dy) * dy   # always in [0, dy)
            # Store both values so we can round inward later
            crossings[y].append((floor_ix, floor_ix + (1 if rem else 0)))

    spans = {}
    for y, xs in crossings.items():
        xs.sort()                   # sort by floor value (left to right)

        # Even-odd pairing: pair 0, pair 1, …  each pair is a filled interval.
        # Left  edge of pair: use ceiling (round right = inward)
        # Right edge of pair: use floor   (round left  = inward)
        row_spans = []
        i = 0
        while i + 1 < len(xs):
            x_min = xs[i][1]        # ceil
            x_max = xs[i+1][0]     # floor
            if x_min < 0:
                x_min = 0
            if x_max >= screen_w:
                x_max = screen_w - 1
            if x_min <= x_max:
                row_spans.append((x_min, x_max))
            i += 2

        if row_spans:
            spans[y] = row_spans

    return spans


# ---------------------------------------------------------------------------
# Render one span segment into pix_array (integer math only)
# ---------------------------------------------------------------------------

def render_span(pix_array, flat, pal_rgb, y, x_min, x_max,
                flat_size, flat_mask, cell,
                tint_r, tint_g, tint_b):
    """Partition [x_min..x_max] on scanline y into HW cells + SW slivers."""

    # First 16-px-grid-aligned X at or after x_min
    cell_start = ((x_min + cell - 1) // cell) * cell
    # Exclusive right boundary of the last full aligned cell
    cell_end   = ((x_max + 1) // cell) * cell

    v = y & flat_mask

    # Left sliver
    for x in range(x_min, min(cell_start, x_max + 1)):
        idx = flat[v * flat_size + (x & flat_mask)]
        r, g, b = pal_rgb[idx]
        pix_array[x, y, 0] = r
        pix_array[x, y, 1] = g
        pix_array[x, y, 2] = b

    # Hardware cell stamps
    bx = cell_start
    while bx + cell <= cell_end and bx + cell - 1 <= x_max:
        for x in range(bx, bx + cell):
            idx = flat[v * flat_size + (x & flat_mask)]
            r, g, b = pal_rgb[idx]
            r = r + tint_r; r = r if r < 256 else 255
            g = g + tint_g; g = g if g < 256 else 255
            b = b + tint_b; b = b if b < 256 else 255
            pix_array[x, y, 0] = r
            pix_array[x, y, 1] = g
            pix_array[x, y, 2] = b
        bx += cell

    # Right sliver
    rs = max(cell_end, cell_start)
    for x in range(rs, x_max + 1):
        idx = flat[v * flat_size + (x & flat_mask)]
        r, g, b = pal_rgb[idx]
        pix_array[x, y, 0] = r
        pix_array[x, y, 1] = g
        pix_array[x, y, 2] = b


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

SCREEN_W = 800
SCREEN_H = 600
CELL     = 16
FLAT_SZ  = 64
FLAT_MSK = 63

TINT_R = 18
TINT_G = 0
TINT_B = 0


def main():
    wad_file = "DOOM.WAD"
    palette  = get_doom_palette(wad_file)

    flat = flat_name = None
    for c in ("FLOOR4_8", "FLOOR4_6", "FLOOR4_5", "FLOOR4_1"):
        flat = get_doom_flat(wad_file, c)
        if flat:
            flat_name = c
            break

    if palette is None or flat is None:
        print("Failed to load WAD data.")
        return
    print("Loaded flat:", flat_name)

    cx = SCREEN_W // 2
    cy = SCREEN_H // 2
    outline = generate_boundary(cx, cy, num_points=12, min_r=120, max_r=260, seed=7)
    spans   = build_span_table(outline, SCREEN_W, SCREEN_H)

    pygame.init()
    screen     = pygame.display.set_mode((SCREEN_W, SCREEN_H))
    pygame.display.set_caption("OptiDoom Hybrid 3DO / Software Floor Prototype")
    clock      = pygame.time.Clock()
    frame_surf = pygame.Surface((SCREEN_W, SCREEN_H))
    frame_surf.fill((32, 32, 32))

    # -----------------------------------------------------------------------
    # Render all spans
    # -----------------------------------------------------------------------
    pix = pygame.surfarray.pixels3d(frame_surf)

    for y in range(SCREEN_H):
        if y not in spans:
            continue
        for x_min, x_max in spans[y]:
            render_span(pix, flat, palette, y, x_min, x_max,
                        FLAT_SZ, FLAT_MSK, CELL, TINT_R, TINT_G, TINT_B)

    del pix

    # -----------------------------------------------------------------------
    # Green boundary — left/right edge pixels of each span segment.
    # Derived from the span table so it is pixel-identical to the fill edge.
    # Horizontal caps are drawn only on scanlines with no span above/below.
    # -----------------------------------------------------------------------
    for y in range(SCREEN_H):
        if y not in spans:
            continue
        for x_min, x_max in spans[y]:
            if 0 <= x_min < SCREEN_W:
                frame_surf.set_at((x_min, y), (0, 255, 0))
            if 0 <= x_max < SCREEN_W:
                frame_surf.set_at((x_max, y), (0, 255, 0))
        # Horizontal cap only when the whole row above/below is empty
        if (y - 1) not in spans:
            for x_min, x_max in spans[y]:
                for x in range(max(x_min, 0), min(x_max + 1, SCREEN_W)):
                    frame_surf.set_at((x, y), (0, 255, 0))
        if (y + 1) not in spans:
            for x_min, x_max in spans[y]:
                for x in range(max(x_min, 0), min(x_max + 1, SCREEN_W)):
                    frame_surf.set_at((x, y), (0, 255, 0))

    # -----------------------------------------------------------------------
    # 16-px grid lines (cyan blend) inside the boundary
    # -----------------------------------------------------------------------
    for gx in range(0, SCREEN_W, CELL):
        for y in range(SCREEN_H):
            if y not in spans:
                continue
            for x_min, x_max in spans[y]:
                if x_min <= gx <= x_max:
                    c = frame_surf.get_at((gx, y))
                    frame_surf.set_at((gx, y), (
                        (c[0] * 3) >> 2,
                        (c[1] * 3 + 80) >> 2,
                        (c[2] * 3 + 80) >> 2,
                    ))

    # -----------------------------------------------------------------------
    # Stats overlay
    # -----------------------------------------------------------------------
    total_cells = total_sliver = 0
    for y in range(SCREEN_H):
        if y not in spans:
            continue
        for x_min, x_max in spans[y]:
            if x_min < 0: x_min = 0
            if x_max >= SCREEN_W: x_max = SCREEN_W - 1
            cs = ((x_min + CELL - 1) // CELL) * CELL
            ce = ((x_max + 1) // CELL) * CELL
            nc = max(0, (min(ce, x_max + 1) - cs)) // CELL
            total_cells  += nc
            total_sliver += (x_max - x_min + 1) - nc * CELL

    font = pygame.font.SysFont("monospace", 14)
    for i, line in enumerate([
        "OptiDoom Hybrid Floor Renderer Prototype",
        "Flat: %s  |  Cell: 16x16  |  Grid: global" % flat_name,
        "HW cells: %d  |  SW sliver px: %d" % (total_cells, total_sliver),
        "Red tint = HW cell  |  No tint = SW sliver",
        "Green outline = sector boundary",
        "Cyan grid = 16px alignment grid",
    ]):
        frame_surf.blit(font.render(line, True, (255, 255, 255)), (8, 4 + i * 16))

    # -----------------------------------------------------------------------
    # Event loop
    # -----------------------------------------------------------------------
    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
                running = False
        screen.blit(frame_surf, (0, 0))
        pygame.display.flip()
        clock.tick(30)

    pygame.quit()


if __name__ == "__main__":
    main()
