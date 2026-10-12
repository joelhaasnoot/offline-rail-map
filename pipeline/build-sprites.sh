#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
#
# Regenerate the app's style assets from the pinned upstream OpenRailwayMap-vector (upstream.sh):
# generate upstream's style and legend, build the sprite sheets from upstream's symbols plus this
# project's replacements in pipeline/symbols (same relative paths win), then refresh the app assets
# with prepare_style.py.
#
#   pipeline/build-sprites.sh
#
# Requirements: node, npm, martin, curl, python3 with Pillow.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIPELINE="$ROOT/pipeline"
WORK="$PIPELINE/work"
ORM="$WORK/OpenRailwayMap-vector"
source "$PIPELINE/upstream.sh"
MERGED="$WORK/sprite-build/symbols" # Martin names the sprite after this folder
PORT="${SPRITE_PORT:-3999}"

checkout_upstream "$ORM"

# Upstream's generators need the yaml package (version as in upstream's proxy.Dockerfile); Node finds
# it in work/node_modules from the checkout below.
[[ -d "$WORK/node_modules/yaml" ]] || npm install --silent --no-save --prefix "$WORK" yaml@2.8.1
(cd "$ORM" && node proxy/js/styles.mjs > "$WORK/style.json" && node proxy/js/legend.mjs > "$WORK/legend.json")

rm -rf "$MERGED" && mkdir -p "$(dirname "$MERGED")"
cp -R "$ORM/symbols" "$MERGED"
if [[ -d "$PIPELINE/symbols" ]]; then
  cp -R "$PIPELINE/symbols/." "$MERGED/"
  echo "replacement symbols: $(find "$PIPELINE/symbols" -name '*.svg' | wc -l | tr -d ' ')"
fi

martin --sprite "$MERGED" --listen-addresses "127.0.0.1:$PORT" > "$WORK/martin-sprites.log" 2>&1 &
MARTIN_PID=$!
trap 'kill $MARTIN_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do
  curl -fs -o /dev/null "http://127.0.0.1:$PORT/sprite/symbols.json" && break
  sleep 1
done

mkdir -p "$WORK/sprites"
for kind in sprite sdf_sprite; do
  for suffix in "" "@2x"; do
    for ext in json png; do
      curl -fsS -o "$WORK/sprites/${kind}_symbols${suffix}.${ext}" "http://127.0.0.1:$PORT/$kind/symbols${suffix}.${ext}"
    done
  done
done
kill $MARTIN_PID 2>/dev/null || true
python3 "$PIPELINE/prepare_style.py"
