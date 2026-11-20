#!/usr/bin/env python3
"""Generate the PNG icon set the Control4 driver and the Android app need.

Control4 Navigator wants the device/branding icons at 20..150, 300, 400, 512 and
1024 px, and tab icons at 20..140 px. Android TV wants a 320x180 banner and a
launcher icon. Everything is drawn with Pillow so the repo stays free of binary
design-tool assets; re-run this script to regenerate.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRIVER_ICONS = os.path.join(ROOT, "shield_bridge", "icons")
APP_RES = os.path.join(os.path.dirname(ROOT), "shield-bridge", "app", "src", "main", "res")

BG = (18, 24, 38, 255)        # dark navy tile
ACCENT = (118, 185, 0, 255)   # green, nods to the Shield without using its logo
WHITE = (245, 245, 245, 255)

MSP_SIZES = [20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 300, 400]
DISPLAY_SIZES = [70, 90, 300, 512, 1024]
TAB_SIZES = [20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140]


def tile(size, radius_frac=0.22, bg=BG):
    """Rounded square background rendered at 4x and downsampled for smooth edges."""
    s = size * 4
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=int(s * radius_frac), fill=bg)
    return img, d, s


def finish(img, size):
    return img.resize((size, size), Image.LANCZOS)


def draw_play(d, s, cx, cy, r, fill):
    pts = [(cx - r * 0.75, cy - r), (cx - r * 0.75, cy + r), (cx + r * 0.95, cy)]
    d.polygon(pts, fill=fill)


def device_icon(size):
    """Device icon: play triangle inside a ring, on a dark tile."""
    img, d, s = tile(size)
    cx = cy = s / 2
    ring = s * 0.33
    d.ellipse([cx - ring, cy - ring, cx + ring, cy + ring], outline=ACCENT, width=max(2, int(s * 0.055)))
    draw_play(d, s, cx + s * 0.02, cy, s * 0.17, WHITE)
    return finish(img, size)


def branding_icon(size):
    """Branding icon: same tile with a 'continue' arc to the left of the play mark."""
    img, d, s = tile(size)
    cx = cy = s / 2
    r = s * 0.33
    w = max(2, int(s * 0.07))
    d.arc([cx - r, cy - r, cx + r, cy + r], start=120, end=400, fill=ACCENT, width=w)
    # arrow head on the end of the arc (clockwise continuation)
    ax, ay = cx + r * 0.63, cy - r * 0.77
    d.polygon([(ax - s * 0.05, ay - s * 0.11), (ax + s * 0.09, ay), (ax - s * 0.05, ay + s * 0.11)], fill=ACCENT)
    draw_play(d, s, cx + s * 0.02, cy, s * 0.15, WHITE)
    return finish(img, size)


def tab_continue(size):
    """Tab icon: clock face with a play mark, transparent background (tabs are tinted by UI)."""
    s = size * 4
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx = cy = s / 2
    r = s * 0.42
    w = max(2, int(s * 0.08))
    d.arc([cx - r, cy - r, cx + r, cy + r], start=300, end=240, fill=WHITE, width=w)
    draw_play(d, s, cx + s * 0.03, cy, s * 0.2, WHITE)
    return finish(img, size)


def tab_apps(size):
    """Tab icon: 2x2 grid of rounded squares."""
    s = size * 4
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = s * 0.1
    gap = s * 0.08
    cell = (s - 2 * pad - gap) / 2
    for i in range(2):
        for j in range(2):
            x = pad + i * (cell + gap)
            y = pad + j * (cell + gap)
            d.rounded_rectangle([x, y, x + cell, y + cell], radius=int(cell * 0.2), fill=WHITE)
    return finish(img, size)


def nav_glyph(size, kind):
    """White control glyph on a transparent background, tinted by the UI."""
    s = size * 4
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx = cy = s / 2
    r = s * 0.3
    if kind in ("up", "down", "left", "right"):
        if kind == "up":
            pts = [(cx, cy - r), (cx - r, cy + r * 0.7), (cx + r, cy + r * 0.7)]
        elif kind == "down":
            pts = [(cx, cy + r), (cx - r, cy - r * 0.7), (cx + r, cy - r * 0.7)]
        elif kind == "left":
            pts = [(cx - r, cy), (cx + r * 0.7, cy - r), (cx + r * 0.7, cy + r)]
        else:
            pts = [(cx + r, cy), (cx - r * 0.7, cy - r), (cx - r * 0.7, cy + r)]
        d.polygon(pts, fill=WHITE)
    elif kind == "ok":
        w = max(2, int(s * 0.08))
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHITE, width=w)
        d.ellipse([cx - r * 0.42, cy - r * 0.42, cx + r * 0.42, cy + r * 0.42], fill=WHITE)
    elif kind == "back":
        w = max(2, int(s * 0.1))
        # curved arrow pointing left
        d.arc([cx - r, cy - r, cx + r, cy + r], start=80, end=330, fill=WHITE, width=w)
        hx, hy = cx - r * 0.1, cy - r * 0.95
        d.polygon([(hx - s * 0.08, hy), (hx + s * 0.06, hy - s * 0.1), (hx + s * 0.06, hy + s * 0.1)], fill=WHITE)
    elif kind == "home":
        # simple house
        d.polygon([(cx, cy - r), (cx - r, cy), (cx + r, cy)], fill=WHITE)
        d.rectangle([cx - r * 0.65, cy - r * 0.1, cx + r * 0.65, cy + r * 0.75], fill=WHITE)
    elif kind == "search":
        w = max(2, int(s * 0.1))
        rr = r * 0.62
        ccx, ccy = cx - r * 0.18, cy - r * 0.18
        d.ellipse([ccx - rr, ccy - rr, ccx + rr, ccy + rr], outline=WHITE, width=w)
        # handle
        import math
        hx0 = ccx + rr * math.cos(math.radians(45))
        hy0 = ccy + rr * math.sin(math.radians(45))
        d.line([hx0, hy0, cx + r * 0.75, cy + r * 0.75], fill=WHITE, width=int(w * 1.4))
    elif kind == "play":
        d.polygon([(cx - r * 0.7, cy - r), (cx - r * 0.7, cy + r), (cx + r, cy)], fill=WHITE)
    elif kind == "pause":
        bw = r * 0.55
        d.rectangle([cx - r * 0.8, cy - r, cx - r * 0.8 + bw, cy + r], fill=WHITE)
        d.rectangle([cx + r * 0.25, cy - r, cx + r * 0.25 + bw, cy + r], fill=WHITE)
    elif kind in ("rew", "ff"):
        sign = 1 if kind == "ff" else -1
        for off in (-0.55, 0.45):
            bx = cx + sign * off * r
            d.polygon([(bx - sign * r * 0.55, cy - r * 0.8), (bx - sign * r * 0.55, cy + r * 0.8), (bx + sign * r * 0.55, cy)], fill=WHITE)
    elif kind == "menu":
        bh = max(2, int(r * 0.22))
        for dy in (-0.6, 0.0, 0.6):
            y = cy + dy * r
            d.rounded_rectangle([cx - r, y - bh / 2, cx + r, y + bh / 2], radius=int(bh / 2), fill=WHITE)
    elif kind == "dpad":
        a = r * 0.3
        for dx, dy in ((0, -1), (1, 0), (0, 1), (-1, 0)):
            px, py = cx + dx * r * 0.82, cy + dy * r * 0.82
            if dx == 0:
                d.polygon([(px, py + dy * a), (px - a, py - dy * a * 0.7), (px + a, py - dy * a * 0.7)], fill=WHITE)
            else:
                d.polygon([(px + dx * a, py), (px - dx * a * 0.7, py - a), (px - dx * a * 0.7, py + a)], fill=WHITE)
        c = r * 0.2
        d.ellipse([cx - c, cy - c, cx + c, cy + c], fill=WHITE)
    elif kind == "playpause":
        # play triangle + pause bars, side by side
        d.polygon([(cx - r, cy - r * 0.7), (cx - r, cy + r * 0.7), (cx - r * 0.1, cy)], fill=WHITE)
        bw = r * 0.22
        d.rectangle([cx + r * 0.25, cy - r * 0.7, cx + r * 0.25 + bw, cy + r * 0.7], fill=WHITE)
        d.rectangle([cx + r * 0.6, cy - r * 0.7, cx + r * 0.6 + bw, cy + r * 0.7], fill=WHITE)
    return finish(img, size)



# --- Shield Bridge emblem ---------------------------------------------------
# A shield with a lime-to-emerald rim, a dark interior and a white play mark,
# glowing on a dark tile. The remote variant swaps the play mark for a D-pad.
# Drawn once at 2048 px and scaled down, so small sizes stay crisp.

EMBLEM_A = (176, 234, 52, 255)    # lime, top-left of the rim
EMBLEM_B = (18, 176, 122, 255)    # emerald, bottom-right of the rim
INNER_A = (16, 40, 28, 255)
INNER_B = (4, 12, 9, 255)
TILE_A = (20, 30, 48, 255)
TILE_B = (6, 10, 18, 255)


def _quad(p0, p1, p2, n=48):
    out = []
    for i in range(n + 1):
        t = i / n
        a, b, c = (1 - t) ** 2, 2 * (1 - t) * t, t ** 2
        out.append((a * p0[0] + b * p1[0] + c * p2[0], a * p0[1] + b * p1[1] + c * p2[1]))
    return out


def shield_points(cx, top, w, h):
    left, right = cx - w / 2, cx + w / 2
    shoulder = top + 0.40 * h
    pts = _quad((left, top), (cx, top + 0.12 * h), (right, top))
    pts.append((right, shoulder))
    pts += _quad((right, shoulder), (right, top + 0.82 * h), (cx, top + h))[1:]
    pts += _quad((cx, top + h), (left, top + 0.82 * h), (left, shoulder))[1:]
    return pts


def _gradient(size, c1, c2, diagonal=False):
    v = Image.linear_gradient("L").resize(size)
    mask = Image.blend(Image.linear_gradient("L").rotate(90).resize(size), v, 0.5) if diagonal else v
    return Image.composite(Image.new("RGBA", size, c2), Image.new("RGBA", size, c1), mask)


def _mask(size, pts):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m


def _paint(base, layer_rgba, mask):
    base.alpha_composite(Image.composite(layer_rgba, Image.new("RGBA", base.size, (0, 0, 0, 0)), mask))


def render_emblem(S=2048, symbol="play", tile_bg=True):
    size = (S, S)
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    if tile_bg:
        tmask = Image.new("L", size, 0)
        ImageDraw.Draw(tmask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.22), fill=255)
        _paint(img, _gradient(size, TILE_A, TILE_B), tmask)
        w, h, top = 0.56 * S, 0.66 * S, 0.15 * S
    else:
        w, h, top = 0.74 * S, 0.88 * S, 0.05 * S
    cx = S / 2
    outer = shield_points(cx, top, w, h)
    omask = _mask(size, outer)

    # soft green glow behind the shield
    glow = omask.filter(ImageFilter.GaussianBlur(S * 0.05)).point(lambda v: int(v * 0.55))
    _paint(img, Image.new("RGBA", size, (90, 210, 90, 255)), glow)
    if tile_bg:
        # grounded shadow
        sh = Image.new("L", size, 0)
        sh.paste(omask, (0, int(S * 0.025)))
        sh = sh.filter(ImageFilter.GaussianBlur(S * 0.02)).point(lambda v: int(v * 0.6))
        _paint(img, Image.new("RGBA", size, (0, 0, 0, 255)), sh)

    # rim, then dark interior
    _paint(img, _gradient(size, EMBLEM_A, EMBLEM_B, diagonal=True), omask)
    t = w * 0.075
    inner = shield_points(cx, top + t, w - 2 * t, h - 2.5 * t)
    imask = _mask(size, inner)
    _paint(img, _gradient(size, INNER_A, INNER_B), imask)

    # gloss on the upper-left of the interior
    gl = Image.new("L", size, 0)
    ImageDraw.Draw(gl).ellipse([cx - w * 0.9, top - h * 0.55, cx + w * 0.25, top + h * 0.38], fill=38)
    gl = Image.composite(gl, Image.new("L", size, 0), imask)
    _paint(img, Image.new("RGBA", size, (255, 255, 255, 255)), gl)


    # centre symbol with its own glow
    sym = Image.new("L", size, 0)
    sd = ImageDraw.Draw(sym)
    scy = top + 0.44 * h
    if symbol == "play":
        r = S * 0.13
        sd.polygon([(cx - r * 0.62, scy - r), (cx - r * 0.62, scy + r), (cx + r * 0.95, scy)], fill=255)
    else:  # D-pad
        R = S * 0.14
        ring = max(2, int(S * 0.022))
        sd.ellipse([cx - R, scy - R, cx + R, scy + R], outline=255, width=ring)
        a = S * 0.042
        for dx, dy in ((0, -1), (1, 0), (0, 1), (-1, 0)):
            px, py = cx + dx * R * 0.58, scy + dy * R * 0.58
            if dx == 0:
                sd.polygon([(px, py + dy * a), (px - a, py - dy * a * 0.6), (px + a, py - dy * a * 0.6)], fill=255)
            else:
                sd.polygon([(px + dx * a, py), (px - dx * a * 0.6, py - a), (px - dx * a * 0.6, py + a)], fill=255)
        c = S * 0.03
        sd.ellipse([cx - c, scy - c, cx + c, scy + c], fill=255)
    sglow = sym.filter(ImageFilter.GaussianBlur(S * 0.025)).point(lambda v: int(v * 0.7))
    _paint(img, Image.new("RGBA", size, (140, 255, 120, 255)), sglow)
    _paint(img, Image.new("RGBA", size, (250, 252, 248, 255)), sym)
    return img


_EMBLEM_CACHE = {}


def emblem(size, symbol="play", tile_bg=True):
    key = (symbol, tile_bg)
    if key not in _EMBLEM_CACHE:
        _EMBLEM_CACHE[key] = render_emblem(2048, symbol, tile_bg)
    return _EMBLEM_CACHE[key].resize((size, size), Image.LANCZOS)


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, "PNG", optimize=True)


DRIVERS = {
    "shield_bridge": (118, 185, 0, 255),   # green
    "roku_bridge": (125, 60, 190, 255),    # purple
}


def driver_icons(name, accent):
    global ACCENT
    ACCENT = accent
    icons = os.path.join(ROOT, name, "icons")
    if name == "shield_bridge":
        dev = lambda z: emblem(z, "play", True)
        brand = lambda z: emblem(z, "play", False)
    else:
        dev, brand = device_icon, branding_icon
    for sz in sorted(set(MSP_SIZES + DISPLAY_SIZES)):
        save(dev(sz), os.path.join(icons, "device", f"device_{sz}.png"))
        save(brand(sz), os.path.join(icons, "branding", f"branding_{sz}.png"))
    for sz in DISPLAY_SIZES:
        save(dev(sz), os.path.join(icons, "device", f"experience_{sz}.png"))
    for sz in TAB_SIZES:
        save(tab_continue(sz), os.path.join(icons, "tab_continue", f"tab_continue_{sz}.png"))
        save(tab_apps(sz), os.path.join(icons, "tab_apps", f"tab_apps_{sz}.png"))
    save(dev(32), os.path.join(icons, "device_sm.png"))
    save(dev(64), os.path.join(icons, "device_lg.png"))
    if name == "shield_bridge":
        # Shield Bridge Remote: same emblem with a D-pad
        for sz in sorted(set(MSP_SIZES + DISPLAY_SIZES)):
            save(emblem(sz, "dpad", True), os.path.join(icons, "remote", f"experience_{sz}.png"))
        save(emblem(32, "dpad", True), os.path.join(icons, "remote_sm.png"))
        save(emblem(64, "dpad", True), os.path.join(icons, "remote_lg.png"))
    # On-screen control glyphs
    kinds = ["up", "down", "left", "right", "ok", "back", "home", "playpause", "search", "play", "pause", "rew", "ff", "menu"]
    if name == "shield_bridge":
        kinds.append("dpad")   # transport-bar toggle into D-pad mode
    for kind in kinds:
        nm = "nav_" + kind
        for sz in TAB_SIZES:
            save(nav_glyph(sz, kind), os.path.join(icons, nm, f"{nm}_{sz}.png"))


def main():
    # Control4 driver icons (Shield last, so ACCENT is green for the app assets)
    for name in ("roku_bridge", "shield_bridge"):
        driver_icons(name, DRIVERS[name])

    # Android app resources
    save(emblem(192, "play", True), os.path.join(APP_RES, "mipmap", "ic_launcher.png"))
    banner = Image.new("RGBA", (320, 180), BG)
    icon = emblem(130, "play", False)
    banner.paste(icon, (22, 25), icon)
    d = ImageDraw.Draw(banner)
    # simple wordmark made of bars so we don't depend on fonts being installed
    d.rounded_rectangle([170, 60, 290, 78], radius=8, fill=WHITE)
    d.rounded_rectangle([170, 92, 250, 110], radius=8, fill=ACCENT)
    save(banner, os.path.join(APP_RES, "drawable", "banner.png"))
    print("icons written")


if __name__ == "__main__":
    sys.exit(main())
