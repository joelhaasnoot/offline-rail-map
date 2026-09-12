#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
"""Bake OpenRailwayMap vector tiles from a running Martin server into an MBTiles file.

Walks the tile pyramid inside a bounding box. From `--prune-zoom` upwards, subtrees
below an empty tile are skipped (railway features are always present in the
`railway_line_high` layer from zoom 12, so an empty z>=12 tile has empty children).

Usage:
  bake_tiles.py --martin http://127.0.0.1:3000 --config martin.yml \
      --bbox 3.3,50.7,7.3,53.6 --maxzoom 16 --output railway.mbtiles
"""
import argparse
import gzip
import json
import math
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor


def lonlat_to_tile(lon, lat, z):
    n = 2 ** z
    lat = max(min(lat, 85.0511), -85.0511)
    x = int((lon + 180.0) / 360.0 * n)
    y = int((1.0 - math.log(math.tan(math.radians(lat)) + 1.0 / math.cos(math.radians(lat))) / math.pi) / 2.0 * n)
    return min(max(x, 0), n - 1), min(max(y, 0), n - 1)


def functions_from_config(path):
    """Return Martin function source names, in config order (no yaml dependency needed)."""
    names = []
    in_functions = False
    for line in open(path, encoding="utf-8"):
        if re.match(r"^\s*functions:\s*$", line):
            in_functions = True
            continue
        if in_functions:
            m = re.match(r"^    ([A-Za-z0-9_]+):\s*$", line)
            if m:
                names.append(m.group(1))
            elif re.match(r"^\S", line):
                in_functions = False
    return names


def fetch(url, retries=5):
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"Accept-Encoding": "identity"})
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read()
                if r.status == 204 or not data:
                    return None
                return data
        except urllib.error.HTTPError as e:
            if e.code == 204 or e.code == 404:
                return None
            if attempt == retries - 1:
                raise
            time.sleep(1 + attempt)
        except Exception:
            if attempt == retries - 1:
                raise
            time.sleep(1 + attempt)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--martin", default="http://127.0.0.1:3000")
    ap.add_argument("--config", required=True, help="Martin configuration.yml (function sources)")
    ap.add_argument("--bbox", required=True, help="min_lon,min_lat,max_lon,max_lat")
    ap.add_argument("--minzoom", type=int, default=0)
    ap.add_argument("--maxzoom", type=int, default=16)
    ap.add_argument("--prune-zoom", type=int, default=12)
    ap.add_argument("--concurrency", type=int, default=16)
    ap.add_argument("--output", required=True)
    ap.add_argument("--name", default="OpenRailwayMap")
    ap.add_argument("--attribution", default="© OpenStreetMap contributors, OpenRailwayMap")
    ap.add_argument("--lang", default="", help="value of the `lang` query parameter for localized station names")
    args = ap.parse_args()

    functions = functions_from_config(args.config)
    if not functions:
        sys.exit("no function sources found in config")
    composite = ",".join(functions)
    query = f"?lang={args.lang}" if args.lang else ""
    print(f"{len(functions)} function sources -> composite tile source", flush=True)

    min_lon, min_lat, max_lon, max_lat = (float(v) for v in args.bbox.split(","))

    db = sqlite3.connect(args.output)
    db.executescript(
        """
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        DROP TABLE IF EXISTS tiles;
        DROP TABLE IF EXISTS metadata;
        CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
        CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);
        CREATE TABLE metadata (name TEXT, value TEXT);
        """
    )

    total_tiles = 0
    total_bytes = 0
    start = time.time()
    kept = None  # tiles with data at previous zoom (used for pruning)

    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        for z in range(args.minzoom, args.maxzoom + 1):
            x0, y0 = lonlat_to_tile(min_lon, max_lat, z)
            x1, y1 = lonlat_to_tile(max_lon, min_lat, z)
            if z > args.prune_zoom and kept is not None:
                frontier = [(2 * x + dx, 2 * y + dy) for (x, y) in kept for dx in (0, 1) for dy in (0, 1)]
            else:
                frontier = [(x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]

            def job(xy):
                x, y = xy
                return x, y, fetch(f"{args.martin}/{composite}/{z}/{x}/{y}{query}")

            new_kept = []
            rows = []
            n_data = 0
            for x, y, data in pool.map(job, frontier, chunksize=8):
                if data is None:
                    continue
                n_data += 1
                new_kept.append((x, y))
                blob = gzip.compress(data, compresslevel=6)
                total_bytes += len(blob)
                rows.append((z, x, (2 ** z - 1) - y, sqlite3.Binary(blob)))
                if len(rows) >= 2000:
                    db.executemany("INSERT INTO tiles VALUES (?,?,?,?)", rows)
                    rows = []
            if rows:
                db.executemany("INSERT INTO tiles VALUES (?,?,?,?)", rows)
            db.commit()
            total_tiles += n_data
            kept = new_kept
            print(
                f"z{z:2d}: requested {len(frontier):7d}, with data {n_data:7d}, "
                f"total {total_tiles} tiles / {total_bytes / 1e6:.1f} MB, {time.time() - start:.0f}s",
                flush=True,
            )

    center_lon = (min_lon + max_lon) / 2
    center_lat = (min_lat + max_lat) / 2
    metadata = {
        "name": args.name,
        "format": "pbf",
        "type": "overlay",
        "version": "1",
        "description": "OpenRailwayMap vector tiles (railway infrastructure) for offline use",
        "attribution": args.attribution,
        "minzoom": str(args.minzoom),
        "maxzoom": str(args.maxzoom),
        "bounds": f"{min_lon},{min_lat},{max_lon},{max_lat}",
        "center": f"{center_lon},{center_lat},{min(args.maxzoom, 8)}",
        "json": json.dumps({"vector_layers": [{"id": f, "fields": {}} for f in functions]}),
    }
    db.executemany("INSERT INTO metadata VALUES (?,?)", list(metadata.items()))
    db.commit()
    db.execute("VACUUM")
    db.close()
    print(f"done: {total_tiles} tiles, {total_bytes / 1e6:.1f} MB compressed, {time.time() - start:.0f}s")


if __name__ == "__main__":
    main()
