#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
#
# Build the small world overview map that ships inside the app (zoom 0-4, a few MB).
#
#   pipeline/build-world.sh [--maxzoom N]
#
# Coastlines, lakes, glaciers and country borders come from Natural Earth; country, state, city,
# continent and sea labels come from OpenStreetMap place points fetched with one Overpass query.
# Writes android/app/src/main/assets/world/world.pmtiles.
#
# Requirements: curl, osmium, Java 21 (Planetiler is downloaded if missing).
set -euo pipefail

MAXZOOM=4 # Natural Earth country borders stop at zoom 4 in the OpenMapTiles profile
while [[ $# -gt 0 ]]; do
  case "$1" in
    --maxzoom) MAXZOOM="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/pipeline/work"
OUT="$ROOT/android/app/src/main/assets/world/world.pmtiles"
JAVA="${JAVA:-java}"
mkdir -p "$WORK/world" "$(dirname "$OUT")"

echo "== Place labels (Overpass) =="
QUERY='[out:xml][timeout:600];
(
  node["place"="continent"]["name"];
  node["place"="country"]["name"];
  node["place"="state"]["name"];
  node["place"="city"]["name"];
  node["place"="ocean"]["name"];
  node["place"="sea"]["name"];
);
out body;'
PLACES="$WORK/world/world-places.osm"
fetched=0
for url in https://overpass-api.de/api/interpreter https://overpass.kumi.systems/api/interpreter https://overpass.private.coffee/api/interpreter; do
  echo "trying $url"
  if curl -fsS --max-time 900 -A "offline-rail-map world build (https://github.com/joelhaasnoot/offline-rail-map)" \
      --data-urlencode "data=$QUERY" -o "$PLACES.tmp" "$url" && tail -c 20 "$PLACES.tmp" | grep -q "</osm>"; then
    mv "$PLACES.tmp" "$PLACES"; fetched=1; break
  fi
  sleep 5
done
[[ "$fetched" == "1" ]] || { echo "all Overpass servers failed" >&2; exit 1; }
osmium cat "$PLACES" -o "$WORK/world/world-places.osm.pbf" --overwrite
osmium fileinfo -e "$WORK/world/world-places.osm.pbf" | grep "Number of nodes"

echo "== World tiles (Planetiler) =="
if [[ ! -f "$WORK/planetiler.jar" ]]; then
  curl -fL -o "$WORK/planetiler.jar" https://github.com/onthegomap/planetiler/releases/latest/download/planetiler.jar
fi
(cd "$WORK" && "$JAVA" -Xmx6g -jar planetiler.jar --osm-path=world/world-places.osm.pbf --output=world/world.pmtiles \
  --bounds=world --maxzoom="$MAXZOOM" --only_layers=water,water_name,boundary,place,landcover \
  --languages=en --download --force)
cp "$WORK/world/world.pmtiles" "$OUT"
ls -la "$OUT"
echo "== Done: $OUT =="
