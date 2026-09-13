#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
"""Write manifest.json for the packs found in an output directory.

Each pack directory `<out>/<id>/` must contain `pack-meta.json` (written by build-country.sh)
and `railway.pmtiles`, optionally `basemap.pmtiles`.

Usage: make_manifest.py <out-dir> --base-url https://example.com/packs
"""
import argparse
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from geofabrik import load_index  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out_dir")
    ap.add_argument("--base-url", required=True, help="public URL under which <out-dir> is served (no trailing slash)")
    ap.add_argument(
        "--geofabrik-cache",
        default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "work"),
        help="directory holding the cached Geofabrik index (used for display names of regions)",
    )
    args = ap.parse_args()
    base = args.base_url.rstrip("/")
    try:
        regions = load_index(args.geofabrik_cache)
    except Exception as e:  # offline: fall back to the app formatting region ids itself
        print(f"warning: no Geofabrik index, region names left out ({e})")
        regions = {}

    packs = []
    for pack_id in sorted(os.listdir(args.out_dir)):
        pdir = os.path.join(args.out_dir, pack_id)
        meta_path = os.path.join(pdir, "pack-meta.json")
        railway = os.path.join(pdir, "railway.pmtiles")
        if not (os.path.isfile(meta_path) and os.path.isfile(railway)):
            continue
        meta = json.load(open(meta_path))
        basemap = os.path.join(pdir, "basemap.pmtiles")
        entry = {
            "id": pack_id,
            "name": meta["name"],
            "region": meta.get("region", ""),
            "region_name": regions.get(meta.get("region", ""), {}).get("name", ""),
            "railway_url": f"{base}/{pack_id}/railway.pmtiles",
            "railway_bytes": os.path.getsize(railway),
            "basemap_url": f"{base}/{pack_id}/basemap.pmtiles" if os.path.isfile(basemap) else None,
            "basemap_bytes": os.path.getsize(basemap) if os.path.isfile(basemap) else 0,
            "bbox": meta["bbox"],
            "data_date": meta.get("data_date", ""),
            "version": meta.get("version", 1),
            "coverage": meta.get("coverage"),
        }
        packs.append(entry)

    manifest = {
        "format": 1,
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "packs": packs,
    }
    with open(os.path.join(args.out_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, separators=(",", ":"))
    print(f"wrote manifest with {len(packs)} pack(s)")


if __name__ == "__main__":
    main()
