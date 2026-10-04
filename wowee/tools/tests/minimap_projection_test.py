#!/usr/bin/env python3
"""The minimap's world-to-pixel projection, worked out from the shipped sources.

Three things have to agree for the minimap to show the right piece of the world
at the right size: which world axis the composite texture's u and v carry
(assets/shaders/minimap_tile.vert.glsl plus the 3x3 grid Minimap::compositePass
records), where the player sits inside it (Minimap::render's playerUV), and how
much of it the display quad samples (assets/shaders/minimap_display.frag.glsl).

Nothing asserts that they agree, and reading the shader alone does not settle
it - the composite's axes are set by a loop nesting in C++ and consumed by a
swizzle in GLSL, so the two have to be traced together. This does that
numerically: it reads the two shaders and the two C++ sites rather than
re-implementing them, so it fails when any of them changes.

Run: python wowee/tools/tests/minimap_projection_test.py
"""
from __future__ import annotations

import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHADERS = ROOT / "assets/shaders"
MINIMAP_CPP = ROOT / "src/rendering/minimap.cpp"
COORDINATES = ROOT / "include/core/coordinates.hpp"

TILE_SIZE = 533.33333
# The composite is three tiles across in each direction (COMPOSITE_PX = TILE_PX*3,
# and minimap_tile.vert divides the grid offset by three).
COMPOSITE_SPAN_YARDS = 3.0 * TILE_SIZE


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def tile_shader_scale() -> float:
    """The constant minimap_tile.vert divides the 3x3 grid offset by."""
    text = read(SHADERS / "minimap_tile.vert.glsl")
    match = re.search(r"push\.gridOffset\)\s*/\s*([0-9.]+)", text)
    if not match:
        raise AssertionError("minimap_tile.vert.glsl no longer divides by a literal")
    return float(match.group(1))


def display_zoom_gain() -> float:
    """Whatever minimap_display.frag multiplies zoomRadius by when sampling."""
    text = read(SHADERS / "minimap_display.frag.glsl")
    match = re.search(r"mapUV\s*=\s*[^;]*?zoomRadius\s*\*\s*([0-9.]+)", text)
    if not match:
        raise AssertionError("minimap_display.frag.glsl no longer scales zoomRadius by a literal")
    return float(match.group(1))


def display_uv_swizzle() -> tuple[str, str]:
    """Which post-rotation component feeds composite u, and which feeds v.

    The shader builds the offset as vec2(A, B) from the rotated screen offset,
    so A drives u and B drives v. Reading the names out keeps the test honest if
    the expression is rewritten.
    """
    text = read(SHADERS / "minimap_display.frag.glsl")
    match = re.search(r"mapUV\s*=\s*[^;]*?vec2\(\s*([A-Za-z0-9_.]+)\s*,\s*(-?[A-Za-z0-9_.]+)\s*\)", text)
    if not match:
        raise AssertionError("minimap_display.frag.glsl no longer builds mapUV as vec2(a, b)")
    return match.group(1), match.group(2)


def composite_axes() -> dict[str, str]:
    """Which tile axis the composite's u and v carry.

    Minimap::compositePass walks dr (outer) and dc (inner) over the 3x3 grid and
    pushes gridOffset = (dc + 1, dr + 1); minimap_tile.vert puts gridOffset.x on
    the quad's x, i.e. on composite u, and gridOffset.y on composite v. Inside
    both loops dr steps tileX and dc steps tileY, and coordinates.hpp says tileX
    is the renderY (north-south) tile and tileY the renderX (east-west) tile.
    """
    text = read(MINIMAP_CPP)
    draw_loop = re.search(
        r"for \(int dr = -1;.*?for \(int dc = -1;.*?int tx = (\w+) \+ dr;.*?int ty = (\w+) \+ dc;",
        text, re.S)
    if not draw_loop:
        raise AssertionError("compositePass no longer walks dr/dc over tileX/tileY the same way")
    dr_tile, dc_tile = draw_loop.group(1), draw_loop.group(2)

    push = re.search(r"push\.gridOffset\s*=\s*glm::vec2\(([^,]+),\s*([^)]+)\)", text)
    if not push:
        raise AssertionError("compositePass no longer sets gridOffset from the loop counters")

    coords = read(COORDINATES)
    tile_x_is_render_y = bool(re.search(r"int tileX\s*=\s*static_cast<int>\(std::floor\(32\.0f - renderY", coords))
    tile_y_is_render_x = bool(re.search(r"int tileY\s*=\s*static_cast<int>\(std::floor\(32\.0f - renderX", coords))
    if not (tile_x_is_render_y and tile_y_is_render_x):
        raise AssertionError("worldToTile no longer maps tileX to renderY and tileY to renderX")

    # gridOffset.x <-> dc <-> ty <-> renderX;  gridOffset.y <-> dr <-> tx <-> renderY.
    dr_field, dc_field = dr_tile, dc_tile
    assert dr_field == "centerTileX" and dc_field == "centerTileY", (dr_field, dc_field)
    assert "dc" in push.group(1), push.group(1)
    assert "dr" in push.group(2), push.group(2)
    return {"u": "renderX", "v": "renderY"}


def player_uv_axes() -> dict[str, str]:
    """Which world axis playerU and playerV follow, from Minimap::render."""
    text = read(MINIMAP_CPP)
    ew = re.search(r"float fracEW\s*=\s*([^;]+);", text)
    ns = re.search(r"float fracNS\s*=\s*([^;]+);", text)
    pu = re.search(r"playerU\s*=\s*([^;]+);", text)
    pv = re.search(r"playerV\s*=\s*([^;]+);", text)
    if not all((ew, ns, pu, pv)):
        raise AssertionError("Minimap::render no longer builds fracEW/fracNS/playerU/playerV")
    # fracEW is built from tileY (the renderX tile) and centerWorldPos.x, fracNS
    # from tileX (the renderY tile) and centerWorldPos.y.
    assert "tileY" in ew.group(1) and ".x" in ew.group(1), ew.group(1)
    assert "tileX" in ns.group(1) and ".y" in ns.group(1), ns.group(1)
    assert "fracEW" in pu.group(1), pu.group(1)
    assert "fracNS" in pv.group(1), pv.group(1)
    return {"u": "renderX", "v": "renderY"}


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    failures: list[str] = []
    note = lambda ok, message: None if ok else failures.append(message)  # noqa: E731

    # --- 1. Scale: how many yards does the minimap actually show? ---
    divisor = tile_shader_scale()
    check(divisor == 3.0, f"composite grid divisor is {divisor}, expected 3 tiles")
    # Minimap::render: zoomRadius = viewRadius / (TILE_SIZE * 3).
    text = read(MINIMAP_CPP)
    radius = re.search(r"zoomRadius\s*=\s*viewRadius\s*/\s*\(\s*TILE_SIZE\s*\*\s*([0-9.]+)f?\s*\)", text)
    check(radius is not None, "Minimap::render no longer divides viewRadius by TILE_SIZE * n")
    check(float(radius.group(1)) == 3.0, f"zoomRadius divides by 3 tiles' worth: {radius.group(1)}")

    gain = display_zoom_gain()
    view_radius = 400.0  # Minimap::viewRadius default
    # Half the minimap's width in composite UV is gain * viewRadius / (TILE*3);
    # one UV unit is TILE*3 yards, so the half-width in yards is gain*viewRadius.
    half_width_yards = gain * view_radius
    print(f"  composite: 1 UV = {COMPOSITE_SPAN_YARDS:.0f} yards "
          f"(3 tiles), zoomRadius({view_radius:.0f}) = "
          f"{view_radius / COMPOSITE_SPAN_YARDS:.4f} UV")
    print(f"  display shader scales that by {gain:g}, so the minimap covers "
          f"{2 * half_width_yards:.0f} yards across for an authored "
          f"viewRadius of {view_radius:.0f}")
    note(
        gain == 1.0,
        f"minimap_display.frag multiplies zoomRadius by {gain:g}. zoomRadius is "
        f"already in composite UV (viewRadius / 3 tiles), so this factor scales "
        f"the map by {gain:g}x: every feature on the minimap is {gain:g}x its "
        f"authored size relative to the player marker, which is what 'the "
        f"minimap terrain looks doubled' looks like. It should be 1.0.",
    )

    # --- 2. Axes: does the composite's u reach the screen's x? ---
    axes = composite_axes()
    player = player_uv_axes()
    check(axes == player, f"playerUV axis mapping {player} disagrees with the "
                          f"composite grid {axes}")
    u_expr, v_expr = display_uv_swizzle()
    print(f"  composite u carries {axes['u']}, v carries {axes['v']}; "
          f"playerUV agrees")
    print(f"  display offset into u comes from '{u_expr}', into v from '{v_expr}'")

    # With rotation == 0 (north-up, the mode that is actually used - see
    # Minimap::render, where the saved setting is read and dropped), the shader's
    # own expressions reduce to a fixed pair, so they can be evaluated here
    # rather than reasoned about.
    if u_expr == "rotated.y" and v_expr == "-rotated.x":
        # mapCenter = vec2(-center.x, center.y); rotation 0 -> rotated == mapCenter.
        # So u <- +center.y (screen down) and v <- +center.x (screen right).
        u_driven_by, v_driven_by = "screenY", "screenX"
        note(False,
             "minimap_display.frag feeds composite u from the screen's vertical "
             "axis and composite v from its horizontal axis, while the composite "
             "grid puts u on renderX (east-west) and v on renderY (north-south). "
             "The display transposes them, so the map is rotated 90 degrees: "
             "what should be to the east is drawn to the north. For a north-up "
             "minimap the offset should be vec2(-rotated.x, -rotated.y): screen "
             "right is +renderX, which is -u, and screen up is -renderY, which "
             "is +v.")
    else:
        u_driven_by = v_driven_by = "?"
        note(False, f"minimap_display.frag's mapUV offset changed shape "
                    f"(vec2({u_expr}, {v_expr})); this test only reasons about "
                    f"the north-up form")
    print(f"  at rotation 0 the sampled offset is driven by u<-{u_driven_by}, "
          f"v<-{v_driven_by}")

    if failures:
        for index, message in enumerate(failures, 1):
            print(f"FAIL minimap projection ({index}/{len(failures)}): {message}",
                  file=sys.stderr)
        return 1
    print("PASS minimap projection: composite axes, player UV and display sample agree")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except AssertionError as error:
        print(f"FAIL minimap projection: {error}", file=sys.stderr)
        sys.exit(1)