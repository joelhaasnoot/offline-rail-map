# Offline Railway Map

An Android app that shows the [OpenRailwayMap](https://openrailwaymap.app) cartography fully
offline: infrastructure, speed, train protection (signalling), electrification, gauge and operator
views, exactly like the web app, rendered from country packs you download once.

OpenRailwayMap's tile usage policy forbids bulk-downloading their tiles, so this project rebuilds
the same vector tiles from OpenStreetMap data with OpenRailwayMap's own open-source (GPL-3.0)
import pipeline and style, splits them per country and serves them as downloadable packs.

```
OSM extract (Geofabrik)
   │  osmium tags-filter (railway features only)
   ▼
OpenRailwayMap-vector import  (osm2pgsql + PostGIS, docker)
   │  Martin renders MVT tiles from the same SQL functions the website uses
   ▼
pipeline/bake_tiles.py  → railway.pmtiles   (all layers, z0–16, ~40 MB for the Netherlands)
planetiler              → basemap.pmtiles   (slim OpenMapTiles basemap, z0–12, ~55 MB for NL)
   ▼
manifest.json  ──▶  Android app (MapLibre Native, PMTiles from local files)
```

## Repository layout

| Path | What |
|------|------|
| `android/` | Android app (Kotlin, Jetpack Compose, MapLibre Native 13); the Gradle project lives here, the module is `android/app` |
| `android/app/src/main/assets/style/orm-style.json` | Generated OpenRailwayMap style (see `pipeline/prepare_style.py`) |
| `android/app/src/main/assets/style/basemap-style.json` | Hand-written light basemap style for the OpenMapTiles schema |
| `android/app/src/main/assets/sprites`, `assets/font` | Generated OpenRailwayMap symbols and glyphs |
| `ios/` | (planned) iOS app |
| `pipeline/build-country.sh` | End-to-end pack build for one Geofabrik region |
| `pipeline/build-all.sh` | Rebuilds every pack listed in a manifest and refreshes the manifest |
| `pipeline/build-world.sh` | Builds the zoom 0–4 world overview bundled in the app |
| `pipeline/bake_tiles.py` | Walks the tile pyramid against Martin and writes MBTiles |
| `pipeline/prepare_style.py` | Turns upstream style + sprites + fonts into app assets |
| `pipeline/make_manifest.py` | Writes `manifest.json` listing the packs in an output dir |

## Building packs

Requirements on the build machine: Docker, `osmium`, `martin`, `pmtiles`, `psql`, Python 3 with
Pillow and Java 21 (for Planetiler). Node.js is only needed to regenerate the app's style assets.

```bash
pipeline/build-country.sh netherlands                      # railway + basemap pack
pipeline/build-country.sh belgium --no-basemap             # railway only
pipeline/build-country.sh germany --basemap-maxzoom 13     # more basemap detail (about 2.5x larger)
pipeline/make_manifest.py pipeline/out --base-url https://packs.example.com
```

Railway tiles go to zoom 16. Basemaps stop at zoom 12 by default: compared side by side with zoom 13
they look nearly identical, at 40% of the size (Netherlands: 54 MB instead of 142 MB).

To rebuild every pack that is in the current manifest (smallest first, refreshing the manifest after
each pack, failures logged to `pipeline/work/logs/` and skipped):

```bash
pipeline/build-all.sh                          # packs listed in pipeline/out/manifest.json
pipeline/build-all.sh --only belgium,france    # a subset
pipeline/build-all.sh --dry-run                # show the plan without building
```

Upload `pipeline/out/` to any static host (S3/R2/GitHub Releases/a web server) and point the app
at `<base-url>/manifest.json`.

The first run clones `hiddewie/OpenRailwayMap-vector` into `pipeline/work/`. Regenerate the app's
style assets after upstream style changes with:

```bash
cd pipeline/work/OpenRailwayMap-vector && node proxy/js/styles.mjs > ../style.json
martin --sprite ./symbols --listen-addresses 127.0.0.1:3999 &   # then fetch /sprite/symbols*.json|png and /sdf_sprite/... into pipeline/work/sprites/
python3 ../../prepare_style.py
```

Each pack also carries the Geofabrik region polygon (`pipeline/coverage.py`), which the app uses to
tell "no data here yet" from "this area is in a pack you haven't downloaded" and to offer that
download directly on the map.

## World overview

The app ships a small world map (zoom 0–4, about 3 MB) so it is never blank: coastlines, borders
and glaciers from Natural Earth, with continent, country, state, city and sea labels from
OpenStreetMap. Inside a downloaded country the detailed pack takes over; the app masks the pack's
region outline so the coarse world coastline never shows through. Rebuild it with:

```bash
pipeline/build-world.sh
```

## Building the app

```bash
cd android && ./gradlew :app:assembleDebug
```

Unit tests (pack coverage and manifest parsing):

```bash
cd android && ./gradlew :app:testDebugUnitTest
```

By default the app reads the published packs from `https://data.offlinerailmap.com/manifest.json`.
To test packs built locally, serve them with `cd pipeline/out && python3 -m http.server 8765` and
build with `-PmanifestUrl=http://10.0.2.2:8765/manifest.json` (the host machine as seen from the
Android emulator).

## How the style switching works

The upstream style is one big MapLibre style whose layers react to `global-state` values
(`tracks`, `signals`, `stations`, …). MapLibre Native does not evaluate `global-state`, so
`StyleBuilder` substitutes the values for the selected view and options into the expressions,
evaluates every layer's `visibility` expression to a constant and drops hidden layers before
handing the style to the map. Each installed country pack gets its own copy of the sources and
layers, so several countries can be shown at once.

## License

The whole project is licensed under the **GNU General Public License v3.0 or later** (see
`LICENSE`). It is a derivative of the OpenRailwayMap vector style and pipeline, and the parts that
come from there keep their upstream copyright; `NOTICE` lists exactly which files are derived from
which project and what they contain:

- OpenRailwayMap-vector (GPL-3.0-or-later, © Hidde Wieringa; earlier styles © Michael Reichert and
  © Alexander Matheisen): the generated map style, sprite sheets and OpenRailwayMap glyphs, and the
  import/tile pipeline this project drives.
- Fira Code (SIL Open Font License 1.1): the FiraCode glyphs.
- Everything else (Android app code, basemap style, pipeline scripts) was written for this project
  and is released under the same GPL-3.0-or-later.

Map data © OpenStreetMap contributors (ODbL). Basemap tiles are produced with Planetiler
(Apache-2.0) in the OpenMapTiles schema (BSD-3-Clause schema, CC-BY 4.0 design).
