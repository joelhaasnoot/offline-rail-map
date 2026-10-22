#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
"""Look up a Geofabrik region: prints `<pbf-url>\t<name>\t<parent>\t<id>` for the given region id.

Accepts the plain index id (`belgium`, `us/california`) or `<parent>/<id>` (`europe/belgium`); the
last field is the id as it appears in the index.
"""
import json
import os
import sys
import time
import urllib.request

INDEX_URL = "https://download.geofabrik.de/index-v1-nogeom.json"


def load_index(cache_dir):
    """Return {region id: properties} from the Geofabrik index, cached for a week in cache_dir."""
    path = os.path.join(cache_dir, "geofabrik-index.json")
    if not os.path.isfile(path) or time.time() - os.path.getmtime(path) > 7 * 86400:
        os.makedirs(cache_dir, exist_ok=True)
        urllib.request.urlretrieve(INDEX_URL, path)
    index = json.load(open(path))
    return {f["properties"]["id"]: f["properties"] for f in index["features"]}


def resolve(index, region):
    """Return the index id for region, or None. `<parent>/<id>` matches an id whose parent is <parent>."""
    if region in index:
        return region
    parent, _, child = region.rpartition("/")
    if parent and index.get(child, {}).get("parent") == parent:
        return child
    return None


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: geofabrik.py <cache-dir> <region-id>")
    cache_dir, region = sys.argv[1], sys.argv[2]
    index = load_index(cache_dir)
    region_id = resolve(index, region)
    if region_id is None:
        sys.exit(f"unknown Geofabrik region '{region}'")
    p = index[region_id]
    print("\t".join([p["urls"]["pbf"], p["name"], p.get("parent", ""), region_id]))


if __name__ == "__main__":
    main()
