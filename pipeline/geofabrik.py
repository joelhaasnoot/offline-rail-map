#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
"""Look up a Geofabrik region: prints `<pbf-url>\t<name>\t<parent>` for the given region id."""
import json
import os
import sys
import time
import urllib.request

INDEX_URL = "https://download.geofabrik.de/index-v1-nogeom.json"


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: geofabrik.py <cache-dir> <region-id>")
    cache_dir, region = sys.argv[1], sys.argv[2]
    path = os.path.join(cache_dir, "geofabrik-index.json")
    if not os.path.isfile(path) or time.time() - os.path.getmtime(path) > 7 * 86400:
        urllib.request.urlretrieve(INDEX_URL, path)
    index = json.load(open(path))
    for feature in index["features"]:
        p = feature["properties"]
        if p["id"] == region:
            print("\t".join([p["urls"]["pbf"], p["name"], p.get("parent", "")]))
            return
    sys.exit(f"unknown Geofabrik region '{region}'")


if __name__ == "__main__":
    main()
