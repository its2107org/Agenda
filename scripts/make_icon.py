#!/usr/bin/env python3
"""Draws Agenda's app icon (light, dark and tinted versions) at 1024 x 1024."""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = sys.argv[1] if len(sys.argv) > 1 else "App/Assets.xcassets/AppIcon.appiconset"


def gradient(top, bottom):
    img = Image.new("RGB", (S, S))
    d = ImageDraw.Draw(img)
    for y in range(S):
        t = y / (S - 1)
        d.line([(0, y), (S, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def artwork(ink, accent, faint, glow=False):
    """Three list rows; the first ticked off with a bold check."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    left, circle = 230, 120
    rows = [330, 512, 694]
    for i, y in enumerate(rows):
        box = [left, y - circle / 2, left + circle, y + circle / 2]
        if i == 0:
            d.ellipse(box, fill=accent + (255,))
            # Check mark.
            cx, cy = left + circle / 2, y
            d.line([(cx - 30, cy + 2), (cx - 8, cy + 26), (cx + 32, cy - 24)], fill=ink + (255,), width=20, joint="curve")
            for px, py in [(cx - 30, cy + 2), (cx + 32, cy - 24), (cx - 8, cy + 26)]:
                d.ellipse([px - 10, py - 10, px + 10, py + 10], fill=ink + (255,))
            bar_colour = faint + (255,)
        else:
            d.ellipse(box, outline=ink + (255,), width=18)
            bar_colour = ink + (255,)
        length = [330, 420, 300][i]
        bx = left + circle + 60
        d.rounded_rectangle([bx, y - 30, bx + length, y + 30], radius=30, fill=bar_colour)
    if glow:
        g = layer.filter(ImageFilter.GaussianBlur(36))
        out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        out.alpha_composite(g)
        out.alpha_composite(layer)
        return out
    return layer


def make(name, top, bottom, ink, accent, faint, glow=False):
    bg = gradient(top, bottom).convert("RGBA")
    bg.alpha_composite(artwork(ink, accent, faint, glow))
    bg.convert("RGB").save(f"{OUT}/{name}.png")


make("icon-light", (122, 112, 255), (72, 52, 212), (255, 255, 255), (255, 196, 70), (196, 186, 255))
make("icon-dark", (36, 34, 52), (12, 12, 18), (236, 234, 255), (255, 196, 70), (110, 104, 160), glow=True)
make("icon-tinted", (24, 24, 24), (0, 0, 0), (235, 235, 235), (170, 170, 170), (110, 110, 110))
print("Icons written to", OUT)
