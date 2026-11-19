#!/usr/bin/env python3
"""Generate the PNG icon set the Control4 driver and the Android app need.

Control4 Navigator wants the device/branding icons at 20..150, 300, 400, 512 and
1024 px, and tab icons at 20..140 px. Android TV wants a 320x180 banner and a
launcher icon. Everything is drawn with Pillow so the repo stays free of binary
design-tool assets; re-run this script to regenerate.
"""
import os
import sys

from PIL import Image, ImageDraw

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
    elif kind == "playpause":
        # play triangle + pause bars, side by side
        d.polygon([(cx - r, cy - r * 0.7), (cx - r, cy + r * 0.7), (cx - r * 0.1, cy)], fill=WHITE)
        bw = r * 0.22
        d.rectangle([cx + r * 0.25, cy - r * 0.7, cx + r * 0.25 + bw, cy + r * 0.7], fill=WHITE)
        d.rectangle([cx + r * 0.6, cy - r * 0.7, cx + r * 0.6 + bw, cy + r * 0.7], fill=WHITE)
    return finish(img, size)


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
    for sz in sorted(set(MSP_SIZES + DISPLAY_SIZES)):
        save(device_icon(sz), os.path.join(icons, "device", f"device_{sz}.png"))
        save(branding_icon(sz), os.path.join(icons, "branding", f"branding_{sz}.png"))
    for sz in DISPLAY_SIZES:
        save(device_icon(sz), os.path.join(icons, "device", f"experience_{sz}.png"))
    for sz in TAB_SIZES:
        save(tab_continue(sz), os.path.join(icons, "tab_continue", f"tab_continue_{sz}.png"))
        save(tab_apps(sz), os.path.join(icons, "tab_apps", f"tab_apps_{sz}.png"))
    save(device_icon(32), os.path.join(icons, "device_sm.png"))
    save(device_icon(64), os.path.join(icons, "device_lg.png"))
    # On-screen control glyphs
    for kind in ("up", "down", "left", "right", "ok", "back", "home", "playpause", "search", "play", "pause", "rew", "ff"):
        nm = "nav_" + kind
        for sz in TAB_SIZES:
            save(nav_glyph(sz, kind), os.path.join(icons, nm, f"{nm}_{sz}.png"))


def main():
    # Control4 driver icons (Shield last, so ACCENT is green for the app assets)
    for name in ("roku_bridge", "shield_bridge"):
        driver_icons(name, DRIVERS[name])

    # Android app resources
    save(device_icon(192), os.path.join(APP_RES, "mipmap", "ic_launcher.png"))
    banner = Image.new("RGBA", (320, 180), BG)
    icon = device_icon(120)
    banner.paste(icon, (30, 30), icon)
    d = ImageDraw.Draw(banner)
    # simple wordmark made of bars so we don't depend on fonts being installed
    d.rounded_rectangle([170, 60, 290, 78], radius=8, fill=WHITE)
    d.rounded_rectangle([170, 92, 250, 110], radius=8, fill=ACCENT)
    save(banner, os.path.join(APP_RES, "drawable", "banner.png"))
    print("icons written")


if __name__ == "__main__":
    sys.exit(main())
