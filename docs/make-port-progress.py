#!/usr/bin/env python3
"""Generate docs/port-progress.svg — where the port's work is.

A treemap: each rectangle's AREA is proportional to the work still remaining on
that item, so the picture is honest about what is big. Finished work is drawn
faded and takes no area.

Regenerate with:

    python3 docs/make-port-progress.py

Keep the numbers current when a milestone lands — that is the whole point of
having this as a script rather than a hand-written SVG (the previous one still
said "World entry - never run" long after it ran).

SIZE is a judgement of REMAINING effort on a 0-10 scale, not a byte count.
Status is one of: done, partial, open.
"""

import html
import os

W, H = 1000, 664
PAD = 20

INK = "#0b0f16"
TITLE = "#f4f7fc"
LABEL = "#e9edf5"
SUB = "#c8d0e0"
SUB_DIM = "#93a0b8"

STYLE = {
    "partial": {"fill": "#5a3410", "stroke": "#e0a13c", "sub": "#f0d3a6"},
    "open": {"fill": "#5c1616", "stroke": "#e0605a", "sub": "#f2c3c0"},
}

# --- the work -----------------------------------------------------------------
# (title, status, remaining size, [subtitle lines])
ITEMS = [
    ("Offline content coverage", "partial", 10, [
        "9,464 source quests -> 950 adapted, 0 verified",
        "classes, pets, professions, world scripts bounded",
        "dungeons, guilds, PvP absent; 861/944 objects placed",
    ]),
    ("Console memory ceiling", "open", 9, [
        "driver refuses allocations the heap can serve",
        "512x256 image fails at ~96 MiB live; 256x128 serves",
        "VMA ladder 32/16/8/4 MiB; 8 MiB broke M2 transfers",
    ]),
    ("Long-session stability", "open", 8, [
        "the largest remaining unknown: memory over hours",
        "no sustained crash-free session yet",
    ]),
    ("Connected-realm performance", "partial", 8, [
        "GPU fill-bound; ~8-11 fps in world at 480-640p",
        "updateMeanMs 71-90 -> ~10 (transport, not traffic)",
        "the render wall itself remains",
    ]),
    ("Secure / restricted execution", "partial", 7, [
        "scripted Click() runs insecure only",
        "secure show/hide, clicks, drag-drop inert",
    ]),
    ("Class & combat completion", "partial", 7, [
        "pets, stances/forms, procs, full talents",
        "DK / Paladin / Shaman, channels open",
    ]),
    ("Instances, dungeons, raids", "open", 6, [
        "no boss scripts or encounter state",
        "entering an instance gives no mechanics",
    ]),
    ("Suspend, resume, dock", "open", 5, [
        "no appletHook; sleep/Home/dock unhandled",
        "a failed present is permanent; Close is ignored",
    ]),
    ("Perf audit levers", "partial", 5, [
        "~14 of 25 levers remain",
        "texture-cache LRU, BC textures, skin LOD, present",
    ]),
    ("Guilds / PvP / battlegrounds", "open", 5, [
        "no local guild authority or storage",
        "no PvP, battleground or arena ruleset",
    ]),
    ("Pre-login settings path", "open", 4, [
        "getConfigRoot() -> $HOME/.wowps, never created",
        "settings before first login are silently lost",
    ]),
    ("Heap request 1280 MiB", "open", 4, [
        "was 1536 MiB; still far above the",
        "256-320 MiB usual homebrew range",
    ]),
    ("Lua-heap OOM crash", "open", 4, [
        "mid-session, no clean signature match",
        "GCSTEP added; lua_kb breadcrumb in place",
    ]),
    ("Vehicles & escorts", "partial", 4, [
        "authored kits exist; retail physics open",
        "escorts: no navmesh, ambush or NPC spells",
    ]),
    ("Thread stacks / miniaudio", "open", 3, [
        "128 KiB default; job thread size unset",
        "the PS4 port overflowed on this thread",
    ]),
    ("Diagnostics & net gaps", "open", 2, [
        "crash reporter is a no-op",
        "loader hangs silently; no net status check",
    ]),
    ("On-screen fatal dialog", "partial", 2, [
        "reason lands in boot.log now;",
        "the dialog is still a bare code",
    ]),
    ("Single Joy-Con", "open", 2, [
        "NpadFullCtrl excludes",
        "JoyLeft/JoyRight",
    ]),
    ("Touchscreen cannot click", "open", 2, [
        "touch moves the cursor,",
        "never emits a click",
    ]),
    ("On-screen keyboard wedges", "open", 2, [
        "left open, controller input",
        "stops until the title restarts",
    ]),
    ("Stale PS4 paths in strings", "open", 1, [
        "error text still says",
        "/data/wow_ps/Data",
    ]),
]

# Finished work: drawn faded, no area. (title, [subtitle lines])
DONE = [
    ("Toolchain + NRO build", ["devkitA64, libnx, Mesa NVK, romfs", "727/728 targets"]),
    ("MPQ + asset loading", ["18 archives incl. 2.9 GB common.MPQ", "FrameXML, 4 min -> 1 s"]),
    ("TLS miscompile", ["423 sites were ldr w0,[x0,x0]", "-ftls-model=local-exec, guarded"]),
    ("Audio + teardown", ["audout double-wait removed", "_Exit avoids the FILE list"]),
    ("Login, character, world", ["boot path live; world entry runs", "terrain, M2/WMO, NPCs, HUD"]),
    ("Controller UI + crosshair", ["ConsolePort bar, Minus=map, hub", "crosshair drives the world's clicks"]),
    ("Connected realm", ["connects, logs in, enters world", "against a private server"]),
    ("Sockets + local-realm saves", ["sin_len set; saves via writableRoot()", ""]),
]


def squarify(values, x, y, w, h):
    """Squarified treemap: return a rect per value, laid out largest-first."""
    rects = []
    vals = list(values)
    total = float(sum(vals))
    if total <= 0:
        return rects

    def worst(row, length, scale):
        s = sum(row) * scale
        if s <= 0 or length <= 0:
            return float("inf")
        side = s / length
        return max(max(r * scale / side, side / (r * scale)) for r in row)

    def layout_row(row, x, y, w, h, scale, horizontal):
        s = sum(row) * scale
        out = []
        if horizontal:
            rh = s / w if w else 0
            cx = x
            for r in row:
                rw = (r * scale) / rh if rh else 0
                out.append((cx, y, rw, rh))
                cx += rw
            return out, (x, y + rh, w, h - rh)
        rw = s / h if h else 0
        cy = y
        for r in row:
            rh = (r * scale) / rw if rw else 0
            out.append((x, cy, rw, rh))
            cy += rh
        return out, (x + rw, y, w - rw, h)

    idx = 0
    row = []
    while idx < len(vals):
        v = vals[idx]
        area = w * h
        scale = area / total
        horizontal = w >= h
        length = w if horizontal else h
        if not row or worst(row + [v], length, scale) <= worst(row, length, scale):
            row.append(v)
            idx += 1
        else:
            placed, (x, y, w, h) = layout_row(row, x, y, w, h, scale, horizontal)
            rects.extend(placed)
            row = []
        if not row and idx >= len(vals):
            break
    if row:
        scale = (w * h) / total if w * h else 0
        placed, _ = layout_row(row, x, y, w, h, scale, w >= h)
        rects.extend(placed)
    return rects


def esc(s):
    return html.escape(s, quote=True)


def main():
    out = []
    a = out.append

    open_items = [(t, s, n, lines) for (t, s, n, lines) in ITEMS if s != "done" and n > 0]
    open_items.sort(key=lambda i: -i[2])

    a(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
      f'role="img" aria-label="WoWee Switch porting progress, treemap by remaining work">')
    a("  <title>WoWee Switch - porting progress</title>")
    a("  <defs><style>")
    a("    .h{font:700 19px ui-sans-serif,system-ui,sans-serif;fill:%s}" % TITLE)
    a("    .sub{font:400 11.5px ui-sans-serif,system-ui,sans-serif;fill:%s}" % SUB_DIM)
    a("    .t{font:600 12.5px ui-sans-serif,system-ui,sans-serif;fill:%s}" % LABEL)
    a("    .s{font:400 10.5px ui-sans-serif,system-ui,sans-serif}")
    a("    .k{font:700 11px ui-sans-serif,system-ui,sans-serif;fill:%s}" % TITLE)
    a("    .d{font:600 11px ui-sans-serif,system-ui,sans-serif;fill:#9fe3bf}")
    a("    .ds{font:400 10px ui-sans-serif,system-ui,sans-serif;fill:#7fae94}")
    a("  </style></defs>")
    a(f'  <rect width="{W}" height="{H}" fill="{INK}"/>')

    a(f'  <text x="{PAD}" y="34" class="h">WoWee Switch - where the work is</text>')
    a(f'  <text x="{PAD}" y="54" class="sub">'
      'Rectangle area is the work still REMAINING on that item, not what is built. '
      'Faded green = done.</text>')
    a(f'  <text x="{PAD}" y="70" class="sub">'
      '<tspan fill="#e0a13c">amber</tspan> = partly there &#183; '
      '<tspan fill="#e0605a">red</tspan> = not started &#183; '
      'the biggest blocks are what to do next.</text>')

    # --- treemap of remaining work ---
    tx, ty, tw, th = PAD, 82, W - 2 * PAD, 366
    a(f'  <rect x="{tx}" y="{ty}" width="{tw}" height="{th}" fill="#101722" stroke="#1d2733"/>')

    sizes = [n for (_, _, n, _) in open_items]
    rects = squarify(sizes, tx, ty, tw, th)

    for (title, status, _n, lines), (x, y, w, h) in zip(open_items, rects):
        st = STYLE[status]
        a(f'  <rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" '
          f'fill="{st["fill"]}" stroke="{st["stroke"]}" stroke-width="1.2"/>')
        pad = 7
        if w < 54 or h < 22:
            continue
        # title, wrapped if the box is narrow
        tx0 = x + pad
        ty0 = y + pad + 9
        words = title.split()
        tlines, cur = [], ""
        for wd in words:
            probe = (cur + " " + wd).strip()
            if len(probe) * 6.3 > w - 2 * pad and cur:
                tlines.append(cur)
                cur = wd
            else:
                cur = probe
        tlines.append(cur)
        for i, tl in enumerate(tlines):
            if ty0 + i * 14 > y + h - 4:
                break
            a(f'  <text x="{tx0:.1f}" y="{ty0 + i * 14:.1f}" class="t">{esc(tl)}</text>')
        # subtitles, only what fits
        sy = ty0 + len(tlines) * 14 + 3
        maxchars = max(4, int((w - 2 * pad) / 5.4))
        for ln in lines:
            if sy > y + h - 5:
                break
            text = ln if len(ln) <= maxchars else ln[: maxchars - 1].rstrip() + "\u2026"
            a(f'  <text x="{tx0:.1f}" y="{sy:.1f}" class="s" fill="{st["sub"]}">{esc(text)}</text>')
            sy += 13

    # --- done strip ---
    dy = 464
    a(f'  <text x="{PAD}" y="{dy}" class="k">DONE</text>')
    a(f'  <text x="{PAD + 46}" y="{dy}" class="sub" '
      'style="font-size:10.5px">shipped and on hardware - no area, because none of the work is left</text>')
    cols, gap = 4, 12
    cw = (W - 2 * PAD - gap * (cols - 1)) / cols
    ch = 44
    for i, (title, lines) in enumerate(DONE):
        r, c = divmod(i, cols)
        x = PAD + c * (cw + gap)
        y = dy + 12 + r * (ch + 8)
        a(f'  <rect x="{x:.1f}" y="{y:.1f}" width="{cw:.1f}" height="{ch}" rx="4" '
          'fill="#12301f" stroke="#2d9a68" opacity="0.85"/>')
        a(f'  <text x="{x + 9:.1f}" y="{y + 17:.1f}" class="d">{esc(title)}</text>')
        sy = y + 30
        for ln in lines:
            if not ln or sy > y + ch - 3:
                continue
            a(f'  <text x="{x + 9:.1f}" y="{sy:.1f}" class="ds">{esc(ln)}</text>')
            sy += 12

    a(f'  <text x="{PAD}" y="{H - 12}" class="sub" '
      'style="font-size:10.5px">'
      'Sizes are a judgement of remaining work, not byte counts. '
      'Measured on hardware, 2026-10-13. '
      'Generated by docs/make-port-progress.py - rerun it when a milestone lands.</text>')
    a("</svg>")

    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "port-progress.svg")
    with open(path, "w") as fh:
        fh.write("\n".join(out) + "\n")
    print(f"wrote {path} ({os.path.getsize(path)} bytes, {len(open_items)} open + {len(DONE)} done)")


if __name__ == "__main__":
    main()
