// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation
import os

/**
 The generated map assets shared with the Android app (`android/app/src/main/assets`): styles,
 legend, sprites, glyphs and the world overview. The styles refer to sprites and glyphs with
 Android `asset://` URLs; on iOS those are resolved to files under `root`.
 */
public struct MapAssets: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var ormStyle: URL {
        root.appendingPathComponent("style/orm-style.json")
    }

    public var basemapStyle: URL {
        root.appendingPathComponent("style/basemap-style.json")
    }

    public var legend: URL {
        root.appendingPathComponent("style/legend.json")
    }

    /// The bundled world overview; nil when it is missing from the build.
    public var worldFile: URL? {
        let file = root.appendingPathComponent("world/world.pmtiles")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// `asset://sprites/symbols` -> `file:///…/assets/sprites/symbols`; other URLs are returned unchanged.
    public func resolve(_ url: String) -> String {
        let scheme = "asset://"
        guard url.hasPrefix(scheme) else {
            return url
        }
        var base = root.absoluteString
        if !base.hasSuffix("/") {
            base += "/"
        }
        return base + url.dropFirst(scheme.count)
    }
}

/**
 Builds the MapLibre style JSON shown on the map.

 The upstream OpenRailwayMap style is a single style that switches between "Infrastructure",
 "Speed", ... via `global-state` expressions. MapLibre Native does not evaluate those, so we
 substitute the chosen state values into the expressions ourselves, evaluate each layer's
 `visibility` expression to a constant and drop hidden layers.

 Every installed country pack gets its own copy of the sources and layers, pointing at the
 PMTiles files on disk. Underneath sits a low-zoom world overview bundled with the app (see
 `WorldLayers`). Thread-safe; building is meant to run off the main thread.
 */
public final class StyleBuilder: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.offlinerailmap.ios", category: "StyleBuilder")

    public let assets: MapAssets
    private let lock = NSLock()
    private var loaded: (orm: JSON, basemap: JSON)?
    private var legendData: JSON?
    private var ormLayersCache: (key: OrmKey, value: OrmLayers)?

    private struct OrmKey: Equatable {
        let mode: MapMode
        let options: MapOptions
        let year: Int
    }

    public init(assets: MapAssets) {
        self.assets = assets
    }

    private func load() throws -> (orm: JSON, basemap: JSON) {
        lock.lock()
        defer { lock.unlock() }
        if let loaded {
            return loaded
        }
        let result = (orm: try JSON(contentsOf: assets.ormStyle), basemap: try JSON(contentsOf: assets.basemapStyle))
        loaded = result
        return result
    }

    /// The legend.json object for a view (`{countries, sourceLayers}`).
    public func legendView(modeId: String) throws -> JSON {
        lock.lock()
        defer { lock.unlock() }
        if legendData == nil {
            legendData = try JSON(contentsOf: assets.legend)
        }
        return legendData?[modeId] ?? [:]
    }

    public func build(mode: MapMode, options: MapOptions, packs: [InstalledPack]) throws -> String {
        let (orm, base) = try load()

        var sources: [String: JSON] = [:]
        var layers: [JSON] = []

        // --- Basemap ---
        // Order: background, world overview, mask over downloaded regions, detailed pack basemaps.
        let baseLayers = base["layers"]?.array ?? []
        let backgroundColor = baseLayers.first { $0["type"]?.string == "background" }?["paint"]?["background-color"]?.string
            .flatMap { $0.isEmpty ? nil : $0 } ?? "#f4f1ec"
        layers.append(contentsOf: baseLayers.filter { !$0.has("source") })

        var worldLayers: [JSON] = []
        if let world = assets.worldFile {
            sources[WorldLayers.source] = WorldLayers.source(pmtilesUrl: Self.pmtilesUrl(world))
            worldLayers = baseLayers.filter { $0.has("source") }.compactMap(WorldLayers.worldCopy)
        }
        let worldLabels = worldLayers.filter { $0["type"]?.string == "symbol" }
        layers.append(contentsOf: worldLayers.filter { $0["type"]?.string != "symbol" })

        let basemapPacks = packs.filter { $0.basemapFile != nil }
        let mask = WorldLayers.maskGeometry(basemapPacks.map(\.info))
        if let mask {
            sources[WorldLayers.maskSource] = WorldLayers.maskSource(mask)
            layers.append(WorldLayers.maskLayer(color: backgroundColor))
        }

        let basemapSource = base["sources"]?["basemap"] ?? [:]
        for pack in basemapPacks {
            var source = basemapSource
            source["url"] = .string(Self.pmtilesUrl(pack.basemapFile!))
            sources["basemap__\(pack.info.id)"] = source
        }
        for layer in baseLayers where layer.has("source") {
            let id = layer["id"]?.string ?? ""
            for pack in basemapPacks {
                var copy = layer
                copy["id"] = .string("\(id)__\(pack.info.id)")
                copy["source"] = .string("basemap__\(pack.info.id)")
                if id == "place-country", let field = copy["layout"]?["text-field"] {
                    // Match the English country names of the world overview next door.
                    copy["layout"]?["text-field"] = WorldLayers.preferEnglish(field)
                }
                layers.append(copy)
            }
        }
        for label in worldLabels {
            layers.append(mask.map { WorldLayers.hideInsideMask(label, geometry: $0) } ?? label)
        }

        // --- OpenRailwayMap ---
        let ormSources = orm["sources"]?.object ?? [:]
        for pack in packs {
            for (name, source) in ormSources where source["type"]?.string == "vector" {
                var copy = source
                copy["url"] = .string(Self.pmtilesUrl(pack.railwayFile))
                sources["\(name)__\(pack.info.id)"] = copy
            }
        }
        let processed = try ormLayers(mode: mode, options: options)
        for layer in processed.layers {
            let id = layer["id"]?.string ?? ""
            let source = layer["source"]?.string ?? ""
            for pack in packs {
                var copy = layer
                copy["id"] = .string("\(id)__\(pack.info.id)")
                copy["source"] = .string("\(source)__\(pack.info.id)")
                layers.append(copy)
            }
        }

        let style: JSON = [
            "version": 8,
            "name": .string("OpenRailwayMap offline · \(mode.label)"),
            "sprite": .string(processed.sprite),
            "glyphs": .string(processed.glyphs),
            "sources": .object(sources),
            "layers": .array(layers),
        ]
        Self.log.info("built style '\(mode.id)' for \(packs.count) pack(s): \(layers.count) layers, \(processed.hidden) upstream layers hidden")
        return style.serialized()
    }

    /// The upstream layers that are visible for a view and options, with `global-state` resolved.
    public struct OrmLayers: Sendable {
        public let layers: [JSON]
        public let hidden: Int
        /// Layers whose visibility did not reduce to a constant and are shown regardless.
        public let unresolved: Int
        public let state: [String: JSON]
        public let sprite: String
        public let glyphs: String
    }

    public func ormLayers(mode: MapMode, options: MapOptions) throws -> OrmLayers {
        let year = Calendar.current.component(.year, from: Date())
        let key = OrmKey(mode: mode, options: options, year: year)
        lock.lock()
        if let cache = ormLayersCache, cache.key == key {
            lock.unlock()
            return cache.value
        }
        lock.unlock()

        let (orm, _) = try load()
        let state = Self.globalState(orm: orm, mode: mode, options: options, year: year)
        let vectorSources = Set((orm["sources"]?.object ?? [:]).filter { $0.value["type"]?.string == "vector" }.keys)
        var result: [JSON] = []
        var hidden = 0
        var unresolved = 0
        for layer in orm["layers"]?.array ?? [] {
            guard let source = layer["source"]?.string, vectorSources.contains(source) else {
                continue
            }
            var substituted = Self.simplify(Self.substitute(layer, state: state))
            let visibility = substituted["layout"]?["visibility"]
            if case .array = visibility {
                Self.log.warning("visibility of \(layer["id"]?.string ?? "?") did not reduce to a constant")
                substituted["layout"]?["visibility"] = "visible"
                unresolved += 1
            }
            if substituted["layout"]?["visibility"]?.string == "none" {
                hidden += 1
                continue
            }
            // Filters that reduced to a constant: drop the layer or drop the filter.
            if case .bool(let keep) = substituted["filter"] {
                if !keep {
                    hidden += 1
                    continue
                }
                substituted.remove("filter")
            }
            result.append(substituted)
        }
        let value = OrmLayers(
            layers: result,
            hidden: hidden,
            unresolved: unresolved,
            state: state,
            sprite: assets.resolve(orm["sprite"]?.string ?? ""),
            glyphs: assets.resolve(orm["glyphs"]?.string ?? "")
        )
        lock.lock()
        ormLayersCache = (key, value)
        lock.unlock()
        return value
    }

    static func pmtilesUrl(_ file: URL) -> String {
        "pmtiles://file://" + file.path
    }

    static func globalState(orm: JSON, mode: MapMode, options: MapOptions, year: Int) -> [String: JSON] {
        var state: [String: JSON] = [:]
        for (key, definition) in orm["state"]?.object ?? [:] {
            state[key] = definition["default"] ?? .null
        }
        state["style"] = .string(mode.id)
        state.merge(mode.globalState) { _, new in new }
        state.merge(options.toGlobalState()) { _, new in new }
        state["theme"] = "light"
        state["pitched"] = false
        state["bearing"] = 0
        state["hillshade"] = false
        state["openHistoricalMap"] = false
        state["date"] = .number(Double(year))
        state["allDates"] = false
        return state
    }

    /// Replaces every `["global-state", key]` with the value of that key.
    static func substitute(_ value: JSON, state: [String: JSON]) -> JSON {
        switch value {
        case .array(let items):
            if items.count == 2, items[0] == "global-state" {
                return items[1].string.flatMap { state[$0] } ?? .null
            }
            return .array(items.map { substitute($0, state: state) })
        case .object(let values):
            return .object(values.mapValues { substitute($0, state: state) })
        default:
            return value
        }
    }

    /**
     Constant-folds sub-expressions whose operands are all constants (after `global-state`
     substitution), so that e.g. `["==", "usage", "usage"]` becomes `true` and `["all", ...]`,
     `["any", ...]` and `["case", ...]` collapse. Besides shrinking the style, this is required
     because MapLibre Native parses a filter such as `["==", "a", "b"]` as a *legacy* filter
     (property "a" equals "b") and rejects `["==", true, false]` outright.
     */
    static func simplify(_ value: JSON) -> JSON {
        if case .object(let values) = value {
            return .object(values.mapValues(simplify))
        }
        guard case .array(let items) = value, let op = items.first?.string else {
            return value
        }
        if op == "literal" {
            return value
        }
        let args = items.dropFirst().map(simplify)
        let rebuilt = JSON.array([.string(op)] + args)
        switch op {
        case "all":
            var remaining: [JSON] = []
            for arg in args {
                if arg == false {
                    return false
                }
                if arg != true {
                    remaining.append(arg)
                }
            }
            switch remaining.count {
            case 0:
                return true
            case 1:
                return remaining[0]
            default:
                return .array(["all"] + remaining)
            }
        case "any":
            var remaining: [JSON] = []
            for arg in args {
                if arg == true {
                    return true
                }
                if arg != false {
                    remaining.append(arg)
                }
            }
            switch remaining.count {
            case 0:
                return false
            case 1:
                return remaining[0]
            default:
                return .array(["any"] + remaining)
            }
        case "case":
            var kept: [JSON] = []
            var i = 0
            while i + 1 < args.count {
                let condition = args[i]
                if condition == true {
                    return kept.isEmpty ? args[i + 1] : .array(["case"] + kept + [args[i + 1]])
                }
                if condition != false && condition != .null {
                    kept.append(condition)
                    kept.append(args[i + 1])
                }
                i += 2
            }
            let fallback = args.last ?? .null
            return kept.isEmpty ? fallback : .array(["case"] + kept + [fallback])
        case "!":
            if case .bool(let b)? = args.first {
                return .bool(!b)
            }
            return rebuilt
        case "==", "!=", "<", "<=", ">", ">=", "in", "match", "coalesce":
            let allConstant = args.enumerated().allSatisfy { index, arg in
                // The label lists of a match (every other argument before the fallback) are data, not expressions.
                if op == "match" && index % 2 == 1 && index < args.count - 1 {
                    return true
                }
                guard case .array(let inner) = arg else {
                    return true
                }
                return inner.first == "literal"
            }
            if allConstant, let result = try? evaluate(rebuilt) {
                return result
            }
            return rebuilt
        default:
            return rebuilt
        }
    }

    // MARK: - A very small expression evaluator, enough for the upstream `visibility` expressions

    struct UnsupportedExpression: Error {}

    static func evaluate(_ e: JSON) throws -> JSON {
        guard case .array(let items) = e, let op = items.first?.string else {
            return e
        }
        func arg(_ index: Int) throws -> JSON {
            try evaluate(index < items.count ? items[index] : .null)
        }
        switch op {
        case "literal":
            return items.count > 1 ? items[1] : .null
        case "case":
            var i = 1
            while i + 1 < items.count {
                if truthy(try arg(i)) {
                    return try arg(i + 1)
                }
                i += 2
            }
            return try arg(items.count - 1)
        case "all":
            for i in 1..<items.count where !truthy(try arg(i)) {
                return false
            }
            return true
        case "any":
            for i in 1..<items.count where truthy(try arg(i)) {
                return true
            }
            return false
        case "!":
            return .bool(!truthy(try arg(1)))
        case "==":
            return .bool(try arg(1) == arg(2))
        case "!=":
            return .bool(try arg(1) != arg(2))
        case "<":
            return .bool(try compare(arg(1), arg(2)) < 0)
        case "<=":
            return .bool(try compare(arg(1), arg(2)) <= 0)
        case ">":
            return .bool(try compare(arg(1), arg(2)) > 0)
        case ">=":
            return .bool(try compare(arg(1), arg(2)) >= 0)
        case "in":
            let needle = try arg(1)
            switch try arg(2) {
            case .array(let haystack):
                return .bool(haystack.contains(needle))
            case .string(let haystack):
                if case .string(let text) = needle {
                    return .bool(haystack.contains(text))
                }
                return false
            default:
                return false
            }
        case "match":
            let input = try arg(1)
            var i = 2
            while i + 1 < items.count - 1 {
                let labels = items[i]
                let matched: Bool
                if case .array(let options) = labels {
                    matched = options.contains(input)
                } else {
                    matched = labels == input
                }
                if matched {
                    return try arg(i + 1)
                }
                i += 2
            }
            return try arg(items.count - 1)
        case "coalesce":
            for i in 1..<items.count {
                let value = try arg(i)
                if value != .null {
                    return value
                }
            }
            return .null
        default:
            throw UnsupportedExpression()
        }
    }

    private static func truthy(_ value: JSON) -> Bool {
        switch value {
        case .null:
            return false
        case .bool(let b):
            return b
        case .number(let n):
            return n != 0
        case .string(let s):
            return !s.isEmpty
        default:
            return true
        }
    }

    private static func compare(_ a: JSON, _ b: JSON) throws -> Int {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            return x < y ? -1 : (x > y ? 1 : 0)
        case (.string(let x), .string(let y)):
            return x < y ? -1 : (x > y ? 1 : 0)
        default:
            throw UnsupportedExpression()
        }
    }
}
