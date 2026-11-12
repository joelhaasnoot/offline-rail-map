#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
"""Work out the rail corridor of the imported region: everything within N km of a railway.

Large, mostly empty countries (Canada, Australia) have basemaps of gigabytes, nearly all of it
far from any track. build-country.sh limits their basemap to this corridor.

  1. Lay a grid over the country with cells of N/20 (5 km for 100 km) and note every cell a
     railway line passes through. Every line in the database counts, in use or not: whatever
     the map draws gets a basemap. This leaves some thousands of cells instead of millions of
     track vertices.
  2. Grow each of those cells into a disc with a radius of N km, row by row: a disc covers a
     run of cells in each grid row it touches, and overlapping runs in a row are merged. The
     grid is in Web Mercator, which stretches distances by 1/cos(latitude), so the radius in
     cells grows by that factor towards the poles. One cell is added to make up for the grid.
  3. Merge the runs into polygons, which joins everything less than 2 N km apart, and fill
     the holes: land enclosed by railways on all sides stays in the pack instead of becoming
     an island of missing map.
  4. Smooth the staircase the grid leaves, cut the result to the Geofabrik region outline (so
     it does not reach into neighbouring countries the extract has no data for) and drop
     slivers under 25 km2.

Railways further than 2 N km from any other keep their own separate area (Tasmania, an isolated
mine railway), so no track is ever left without a basemap.

Buffering the tracks in PostGIS gives the same shape but takes minutes for a small country,
because every buffer overlaps hundreds of others; the grid takes seconds for a large one.

Writes the corridor as an Osmosis .poly file (for Planetiler's --polygon) and prints it in the
format of coverage.py: a JSON list of outer rings of [lon, lat].

Usage: corridor.py <cache-dir> <region-id> --db postgresql://... --km 100 --poly corridor.poly
"""
import argparse
import json
import math
import os
import subprocess
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from coverage import geometry_for  # noqa: E402

GRID_SHARE = 0.05  # cell size as a share of the distance
MIN_PART_KM2 = 25
EARTH_RADIUS_M = 6378137

CELLS_SQL = """
select distinct floor(ST_X(p) / {cell})::int, floor(ST_Y(p) / {cell})::int
from (select (ST_DumpPoints(ST_Segmentize(way, {cell}))).geom as p from railway_line) points;
"""

OUTLINE_SQL = """
with merged as (
  select (ST_Dump(ST_UnaryUnion(ST_GeomFromText('{strips}', 3857)))).geom as g
), filled as (
  select ST_Union(ST_MakePolygon(ST_ExteriorRing(g))) as g from merged
), region as (
  select ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON($geojson${region}$geojson$), 4326)) as g
), parts as (
  select (ST_Dump(ST_Intersection(ST_Transform(ST_SimplifyPreserveTopology(filled.g, {cell}), 4326), region.g))).geom as g
  from filled, region
), kept as (
  select ST_MakePolygon(ST_ExteriorRing(g)) as g from parts
  where GeometryType(g) = 'POLYGON' and ST_Area(g::geography) > {min_part} * 1e6
)
select json_build_object(
  'geometry', ST_AsGeoJSON(ST_Collect(g), 3)::json,
  'corridor_km2', round(coalesce(sum(ST_Area(g::geography)), 0) / 1e6),
  'region_km2', (select round(ST_Area(g::geography) / 1e6) from region))
from kept;
"""


def psql(db, sql):
    result = subprocess.run(
        ["psql", db, "-v", "ON_ERROR_STOP=1", "-tAqX", "-F", " ", "-f", "-"],
        input=sql, capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.exit(f"corridor query failed: {result.stderr.strip()}")
    return result.stdout


def grow(cells, cell_m, metres):
    """Runs of grid cells within `metres` of the given cells: {row: [(first column, last column)]}."""
    columns_by_row = defaultdict(list)
    for x, y in cells:
        columns_by_row[y].append(x)

    runs = defaultdict(list)
    for y, columns in columns_by_row.items():
        latitude = math.atan(math.sinh((y + 0.5) * cell_m / EARTH_RADIUS_M))
        radius = metres / max(math.cos(latitude), 0.08) / cell_m + 1  # in cells; capped beyond 85 degrees
        columns.sort()
        for dy in range(-int(radius), int(radius) + 1):
            half = math.sqrt(radius * radius - dy * dy)
            row = runs[y + dy]
            first, last = None, None
            for x in columns:
                lo, hi = math.floor(x - half), math.ceil(x + half)
                if first is None:
                    first, last = lo, hi
                elif lo <= last + 1:
                    last = hi
                else:
                    row.append((first, last))
                    first, last = lo, hi
            row.append((first, last))

    merged = {}
    for y, row in runs.items():
        row.sort()
        out = [row[0]]
        for lo, hi in row[1:]:
            if lo <= out[-1][1] + 1:
                if hi > out[-1][1]:
                    out[-1] = (out[-1][0], hi)
            else:
                out.append((lo, hi))
        merged[y] = out
    return merged


def strips_wkt(runs, cell_m):
    """One rectangle per run, as a MULTIPOLYGON in Web Mercator."""
    rectangles = []
    for y, row in runs.items():
        y0, y1 = y * cell_m, (y + 1) * cell_m
        for lo, hi in row:
            x0, x1 = lo * cell_m, (hi + 1) * cell_m
            rectangles.append(f"(({x0:.0f} {y0:.0f},{x1:.0f} {y0:.0f},{x1:.0f} {y1:.0f},{x0:.0f} {y1:.0f},{x0:.0f} {y0:.0f}))")
    return "MULTIPOLYGON(" + ",".join(rectangles) + ")"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cache_dir")
    ap.add_argument("region")
    ap.add_argument("--db", required=True, help="database the region was imported into")
    ap.add_argument("--km", type=float, default=100, help="distance from the tracks to keep")
    ap.add_argument("--poly", required=True, help="where to write the .poly file")
    args = ap.parse_args()

    metres = args.km * 1000
    cell_m = metres * GRID_SHARE
    cells = [tuple(int(v) for v in line.split()) for line in psql(args.db, CELLS_SQL.format(cell=cell_m)).splitlines() if line]
    if not cells:
        sys.exit("no railway lines in the database, so there is no corridor")

    runs = grow(cells, cell_m, metres)
    row = json.loads(psql(args.db, OUTLINE_SQL.format(
        strips=strips_wkt(runs, cell_m),
        cell=cell_m,
        min_part=MIN_PART_KM2,
        region=json.dumps(geometry_for(args.cache_dir, args.region)),
    )))
    geometry = row["geometry"]
    if not geometry or not geometry["coordinates"]:
        sys.exit("the corridor does not overlap the region outline")

    rings = [polygon[0] for polygon in geometry["coordinates"]]
    with open(args.poly, "w") as f:
        f.write(f"{args.region}\n")
        for i, ring in enumerate(rings, 1):
            f.write(f"{i}\n")
            for lon, lat in ring:
                f.write(f"   {lon:.3f}   {lat:.3f}\n")
            f.write("END\n")
        f.write("END\n")

    share = 100 * row["corridor_km2"] / row["region_km2"] if row["region_km2"] else 0
    print(
        f"corridor of {args.km:g} km around {len(cells)} track cells: {len(rings)} area(s), "
        f"{row['corridor_km2']:,.0f} km2 = {share:.0f}% of the region",
        file=sys.stderr,
    )
    print(json.dumps(rings, separators=(",", ":")))


if __name__ == "__main__":
    main()
