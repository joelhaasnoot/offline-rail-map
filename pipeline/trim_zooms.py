#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
"""Narrow the zoom range of each Martin function source to the zooms the app's style draws it at.

Upstream serves some layers one zoom beyond where the style shows them (the `*_low` lines stop at
style maxzoom 7, which is exclusive, but Martin still puts them in zoom 7 tiles). On the phone that
data is read, decompressed and kept in memory for nothing, and the zoom 7 tiles are the heaviest of
all. Functions the style does not use keep their range.

Usage:
  trim_zooms.py <martin configuration.yml> <orm-style.json> --maxzoom 16 > martin-bake.yml
"""
import argparse
import json
import math
import re
import sys
from collections import defaultdict


def drawn_ranges(style, maxzoom):
    """Tile zooms each source layer is drawn from: [floor(minzoom), ceil(maxzoom) - 1], where zooms
    beyond the baked maximum are drawn from the deepest tiles (overzoom)."""
    ranges = defaultdict(lambda: [math.inf, -math.inf])
    for layer in style["layers"]:
        name = layer.get("source-layer")
        if not name:
            continue
        lo = min(math.floor(layer.get("minzoom", 0)), maxzoom)
        hi = min(math.ceil(layer.get("maxzoom", 24)) - 1, maxzoom)
        r = ranges[name]
        r[0] = min(r[0], lo)
        r[1] = max(r[1], hi)
    return ranges


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config")
    ap.add_argument("style")
    ap.add_argument("--maxzoom", type=int, required=True, help="deepest zoom that is baked")
    args = ap.parse_args()

    ranges = drawn_ranges(json.load(open(args.style, encoding="utf-8")), args.maxzoom)
    lines = open(args.config, encoding="utf-8").read().splitlines()

    # Split the functions section into one block of lines per function source.
    out, block, name, in_functions = [], [], None, False

    def flush():
        if name is None:
            out.extend(block)
            return
        zooms = {}
        for line in block:
            m = re.match(r"^      (minzoom|maxzoom):\s*(\d+)\s*$", line)
            if m:
                zooms[m.group(1)] = int(m.group(2))
        if name not in ranges:
            out.extend(block)
            return
        lo, hi = ranges[name]
        new_min = max(zooms.get("minzoom", 0), lo)
        new_max = min(zooms.get("maxzoom", args.maxzoom), hi)
        if (new_min, new_max) != (zooms.get("minzoom", 0), zooms.get("maxzoom", args.maxzoom)):
            print(f"{name}: z{zooms.get('minzoom', 0)}-{zooms.get('maxzoom', args.maxzoom)} -> z{new_min}-{new_max}", file=sys.stderr)
        for line in block:
            if re.match(r"^      (minzoom|maxzoom):", line):
                continue
            out.append(line)
            if re.match(r"^      function:", line):
                out.append(f"      minzoom: {new_min}")
                out.append(f"      maxzoom: {new_max}")

    for line in lines:
        if re.match(r"^\s*functions:\s*$", line):
            flush()
            block, name, in_functions = [line], None, True
            continue
        m = re.match(r"^    ([A-Za-z0-9_]+):\s*$", line) if in_functions else None
        if m or (in_functions and re.match(r"^\S", line)):
            flush()
            block, name = [], None
            if m:
                name = m.group(1)
            else:
                in_functions = False
        block.append(line)
    flush()
    print("\n".join(out))


if __name__ == "__main__":
    main()
