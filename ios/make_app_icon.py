#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Draws the iOS app icon from the same design as the Android launcher icon
(android/app/src/main/res/drawable/ic_launcher_*.xml): two orange rails with dark sleepers."""
import os

from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4  # draw large, then downsample for smooth edges
VIEWPORT = 108

px = SIZE * SCALE / VIEWPORT
img = Image.new("RGB", (SIZE * SCALE, SIZE * SCALE), "#F3EFE9")
draw = ImageDraw.Draw(img)


def line(x1, y1, x2, y2, color, width):
    w = width * px
    draw.line([(x1 * px, y1 * px), (x2 * px, y2 * px)], fill=color, width=round(w))
    for x, y in ((x1, y1), (x2, y2)):  # round caps
        draw.ellipse([x * px - w / 2, y * px - w / 2, x * px + w / 2, y * px + w / 2], fill=color)


for y, x1, x2 in ((80, 27, 81), (68, 31, 77), (56, 35, 73), (44, 39, 69), (32, 43, 65)):
    line(x1, y, x2, y, "#333333", 4)
line(30, 86, 52, 22, "#FF8100", 5)
line(78, 86, 56, 22, "#FF8100", 5)

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "OfflineRailwayMap/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
os.makedirs(os.path.dirname(out), exist_ok=True)
img.resize((SIZE, SIZE), Image.LANCZOS).save(out)
print(out)
