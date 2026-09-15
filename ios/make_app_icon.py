#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
"""Draws the iOS app icon from the same design as the Android launcher icon
(pipeline/make_app_icon.py): a two-lamp signal head showing green on the app's orange."""
import os

from PIL import Image, ImageDraw

SIZE = 1024
SUPERSAMPLE = 4  # draw large, then downsample for smooth edges

ORANGE = (0xE8, 0x64, 0x0A, 255)
HEAD = (0x26, 0x26, 0x26, 255)
UNLIT = (0x5A, 0x5A, 0x5A, 255)
GREEN = (0x2E, 0xE0, 0x6F, 255)
GLOW = (0x2E, 0xE0, 0x6F, 0x66)

# Geometry of the signal head in its 18 x 17.12 drawing units, as in pipeline/make_app_icon.py.
HEAD_BOX = (5, 0.55, 13, 16.55)
TOP_LAMP = (9, 4.6, 2.25)
BOTTOM_LAMP = (9, 12.5, 2.25)
GLOW_RADIUS = 3.05
CENTER = (9.0, 8.55)
# Signal height as a share of the icon; Android shows it at about this size inside its launcher mask.
HEIGHT_SHARE = 0.66

canvas = SIZE * SUPERSAMPLE
unit = canvas * HEIGHT_SHARE / (HEAD_BOX[3] - HEAD_BOX[1])


def to_px(x, y):
    return canvas / 2 + (x - CENTER[0]) * unit, canvas / 2 + (y - CENTER[1]) * unit


def disc(layer, cx, cy, r, colour):
    x, y = to_px(cx, cy)
    ImageDraw.Draw(layer).ellipse([x - r * unit, y - r * unit, x + r * unit, y + r * unit], fill=colour)


img = Image.new("RGBA", (canvas, canvas), ORANGE)
x0, y0 = to_px(HEAD_BOX[0], HEAD_BOX[1])
x1, y1 = to_px(HEAD_BOX[2], HEAD_BOX[3])
ImageDraw.Draw(img).rounded_rectangle([x0, y0, x1, y1], radius=(x1 - x0) / 2, fill=HEAD)
disc(img, *TOP_LAMP, UNLIT)
glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
disc(glow, BOTTOM_LAMP[0], BOTTOM_LAMP[1], GLOW_RADIUS, GLOW)
img = Image.alpha_composite(img, glow)
disc(img, *BOTTOM_LAMP, GREEN)

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "OfflineRailwayMap/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
os.makedirs(os.path.dirname(out), exist_ok=True)
# App Store icons must not have transparency.
img.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB").save(out)
print(out)
