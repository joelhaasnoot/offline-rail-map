#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
#
# Build an offline OpenRailwayMap country pack from a Geofabrik extract.
#
#   pipeline/build-country.sh <geofabrik-region-id> [--maxzoom N] [--no-basemap] [--basemap-maxzoom N]
#                             [--corridor auto|always|never] [--corridor-km N]
#
# Example: pipeline/build-country.sh netherlands
#          pipeline/build-country.sh europe/belgium     (<parent>/<id> also works; the pack id is the last path segment)
#
# Large, mostly empty countries: when a pack comes out over 1.5 GB (CORRIDOR_OVER_MB), its basemap
# is rebuilt for the rail corridor only, the area within 100 km of a railway (see corridor.py).
# The pack remembers this, so later builds go straight to the corridor. --corridor always does it
# whatever the size, --corridor never turns it off. Regions in CORRIDOR_REGIONS get it whatever
# their size, unless --corridor says otherwise.
#
# Produces pipeline/out/<id>/railway.pmtiles (+ basemap.pmtiles, pack-meta.json).
# Finished files replace the old ones in one step, so a pack being rebuilt can keep being served.
# Afterwards run: pipeline/make_manifest.py pipeline/out --base-url https://your.host/packs
#
# Set DELETE_EXTRACT=1 to remove the downloaded .osm.pbf afterwards (saves disk on large countries).
# Requirements: docker (compose), osmium, martin, pmtiles, psql, python3 (+Pillow), node, Java 21.
set -euo pipefail

REGION="${1:?usage: build-country.sh <geofabrik-region-id> [--maxzoom N] [--no-basemap] [--basemap-maxzoom N] [--corridor auto|always|never] [--corridor-km N]}"
shift
MAXZOOM=16
BASEMAP=1
BASEMAP_MAXZOOM=12 # zoom 13 looks nearly the same but is about 2.5x larger
CORRIDOR=auto
CORRIDOR_KM=100
CORRIDOR_OVER_MB="${CORRIDOR_OVER_MB:-1500}"
# Geofabrik ids (space separated) of mostly empty regions that stay under the limit but are still
# limited to the corridor.
CORRIDOR_REGIONS="${CORRIDOR_REGIONS:-australia}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --maxzoom) MAXZOOM="$2"; shift 2 ;;
    --no-basemap) BASEMAP=0; shift ;;
    --basemap-maxzoom) BASEMAP_MAXZOOM="$2"; shift 2 ;;
    --corridor) CORRIDOR="$2"; shift 2 ;;
    --corridor-km) CORRIDOR_KM="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIPELINE="$ROOT/pipeline"
WORK="$PIPELINE/work"
OUT="$PIPELINE/out"
ORM="$WORK/OpenRailwayMap-vector"
source "$PIPELINE/upstream.sh"
PACK_ID="${REGION##*/}"
PACK_OUT="$OUT/$PACK_ID"
DB_PORT="${DB_PORT:-5439}"
MARTIN_PORT="${MARTIN_PORT:-3000}"
DB_URL="postgresql://postgres@127.0.0.1:$DB_PORT/gis"
JAVA="${JAVA:-java}"

case "$CORRIDOR" in
  auto|always|never) ;;
  *) echo "--corridor must be auto, always or never" >&2; exit 1 ;;
esac

mkdir -p "$WORK" "$PACK_OUT"

echo "== Region lookup =="
IFS=$'\t' read -r PBF_URL NAME PARENT REGION_ID < <(python3 "$PIPELINE/geofabrik.py" "$WORK" "$REGION")
echo "$NAME ($PARENT): $PBF_URL"
if [[ "$CORRIDOR" == "auto" && " $CORRIDOR_REGIONS " == *" $REGION_ID "* ]]; then
  CORRIDOR=always
fi

echo "== OSM extract =="
PBF="$WORK/$PACK_ID.osm.pbf"
curl -fL --retry 3 -z "$PBF" -o "$PBF" "$PBF_URL"
DATA_DATE="$(osmium fileinfo --get header.option.osmosis_replication_timestamp "$PBF" 2>/dev/null || true)"
if [[ -z "$DATA_DATE" ]]; then
  DATA_DATE="$(osmium fileinfo --get header.option.timestamp "$PBF" 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
echo "data timestamp: $DATA_DATE"

echo "== OpenRailwayMap-vector checkout =="
checkout_upstream "$ORM"
cp "$PIPELINE/compose.override.yaml" "$ORM/compose.override.yaml"

echo "== Filter railway data =="
mkdir -p "$ORM/data/filtered"
osmium tags-filter "$PBF" --overwrite --output "$ORM/data/filtered/data.osm.pbf" --expressions "$ORM/import/osmium-tags-filter"
echo "$DATA_DATE" > "$ORM/data/filtered/data.osm.pbf.timestamp"

echo "== Import into PostGIS (docker) =="
(cd "$ORM" && docker compose build db import && docker compose up -d --force-recreate --wait db \
  && OSM2PGSQL_NUMPROC="${OSM2PGSQL_NUMPROC:-8}" docker compose run --rm --no-deps import import)
psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f "$PIPELINE/sql/offline_tiles.sql"

echo "== Bounding box =="
BBOX="$(psql "$DB_URL" -tAc "select round(ST_XMin(e)::numeric-0.05,3)||','||round(ST_YMin(e)::numeric-0.05,3)||','||round(ST_XMax(e)::numeric+0.05,3)||','||round(ST_YMax(e)::numeric+0.05,3) from (select ST_Extent(ST_Transform(way,4326)) e from railway_line) s")"
echo "bbox: $BBOX"
if [[ -z "$BBOX" ]]; then
  echo "no railway lines in $REGION, nothing to build" >&2
  (cd "$ORM" && docker compose stop db)
  exit 1
fi

CORRIDOR_POLY="$WORK/$PACK_ID-corridor.poly"
CORRIDOR_COVERAGE=""
if [[ "$BASEMAP" == "1" && "$CORRIDOR" != "never" ]]; then
  echo "== Rail corridor =="
  CORRIDOR_COVERAGE="$(python3 "$PIPELINE/corridor.py" "$WORK" "$REGION_ID" --db "$DB_URL" --km "$CORRIDOR_KM" --poly "$CORRIDOR_POLY")"
fi

echo "== Bake vector tiles =="
# Functions that only start at zoom 17 are pulled down to the baked maximum zoom so their data is
# present in the deepest tiles (MapLibre overzooms from there). Then every function is limited to
# the zooms the app's style draws it at. Railway lines come from the offline variant of the upstream
# function (pipeline/sql/offline_tiles.sql).
sed -e "s/minzoom: 17/minzoom: $MAXZOOM/" -e "s/function: railway_line_high$/function: railway_line_high_offline/" \
  "$ORM/martin/configuration.yml" > "$WORK/martin-full.yml"
python3 "$PIPELINE/trim_zooms.py" "$WORK/martin-full.yml" "$ROOT/android/app/src/main/assets/style/orm-style.json" \
  --maxzoom "$MAXZOOM" > "$WORK/martin-bake.yml"
pkill -x martin || true
DATABASE_URL="$DB_URL" martin --config "$WORK/martin-bake.yml" --listen-addresses "127.0.0.1:$MARTIN_PORT" > "$WORK/martin.log" 2>&1 &
MARTIN_PID=$!
trap 'kill $MARTIN_PID 2>/dev/null || true' EXIT
sleep 4
rm -f "$PACK_OUT/railway.mbtiles"
python3 "$PIPELINE/bake_tiles.py" --martin "http://127.0.0.1:$MARTIN_PORT" --config "$WORK/martin-bake.yml" \
  --bbox="$BBOX" --maxzoom "$MAXZOOM" --concurrency "${BAKE_CONCURRENCY:-16}" \
  --output "$PACK_OUT/railway.mbtiles" --name "OpenRailwayMap $NAME"
pmtiles convert "$PACK_OUT/railway.mbtiles" "$PACK_OUT/railway.new.pmtiles"
mv -f "$PACK_OUT/railway.new.pmtiles" "$PACK_OUT/railway.pmtiles"
rm -f "$PACK_OUT/railway.mbtiles"
kill $MARTIN_PID 2>/dev/null || true
(cd "$ORM" && docker compose stop db)

# Corridor distance in km the basemap was limited to; empty when it covers the whole region.
BASEMAP_CORRIDOR_KM=""
if [[ "$BASEMAP" == "1" ]]; then
  echo "== Basemap (planetiler) =="
  if [[ ! -f "$WORK/planetiler.jar" ]]; then
    curl -fL -o "$WORK/planetiler.jar" https://github.com/onthegomap/planetiler/releases/latest/download/planetiler.jar
  fi
  # Extra arguments are passed on to Planetiler.
  build_basemap() {
    (cd "$WORK" && "$JAVA" -Xmx6g -jar planetiler.jar --osm-path="$PBF" --output="$PACK_OUT/basemap.new.pmtiles" --download \
      --only_layers=water,water_name,waterway,landcover,landuse,park,boundary,aeroway,transportation,place \
      --maxzoom="$BASEMAP_MAXZOOM" --languages=en,nl,de,fr --force "$@")
  }
  # A pack that was limited to its corridor before stays that way.
  if [[ "$CORRIDOR" == "always" ]] || { [[ "$CORRIDOR" == "auto" ]] && grep -q '"basemap_corridor_km"' "$PACK_OUT/pack-meta.json" 2>/dev/null; }; then
    BASEMAP_CORRIDOR_KM="$CORRIDOR_KM"
  fi
  if [[ -n "$BASEMAP_CORRIDOR_KM" ]]; then
    echo "basemap limited to $CORRIDOR_KM km around the tracks"
    build_basemap --polygon="$CORRIDOR_POLY"
  else
    build_basemap
    PACK_MB=$(( ($(wc -c < "$PACK_OUT/railway.pmtiles") + $(wc -c < "$PACK_OUT/basemap.new.pmtiles")) / 1000000 ))
    if [[ "$CORRIDOR" == "auto" && "$PACK_MB" -gt "$CORRIDOR_OVER_MB" ]]; then
      echo "pack is $PACK_MB MB (over $CORRIDOR_OVER_MB MB): rebuilding the basemap for $CORRIDOR_KM km around the tracks"
      BASEMAP_CORRIDOR_KM="$CORRIDOR_KM"
      build_basemap --polygon="$CORRIDOR_POLY"
    fi
  fi
  mv -f "$PACK_OUT/basemap.new.pmtiles" "$PACK_OUT/basemap.pmtiles"
fi

echo "== Pack metadata =="
# The coverage is where the app hides its world overview and expects the pack's own map, so a
# basemap limited to the rail corridor has the corridor as its coverage.
if [[ -n "$BASEMAP_CORRIDOR_KM" ]]; then
  COVERAGE="$CORRIDOR_COVERAGE"
else
  COVERAGE="$(python3 "$PIPELINE/coverage.py" "$WORK" "$REGION_ID")"
fi
python3 - "$PACK_OUT/pack-meta.json" "$PACK_ID" "$NAME" "$PARENT" "$BBOX" "$DATA_DATE" "$COVERAGE" "$BASEMAP" "$BASEMAP_CORRIDOR_KM" <<'PY'
import json, sys
out, pack_id, name, parent, bbox, date, coverage, basemap_built, corridor_km = sys.argv[1:]
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
if corridor_km:
    meta["basemap_corridor_km"] = float(corridor_km)
elif basemap_built == "0" and "basemap_corridor_km" in existing:
    # --no-basemap keeps the old basemap file, and with it the corridor it was limited to.
    meta["basemap_corridor_km"] = existing["basemap_corridor_km"]
    meta["coverage"] = existing["coverage"]
json.dump(meta, open(out, "w"), indent=2)
print(meta)
PY
if [[ "${DELETE_EXTRACT:-0}" == "1" ]]; then
  echo "== Removing extract and filtered data to free disk space =="
  rm -f "$PBF" "$ORM/data/filtered/data.osm.pbf"
fi
ls -la "$PACK_OUT"
echo "== Done: $PACK_OUT =="
