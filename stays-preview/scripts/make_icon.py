#!/usr/bin/env python3
"""Draws Stays' app icon (light, dark and tinted versions) at 1024 x 1024: a hotel desk bell."""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = sys.argv[1] if len(sys.argv) > 1 else "App/Assets.xcassets/AppIcon.appiconset"
SS = 4  # draw big, then shrink, for smooth edges


def gradient(top, bottom):
    img = Image.new("RGB", (S, S))
    d = ImageDraw.Draw(img)
    for y in range(S):
        t = y / (S - 1)
        d.line([(0, y), (S, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def bell(ink, shine, glow=False):
    B = S * SS
    layer = Image.new("RGBA", (B, B), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    k = SS
    cx = B / 2
    # Dome
    r = 300 * k
    base_y = 650 * k
    d.pieslice([cx - r, base_y - r, cx + r, base_y + r], 180, 360, fill=ink + (255,))
    # Little highlight on the dome
    d.arc([cx - r + 70 * k, base_y - r + 70 * k, cx + r - 70 * k, base_y + r - 70 * k], 200, 245, fill=shine + (255,), width=34 * k)
    # Knob and stem
    d.rounded_rectangle([cx - 20 * k, base_y - r - 70 * k, cx + 20 * k, base_y - r + 10 * k], radius=12 * k, fill=ink + (255,))
    d.ellipse([cx - 52 * k, base_y - r - 118 * k, cx + 52 * k, base_y - r - 14 * k], fill=ink + (255,))
    # Base plate
    d.rounded_rectangle([cx - 380 * k, base_y + 26 * k, cx + 380 * k, base_y + 96 * k], radius=35 * k, fill=ink + (255,))
    layer = layer.resize((S, S), Image.LANCZOS)
    if glow:
        g = layer.filter(ImageFilter.GaussianBlur(40))
        out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        out.alpha_composite(g)
        out.alpha_composite(layer)
        return out
    return layer


def make(name, top, bottom, ink, shine, glow=False):
    bg = gradient(top, bottom).convert("RGBA")
    bg.alpha_composite(bell(ink, shine, glow))
    bg.convert("RGB").save(f"{OUT}/{name}.png")


make("icon-light", (236, 140, 98), (184, 82, 52), (255, 250, 244), (236, 160, 120))
make("icon-dark", (52, 36, 30), (18, 12, 10), (245, 170, 130), (255, 214, 190), glow=True)
make("icon-tinted", (24, 24, 24), (0, 0, 0), (235, 235, 235), (150, 150, 150))
print("Icons written to", OUT)
