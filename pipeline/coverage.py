#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
"""Print the coverage polygon(s) of a Geofabrik region as JSON: a list of rings of [lon, lat].

Only outer rings are kept and coordinates are rounded to 3 decimals (~100 m), which is plenty
for "is this point inside the pack" checks in the app.
"""
import json
import os
import sys
import time
import urllib.request

INDEX_URL = "https://download.geofabrik.de/index-v1.json"


def rings_for(cache_dir, region):
    path = os.path.join(cache_dir, "geofabrik-index-geom.json")
    if not os.path.isfile(path) or time.time() - os.path.getmtime(path) > 7 * 86400:
        urllib.request.urlretrieve(INDEX_URL, path)
    index = json.load(open(path))
    for feature in index["features"]:
        if feature["properties"]["id"] != region:
            continue
        geom = feature["geometry"]
        polygons = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
        rings = []
        for polygon in polygons:
            outer = polygon[0]
            rings.append([[round(x, 3), round(y, 3)] for x, y in outer])
        return rings
    sys.exit(f"unknown Geofabrik region '{region}'")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: coverage.py <cache-dir> <region-id>")
    print(json.dumps(rings_for(sys.argv[1], sys.argv[2]), separators=(",", ":")))
