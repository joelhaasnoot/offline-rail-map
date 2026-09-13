#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
#
# Rebuild every country pack listed in a manifest, refreshing the manifest after each one.
#
#   pipeline/build-all.sh [--manifest FILE_OR_URL] [--base-url URL] [--only id,id] [--dry-run] [-- build-country options]
#
# Examples:
#   pipeline/build-all.sh                                   # every pack in pipeline/out/manifest.json
#   pipeline/build-all.sh --only belgium,netherlands
#   pipeline/build-all.sh -- --basemap-maxzoom 12           # pass options on to build-country.sh
#
# Run it where the packs are served from: the manifest is regenerated from pipeline/out, so packs
# missing there drop out of it. Packs are built smallest first. A failing country is logged to
# pipeline/work/logs/<id>.log and skipped; the script exits non-zero at the end if any failed.
# Downloaded extracts are deleted after each build (set DELETE_EXTRACT=0 to keep them).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIPELINE="$ROOT/pipeline"
OUT="$PIPELINE/out"
LOGS="$PIPELINE/work/logs"
MANIFEST="$OUT/manifest.json"
BASE_URL=""
ONLY=""
DRY_RUN=0
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; EXTRA=("$@"); break ;;
    -h|--help) sed -n '5,17p' "$0"; exit 0 ;;
    *) echo "unknown option $1 (build-country options go after --)" >&2; exit 1 ;;
  esac
done

mkdir -p "$LOGS"
MANIFEST_COPY="$(mktemp)"
trap 'rm -f "$MANIFEST_COPY"' EXIT
if [[ "$MANIFEST" == http://* || "$MANIFEST" == https://* ]]; then
  curl -fsSL "$MANIFEST" -o "$MANIFEST_COPY"
else
  cp "$MANIFEST" "$MANIFEST_COPY"
fi

# Prints "BASE <url>" and then one "<id> <bytes>" line per pack, smallest pack first.
PLAN="$(python3 - "$MANIFEST_COPY" "$ONLY" <<'PY'
import json, sys
manifest, only = json.load(open(sys.argv[1])), [x for x in sys.argv[2].split(",") if x]
packs = manifest["packs"]
known = {p["id"] for p in packs}
missing = [x for x in only if x not in known]
if missing:
    sys.exit(f"not in the manifest: {', '.join(missing)}")
if only:
    packs = [p for p in packs if p["id"] in only]
base = ""
for p in manifest["packs"]:
    suffix = f"/{p['id']}/railway.pmtiles"
    if p["railway_url"].endswith(suffix):
        base = p["railway_url"][: -len(suffix)]
        break
print("BASE", base)
for p in sorted(packs, key=lambda p: p["railway_bytes"] + p["basemap_bytes"]):
    print(p["id"], p["railway_bytes"] + p["basemap_bytes"])
PY
)"

if [[ -z "$BASE_URL" ]]; then
  BASE_URL="$(echo "$PLAN" | awk '$1 == "BASE" { print $2 }')"
fi
if [[ -z "$BASE_URL" ]]; then
  echo "could not work out the public base URL from the manifest; pass --base-url" >&2
  exit 1
fi
IDS=()
while read -r id bytes; do
  [[ "$id" == "BASE" || -z "$id" ]] && continue
  IDS+=("$id")
done <<< "$PLAN"

echo "Manifest: $MANIFEST"
echo "Base URL: $BASE_URL"
echo "Packs (${#IDS[@]}, smallest first): ${IDS[*]}"
echo "build-country options: ${EXTRA[*]:-(defaults)}"
if [[ "$DRY_RUN" == "1" ]]; then
  for id in "${IDS[@]}"; do
    echo "  DELETE_EXTRACT=${DELETE_EXTRACT:-1} $PIPELINE/build-country.sh $id ${EXTRA[*]:-}"
  done
  echo "  then after each: python3 $PIPELINE/make_manifest.py $OUT --base-url $BASE_URL"
  exit 0
fi

OK=()
FAILED=()
START_ALL=$(date +%s)
i=0
for id in "${IDS[@]}"; do
  i=$((i + 1))
  log="$LOGS/$id.log"
  start=$(date +%s)
  echo "[$i/${#IDS[@]}] $id: building (log: $log)"
  if DELETE_EXTRACT="${DELETE_EXTRACT:-1}" "$PIPELINE/build-country.sh" "$id" ${EXTRA[@]+"${EXTRA[@]}"} > "$log" 2>&1; then
    python3 "$PIPELINE/make_manifest.py" "$OUT" --base-url "$BASE_URL" >> "$log" 2>&1
    OK+=("$id")
    sizes="$(du -h "$OUT/$id"/*.pmtiles 2>/dev/null | awk '{printf "%s %s  ", $2, $1}' | sed "s|$OUT/$id/||g")"
    echo "[$i/${#IDS[@]}] $id: done in $(( ($(date +%s) - start) / 60 )) min  $sizes"
  else
    FAILED+=("$id")
    echo "[$i/${#IDS[@]}] $id: FAILED after $(( ($(date +%s) - start) / 60 )) min, last lines of the log:"
    tail -5 "$log" | sed 's/^/    /'
  fi
done

echo
echo "Finished in $(( ($(date +%s) - START_ALL) / 60 )) min: ${#OK[@]} built, ${#FAILED[@]} failed."
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "Failed: ${FAILED[*]}"
  exit 1
fi
