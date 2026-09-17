// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation

/**
 The map key, ported from the OpenRailwayMap web legend (`legend.json` + `makeLegendStyle`).

 Every entry is drawn by MapLibre itself: sample lines and points carrying the entry's feature
 properties are placed in rows on an empty "legend map" and styled with the very layers the map
 uses, so colours, dashes and symbols always match. Rows are `rowSpacing` map units apart and
 rendered one at a time by the snapshotter; the app shows the text next to them.
 */
public enum Legend {
    /// Zoom the legend map is rendered at, as on the website.
    public static let renderZoom = 16.0

    /// Distance between row centres, in legend units. Wide enough that rows never bleed into each other.
    public static let rowSpacing = 2.0

    /// Size of one rendered row in legend units: the sample area itself is 1.5 units wide.
    public static let rowWidthUnits = 1.7
    public static let rowHeightUnits = 1.2

    private static let sampleStart = -2.5
    private static let sampleWidth = 1.5
    public static let rowCenterX = sampleStart + sampleWidth / 2

    private static let minZoom = 1.0
    private static let maxZoom = 20.0

    /// Separator the website uses between the parts of a feature key.
    private static let keySeparator = "\u{1E}"

    /// Legend units to degrees, as on the website.
    public static func degrees(_ units: Double) -> Double {
        units * pow(2, -11)
    }

    /// Row centre as (latitude, longitude).
    public static func rowCenter(_ row: Int) -> (lat: Double, lon: Double) {
        (degrees(-Double(row) * rowSpacing), degrees(rowCenterX))
    }

    /// Legend units at the render zoom in points (MapLibre uses 512 point tiles).
    public static func unitsToPoints(_ units: Double) -> Double {
        degrees(units) * 512 * pow(2, renderZoom) / 360
    }

    public struct Entry: Hashable, Sendable {
        public let label: String
        public let sourceName: String
        /// GeoJSON features with geometry already placed in this entry's row.
        public let features: [JSON]
    }

    /// `source-sourceLayer`, the name legend.json uses for a style layer's data.
    public static func sourceName(_ layer: JSON) -> String {
        "\(layer["source"]?.string ?? "")-\(layer["source-layer"]?.string ?? "")"
    }

    public static func visibleAtZoom(_ layer: JSON, _ zoom: Int) -> Bool {
        (layer["minzoom"]?.double ?? minZoom) <= Double(zoom) && Double(zoom) < (layer["maxzoom"]?.double ?? maxZoom + 1)
    }

    /**
     The key entries for the layers visible at `zoom`: symbols (points and areas) first, then lines,
     each group in style order. Symbols come first because the on-screen filter can tell them apart,
     while many line entries share one key and are listed whenever any line is on screen.

     - Parameters:
       - legendView: the legend.json object for the current view (`{countries, sourceLayers}`)
       - state: resolved global state (map options), for entries that depend on them
       - inView: source name to feature keys found on screen; nil lists every entry
     */
    public static func entries(
        legendView: JSON,
        layers: [JSON],
        state: [String: JSON],
        zoom: Int,
        inView: [String: Set<String>]?
    ) -> [Entry] {
        let sourceLayers = legendView["sourceLayers"] ?? [:]
        var done = Set<String>()
        var symbols: [(item: JSON, sourceName: String)] = []
        var lines: [(item: JSON, sourceName: String)] = []
        for layer in layers {
            let name = sourceName(layer)
            if done.contains(name) || !visibleAtZoom(layer, zoom) {
                continue
            }
            done.insert(name)
            guard let items = sourceLayers[name]?["features"]?.array else {
                continue
            }
            for item in items {
                if !visibleAtZoom(item, zoom) || !stateMatches(item, state) || !inViewMatches(item, name, inView) {
                    continue
                }
                if item["type"]?.string == "line" {
                    lines.append((item, name))
                } else {
                    symbols.append((item, name))
                }
            }
        }
        // Rows are numbered in display order: the sample geometry of each entry sits in its own row.
        return (symbols + lines).enumerated().map { row, entry in
            let variants = expandVariants(entry.item).filter { stateMatches($0, state) }
            let features = variants.enumerated().map { index, variant in
                placeFeature(variant, index: index, count: variants.count, row: row)
            }
            return Entry(label: label(entry.item, state), sourceName: entry.sourceName, features: features)
        }
    }

    private static func stateMatches(_ item: JSON, _ state: [String: JSON]) -> Bool {
        guard let required = item["mapState"]?.object else {
            return true
        }
        return required.allSatisfy { key, value in (state[key] ?? .null) == value }
    }

    private static func inViewMatches(_ item: JSON, _ sourceName: String, _ inView: [String: Set<String>]?) -> Bool {
        guard let inView else {
            return true
        }
        guard let found = inView[sourceName] else {
            return false
        }
        guard let keys = item["keys"]?.array, !keys.isEmpty else {
            return true
        }
        return keys.contains { key in key.string.map(found.contains) ?? false }
    }

    /// The item itself followed by its variants, each variant inheriting and overriding the item.
    private static func expandVariants(_ item: JSON) -> [JSON] {
        var out = [item]
        for variant in item["variants"]?.array ?? [] {
            var merged = item
            merged.remove("variants")
            for (key, value) in variant.object ?? [:] where key != "properties" {
                merged[key] = value
            }
            var properties = item["properties"]?.object ?? [:]
            for (key, value) in variant["properties"]?.object ?? [:] {
                properties[key] = value
            }
            merged["properties"] = .object(properties)
            out.append(merged)
        }
        return out
    }

    private static func label(_ item: JSON, _ state: [String: JSON]) -> String {
        let base = item["legend"]?.string ?? ""
        let prefixed = item["country"]?.string.map { "(\($0)) \(base)" } ?? base
        guard let variants = item["variants"]?.array else {
            return prefixed
        }
        let extra = variants
            .filter { $0.has("legend") && stateMatches($0, state) }
            .compactMap { $0["legend"]?.string }
        return ([prefixed] + extra).joined(separator: ", ")
    }

    private static func point(_ x: Double, _ y: Double) -> JSON {
        .array([.number(degrees(x)), .number(degrees(y))])
    }

    /// Sample geometry for variant `index` of `count` in row `row`: lines split the row, points share it.
    private static func placeFeature(_ item: JSON, index: Int, count: Int, row: Int) -> JSON {
        let y = -Double(row) * rowSpacing
        let left = sampleStart + Double(index) / Double(count) * sampleWidth
        let right = sampleStart + Double(index + 1) / Double(count) * sampleWidth
        let middle = (left + right) / 2
        let geometry: JSON
        switch item["type"]?.string {
        case "line":
            geometry = ["type": "LineString", "coordinates": [point(left, y), point(right, y)]]
        case "polygon":
            let ring = (0...20).map { i -> JSON in
                let phi = Double(i) * 2 * Double.pi / 20
                return point(cos(phi) * 0.1 + middle, sin(phi) * 0.1 + y)
            }
            geometry = ["type": "LineString", "coordinates": .array(ring)]
        default:
            geometry = ["type": "Point", "coordinates": point(middle, y)]
        }
        return ["type": "Feature", "geometry": geometry, "properties": item["properties"] ?? [:]]
    }

    /**
     The style that draws `entries`: the visible layers at `zoom`, each reading from a GeoJSON source
     named after its data (`source-sourceLayer`), adapted as the website does for its legend map.
     */
    public static func style(layers: [JSON], zoom: Int, entries: [Entry], sprite: String, glyphs: String) -> JSON {
        var styleLayers: [JSON] = []
        var sourceNames: [String] = []
        for layer in layers where visibleAtZoom(layer, zoom) {
            var copy = layer
            let name = sourceName(layer)
            copy.remove("source-layer")
            copy.remove("minzoom")
            copy.remove("maxzoom")
            copy["source"] = .string(name)
            if var layout = copy["layout"] {
                for key in ["text-padding", "text-offset", "symbol-spacing", "icon-offset"] {
                    layout.remove(key)
                }
                if layout["symbol-placement"]?.string == "line" {
                    layout["symbol-placement"] = "line-center"
                }
                copy["layout"] = layout
            }
            styleLayers.append(copy)
            if !sourceNames.contains(name) {
                sourceNames.append(name)
            }
        }
        var sources: [String: JSON] = [:]
        for name in sourceNames {
            let features = entries.filter { $0.sourceName == name }.flatMap(\.features)
            sources[name] = ["type": "geojson", "data": ["type": "FeatureCollection", "features": .array(features)]]
        }
        return [
            "version": 8,
            "name": "legend",
            "sprite": .string(sprite),
            "glyphs": .string(glyphs),
            "sources": .object(sources),
            "layers": .array(styleLayers),
        ]
    }

    /**
     The keys of a feature seen on the map, computed as on the website: the values of the source
     layer's `key` properties (and of each `matchKeys` list) joined with U+001E.
     */
    public static func featureKeys(sourceLayer: JSON, property: (String) -> JSON?) -> Set<String> {
        func keyOf(_ parts: [JSON]) -> String {
            parts.map { keyPart(property($0.string ?? "")) }.joined(separator: keySeparator)
        }
        var keys: Set<String> = [keyOf(sourceLayer["key"]?.array ?? [])]
        for match in sourceLayer["matchKeys"]?.array ?? [] {
            keys.insert(keyOf(match.array ?? []))
        }
        return keys
    }

    /// JavaScript `String(value ?? '')`, with `{...}` placeholders and `@...` suffixes normalised.
    public static func keyPart(_ value: JSON?) -> String {
        var text: String
        switch value {
        case nil, .null?:
            text = ""
        case .bool(let b)?:
            text = b ? "true" : "false"
        case .number(let n)?:
            text = n.isFinite && n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s)?:
            text = s
        case let other?:
            text = other.serialized()
        }
        if let range = text.firstRange(of: #/\{[^}]+\}/#) {
            text.replaceSubrange(range, with: "{}")
        }
        return text.replacing(#/@([^|]+|$)/#, with: "")
    }
}
