#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
#
# Build an offline OpenRailwayMap country pack from a Geofabrik extract.
#
#   pipeline/build-country.sh <geofabrik-region-id> [--maxzoom N] [--no-basemap] [--basemap-maxzoom N]
#
# Example: pipeline/build-country.sh netherlands
#          pipeline/build-country.sh europe/belgium     (nested ids use the last path segment as pack id)
#
# Produces pipeline/out/<id>/railway.pmtiles (+ basemap.pmtiles, pack-meta.json).
# Afterwards run: pipeline/make_manifest.py pipeline/out --base-url https://your.host/packs
#
# Set DELETE_EXTRACT=1 to remove the downloaded .osm.pbf afterwards (saves disk on large countries).
# Requirements: docker (compose), osmium, martin, pmtiles, psql, python3 (+Pillow), node, Java 21.
set -euo pipefail

REGION="${1:?usage: build-country.sh <geofabrik-region-id> [--maxzoom N] [--no-basemap] [--basemap-maxzoom N]}"
shift
MAXZOOM=16
BASEMAP=1
BASEMAP_MAXZOOM=13
while [[ $# -gt 0 ]]; do
  case "$1" in
    --maxzoom) MAXZOOM="$2"; shift 2 ;;
    --no-basemap) BASEMAP=0; shift ;;
    --basemap-maxzoom) BASEMAP_MAXZOOM="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIPELINE="$ROOT/pipeline"
WORK="$PIPELINE/work"
OUT="$PIPELINE/out"
ORM="$WORK/OpenRailwayMap-vector"
ORM_REF="${ORM_REF:-master}"
PACK_ID="${REGION##*/}"
PACK_OUT="$OUT/$PACK_ID"
DB_PORT="${DB_PORT:-5439}"
MARTIN_PORT="${MARTIN_PORT:-3000}"
DB_URL="postgresql://postgres@127.0.0.1:$DB_PORT/gis"
JAVA="${JAVA:-java}"

mkdir -p "$WORK" "$PACK_OUT"

echo "== Region lookup =="
IFS=$'\t' read -r PBF_URL NAME PARENT < <(python3 "$PIPELINE/geofabrik.py" "$WORK" "$REGION")
echo "$NAME ($PARENT): $PBF_URL"

echo "== OSM extract =="
PBF="$WORK/$PACK_ID.osm.pbf"
curl -fL --retry 3 -z "$PBF" -o "$PBF" "$PBF_URL"
DATA_DATE="$(osmium fileinfo --get header.option.osmosis_replication_timestamp "$PBF" 2>/dev/null || true)"
if [[ -z "$DATA_DATE" ]]; then
  DATA_DATE="$(osmium fileinfo --get header.option.timestamp "$PBF" 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
echo "data timestamp: $DATA_DATE"

echo "== OpenRailwayMap-vector checkout =="
if [[ ! -d "$ORM/.git" ]]; then
  git clone --depth 1 --branch "$ORM_REF" https://github.com/hiddewie/OpenRailwayMap-vector.git "$ORM"
fi
cp "$PIPELINE/compose.override.yaml" "$ORM/compose.override.yaml"

echo "== Filter railway data =="
mkdir -p "$ORM/data/filtered"
osmium tags-filter "$PBF" --overwrite --output "$ORM/data/filtered/data.osm.pbf" --expressions "$ORM/import/osmium-tags-filter"
echo "$DATA_DATE" > "$ORM/data/filtered/data.osm.pbf.timestamp"

echo "== Import into PostGIS (docker) =="
(cd "$ORM" && docker compose build db import && docker compose up -d --force-recreate --wait db \
  && OSM2PGSQL_NUMPROC="${OSM2PGSQL_NUMPROC:-8}" docker compose run --rm --no-deps import import)

echo "== Bounding box =="
BBOX="$(psql "$DB_URL" -tAc "select round(ST_XMin(e)::numeric-0.05,3)||','||round(ST_YMin(e)::numeric-0.05,3)||','||round(ST_XMax(e)::numeric+0.05,3)||','||round(ST_YMax(e)::numeric+0.05,3) from (select ST_Extent(ST_Transform(way,4326)) e from railway_line) s")"
echo "bbox: $BBOX"

echo "== Bake vector tiles =="
# Functions that only start at zoom 17 are pulled down to the baked maximum zoom so their data is
# present in the deepest tiles (MapLibre overzooms from there).
sed "s/minzoom: 17/minzoom: $MAXZOOM/" "$ORM/martin/configuration.yml" > "$WORK/martin-bake.yml"
pkill -x martin || true
DATABASE_URL="$DB_URL" martin --config "$WORK/martin-bake.yml" --listen-addresses "127.0.0.1:$MARTIN_PORT" > "$WORK/martin.log" 2>&1 &
MARTIN_PID=$!
trap 'kill $MARTIN_PID 2>/dev/null || true' EXIT
sleep 4
rm -f "$PACK_OUT/railway.mbtiles"
python3 "$PIPELINE/bake_tiles.py" --martin "http://127.0.0.1:$MARTIN_PORT" --config "$WORK/martin-bake.yml" \
  --bbox="$BBOX" --maxzoom "$MAXZOOM" --concurrency "${BAKE_CONCURRENCY:-16}" \
  --output "$PACK_OUT/railway.mbtiles" --name "OpenRailwayMap $NAME"
pmtiles convert "$PACK_OUT/railway.mbtiles" "$PACK_OUT/railway.pmtiles"
rm -f "$PACK_OUT/railway.mbtiles"
kill $MARTIN_PID 2>/dev/null || true
(cd "$ORM" && docker compose stop db)

if [[ "$BASEMAP" == "1" ]]; then
  echo "== Basemap (planetiler) =="
  if [[ ! -f "$WORK/planetiler.jar" ]]; then
    curl -fL -o "$WORK/planetiler.jar" https://github.com/onthegomap/planetiler/releases/latest/download/planetiler.jar
  fi
  (cd "$WORK" && "$JAVA" -Xmx6g -jar planetiler.jar --osm-path="$PBF" --output="$PACK_OUT/basemap.pmtiles" --download \
    --only_layers=water,water_name,waterway,landcover,landuse,park,boundary,aeroway,transportation,place \
    --maxzoom="$BASEMAP_MAXZOOM" --languages=en,nl,de,fr --force)
fi

echo "== Pack metadata =="
COVERAGE="$(python3 "$PIPELINE/coverage.py" "$WORK" "$REGION")"
python3 - "$PACK_OUT/pack-meta.json" "$PACK_ID" "$NAME" "$PARENT" "$BBOX" "$DATA_DATE" "$COVERAGE" <<'PY'
import json, sys
out, pack_id, name, parent, bbox, date, coverage = sys.argv[1:]
existing = {}
try:
    existing = json.load(open(out))
except Exception:
    pass
meta = {
    "id": pack_id,
    "name": name,
    "region": parent,
    "bbox": [float(v) for v in bbox.split(",")],
    "data_date": date,
    "version": int(existing.get("version", 0)) + 1,
    "coverage": json.loads(coverage),
}
json.dump(meta, open(out, "w"), indent=2)
print(meta)
PY
if [[ "${DELETE_EXTRACT:-0}" == "1" ]]; then
  echo "== Removing extract and filtered data to free disk space =="
  rm -f "$PBF" "$ORM/data/filtered/data.osm.pbf"
fi
ls -la "$PACK_OUT"
echo "== Done: $PACK_OUT =="
