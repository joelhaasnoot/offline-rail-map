# Building Offline Rail Map

How to build the country packs, the bundled world overview and the Android app, and how to package a
release. See the [README](README.md) for what the project is and how it works.

## Country packs

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
cd pipeline/work/OpenRailwayMap-vector && node proxy/js/styles.mjs > ../style.json && cd ../../..
pipeline/build-sprites.sh                      # sprite sheets, then prepare_style.py
node pipeline/composed_image_golden.mjs        # refresh the composed icon test data
```

`build-sprites.sh` renders upstream's symbols with this project's replacements from
`pipeline/symbols/` on top. The only replacements so far are the "unknown signal" icons: a signal
whose type is not tagged in OpenStreetMap is drawn as a signal head with a question-mark badge in the
signal type's colour, instead of upstream's question-mark pentagon. Regenerate them with
`pipeline/make_unknown_signal_icons.py head-badge pipeline/work/OpenRailwayMap-vector/symbols/general pipeline/symbols/general`
(designs: `head`, `head-badge`, `lamp`).

Each pack also carries the Geofabrik region polygon (`pipeline/coverage.py`), which the app uses to
tell "no data here yet" from "this area is in a pack you haven't downloaded" and to offer that
download directly on the map.

## World overview

The zoom 0–4 world map bundled in the app is rebuilt with:

```bash
pipeline/build-world.sh
```

## Android app

```bash
cd android && ./gradlew :app:assembleDebug
```

Unit tests (pack coverage, manifest parsing, the key and composed icons):

```bash
cd android && ./gradlew :app:testDebugUnitTest
```

By default the app reads the published packs from `https://data.offlinerailmap.com/manifest.json`.
To test packs built locally, serve them with `cd pipeline/out && python3 -m http.server 8765` and
build with `-PmanifestUrl=http://10.0.2.2:8765/manifest.json` (the host machine as seen from the
Android emulator).

## Packaging a release

```bash
scripts/package-android-release.sh
```

This runs the unit tests, builds the Play bundle and an installable APK, checks both are signed and
read their packs over https, and writes `android/dist/offline-rail-map-<version>.aab` and `.apk`. It
refuses to package uncommitted changes in `android/` (override with `--allow-dirty`). Bump
`versionCode` and `versionName` in `android/app/build.gradle.kts` first.

The upload key lives in 1Password (item "Offline Rail Map Android upload key": the keystore as
`keystore`, its password and a `key alias` field); the script reads it with the `op` CLI into a
temporary folder that is removed afterwards. Point `RELEASE_1PASSWORD_ITEM` at another item if
needed, or skip 1Password with `android/keystore.properties` (gitignored) or the `RELEASE_STORE_FILE`,
`RELEASE_STORE_PASSWORD`, `RELEASE_KEY_ALIAS` and `RELEASE_KEY_PASSWORD` environment variables:

```properties
storeFile=/path/to/upload.jks
storePassword=...
keyAlias=upload
keyPassword=...
```
