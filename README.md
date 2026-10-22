# Offline Rail Map

An Android and iPhone app that shows the [OpenRailwayMap](https://openrailwaymap.app) cartography fully
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
manifest.json  ──▶  Android and iOS apps (MapLibre Native, PMTiles from local files)
```

## Repository layout

| Path | What |
|------|------|
| `android/` | Android app (Kotlin, Jetpack Compose, MapLibre Native 13); the Gradle project lives here, the module is `android/app` |
| `android/app/src/main/assets/style/orm-style.json` | Generated OpenRailwayMap style (see `pipeline/prepare_style.py`) |
| `android/app/src/main/assets/style/basemap-style.json` | Hand-written light basemap style for the OpenMapTiles schema |
| `android/app/src/main/assets/sprites`, `assets/font` | Generated OpenRailwayMap symbols and glyphs |
| `ios/` | iOS app (Swift, SwiftUI, MapLibre Native iOS 6); `ios/OfflineRailwayMap.xcodeproj`, reads its style, legend, sprites, glyphs and world map from the Android assets folder |
| `ios/RailwayMapCore` | Swift package with everything that needs no UIKit: style building, packs and downloads, map key, coverage (`swift test`) |
| `pipeline/build-country.sh` | End-to-end pack build for one Geofabrik region |
| `pipeline/build-all.sh` | Rebuilds every pack listed in a manifest and refreshes the manifest |
| `pipeline/build-world.sh` | Builds the zoom 0–4 world overview bundled in the app |
| `pipeline/bake_tiles.py` | Walks the tile pyramid against Martin and writes MBTiles |
| `pipeline/upstream.sh` | The pinned OpenRailwayMap-vector commit that packs and style assets are built from |
| `pipeline/prepare_style.py` | Turns upstream style + legend + sprites + fonts into app assets |
| `pipeline/build-sprites.sh` | Regenerates the style assets: upstream style and legend, sprite sheets from upstream symbols plus `pipeline/symbols/` replacements |
| `pipeline/make_manifest.py` | Writes `manifest.json` listing the packs in an output dir |
| `pipeline/composed_image_golden.mjs` | Reference layouts of composed signal icons, from the website's code, for the app's tests |
| `pipeline/take_screenshots.sh`, `pipeline/take_ios_screenshots.sh`, `pipeline/make_store_assets.py` | Capture and frame the Play and App Store screenshots, draw the store icon and feature graphic |
| `fastlane/metadata/android/` | Store graphics for Google Play and F-Droid |
| `scripts/package-android-release.sh` | Packages a signed Android release (see `INSTALL.md`) |
| `INSTALL.md` | How to build the packs, the world overview and the app, and package a release |

## Building

See [INSTALL.md](INSTALL.md) for building the country packs, the world overview and the Android and
iOS apps, and for packaging an Android release.

## World overview

The app ships a small world map (zoom 0–4, about 3 MB) so it is never blank: coastlines, borders
and glaciers from Natural Earth, with continent, country, state, city and sea labels from
OpenStreetMap. Inside a downloaded country the detailed pack takes over; the app masks the pack's
region outline so the coarse world coastline never shows through.

## Map key

The Key tab explains the colours and symbols of the current view, using OpenRailwayMap's own legend
definitions (`legend.json`, prepared per view by `pipeline/prepare_style.py`). Each row is drawn by MapLibre
from sample features styled with the same layers as the map, so the key always matches it. By default
it lists only what is on screen; "Everything" lists the whole view.

## Composed signal icons

Some signal icons the style asks for are not in the sprite: stacks such as
`fi/t-270|fi/t-271-top-{1}` and positioned parts such as `it/avviso-1v|it/1v-G|it/avviso@bottom`.
The website draws them at runtime (`generateImage` in `proxy/js/ui.js`); the app ports that code.
`ComposedImage` parses the ids and lays the parts out exactly as the website does (checked against
the website's own code by `ComposedImageTest`), and `SpriteComposer` draws the normal and SDF
variants from the sprite sheet, for both the map and the key. MapLibre Native needs a missing image
before its callback returns, so at startup the app decodes, in the background, the sprite icons that
the composed icons in `legend.json` are made of; composing one then takes a few milliseconds.

## How the style switching works

The upstream style is one big MapLibre style whose layers react to `global-state` values
(`tracks`, `stations`, the lists of `signals` and `pois` categories, …). The app's views are the
website's named views (`knownStyles` in upstream's `proxy/js/ui.js`). MapLibre Native does not
evaluate `global-state`, so `StyleBuilder` substitutes the values for the selected view and options
into the expressions,
evaluates every layer's `visibility` expression to a constant and drops hidden layers before
handing the style to the map. Each installed country pack gets its own copy of the sources and
layers, so several countries can be shown at once.

## Changes to upstream

The map should look like the website, so changes to OpenRailwayMap's style and tiles are kept small,
and each is listed here. The code comments where each change is made explain why. Packs and style
assets are built from the OpenRailwayMap-vector commit pinned in `pipeline/upstream.sh`; the
committed assets must match the tiles, so after moving the pin every pack has to be rebuilt.

Tiles (`pipeline/sql/offline_tiles.sql`, `build-country.sh`, `trim_zooms.py`):

- `railway_line_high` comes from a copy of upstream's function (`railway_line_high_offline`), which
  must be kept in step with upstream's column list when the pin moves. Below zoom 10 it merges ways
  that are drawn the same into one feature per tile, and it carries each way's OSM `layer`, for the
  bridge levels below.
- `level_crossings_grouped` and `level_crossings_grouped_buffered` read the materialized table
  `level_crossings_grouped` instead of upstream's view on it, which cannot use the spatial index and
  made zooms 15 and 16 take hours on large countries. The tiles hold the same features.
- Layers that start at zoom 17 are baked into the deepest pack zoom, and every layer is baked only
  at the zooms the style draws it at.

Style (`pipeline/prepare_style.py`, at generation):

- The OpenHistoricalMap and terrain sources are dropped; tile sources point at the installed packs.
- Features MapLibre Native lacks are rewritten: `interpolate-hcl`, `icon-overlap`/`text-overlap`,
  CSS Color 4 `hsl()`, and per-feature `line-dasharray` and `text-font` (the layer is split into one
  layer per value).
- Track numbers are shown in every view, not only Infrastructure, placed under each view's line
  labels and signals so they fill the gaps between them.
- Bridges hide what passes under them: each gets a solid mask under its railing, and bridges on OSM
  `layer` 2 and up are drawn in a second pass over the lower ones, so at a crossing like Berlin
  Gleisdreieck the upper line visibly runs over the lower one.

Style (`StyleBuilder`, at runtime): `global-state` is substituted, see above, and all of a pack's
upstream sources are read from its one file.

Key (`prepare_style.py`): upstream has one legend for every map configuration, in sections that each
apply to some `global-state`; it is flattened into one key per app view, leaving only the conditions
on the user's options for the app to check. The route view is left out, and station samples get a
`localized_name`.

Symbols (`pipeline/symbols/`): the "unknown signal" icons are replaced, see `INSTALL.md`.

## License

The whole project is licensed under the **GNU General Public License v3.0 or later** (see
`LICENSE`). It is a derivative of the OpenRailwayMap vector style and pipeline, and the parts that
come from there keep their upstream copyright; `NOTICE` lists exactly which files are derived from
which project and what they contain:

- OpenRailwayMap-vector (GPL-3.0-or-later, © Hidde Wieringa; earlier styles © Michael Reichert and
  © Alexander Matheisen): the generated map style, sprite sheets and OpenRailwayMap glyphs, and the
  import/tile pipeline this project drives.
- Fira Code (SIL Open Font License 1.1): the FiraCode glyphs.
- Everything else (Android and iOS app code, basemap style, pipeline scripts) was written for this project
  and is released under the same GPL-3.0-or-later.

Map data © OpenStreetMap contributors (ODbL). Basemap tiles are produced with Planetiler
(Apache-2.0) in the OpenMapTiles schema (BSD-3-Clause schema, CC-BY 4.0 design).
