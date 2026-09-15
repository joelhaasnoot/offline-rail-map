// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import XCTest
@testable import RailwayMapCore

final class StyleBuilderTests: XCTestCase {
    /// The generated assets shared with the Android app.
    static let assets = MapAssets(
        root: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RailwayMapCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // RailwayMapCore
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/assets", isDirectory: true)
    )

    private let state: [String: JSON] = ["tracks": "usage", "signals": "none", "showRazed": false]

    func testGlobalStateIsSubstituted() {
        let expr: JSON = ["case", ["==", ["global-state", "tracks"], "usage"], "visible", "none"]
        XCTAssertEqual(
            ["case", ["==", "usage", "usage"], "visible", "none"],
            StyleBuilder.substitute(expr, state: state)
        )
        XCTAssertEqual(.null, StyleBuilder.substitute(["global-state", "unknown"], state: state))
    }

    func testVisibilityFoldsToAConstant() {
        let visible = StyleBuilder.simplify(StyleBuilder.substitute(
            ["case", ["==", ["global-state", "tracks"], "usage"], "visible", "none"], state: state
        ))
        XCTAssertEqual("visible", visible)
        let hidden = StyleBuilder.simplify(StyleBuilder.substitute(
            ["match", ["global-state", "signals"], ["speed", "signals"], "visible", "none"], state: state
        ))
        XCTAssertEqual("none", hidden)
    }

    func testFiltersKeepFeatureExpressions() {
        let filter = StyleBuilder.simplify(StyleBuilder.substitute(
            ["all", ["!", ["global-state", "showRazed"]], ["==", ["get", "state"], "present"]], state: state
        ))
        XCTAssertEqual(["==", ["get", "state"], "present"], filter)
        XCTAssertEqual(false, StyleBuilder.simplify(["any", false, ["==", 1, 2]]))
        XCTAssertEqual(
            ["case", ["has", "name"], ["get", "name"], "fallback"],
            StyleBuilder.simplify(["case", false, "never", ["has", "name"], ["get", "name"], "fallback"])
        )
        XCTAssertEqual(true, StyleBuilder.simplify(["in", "b", ["literal", ["a", "b"]]]))
        XCTAssertEqual(["<", ["zoom"], 3], StyleBuilder.simplify(["<", ["zoom"], 3]))
    }

    func testAssetUrlsResolveToFiles() {
        let assets = MapAssets(root: URL(fileURLWithPath: "/app/assets", isDirectory: true))
        XCTAssertEqual("file:///app/assets/sprites/symbols", assets.resolve("asset://sprites/symbols"))
        XCTAssertEqual("https://example.com/x", assets.resolve("https://example.com/x"))
    }

    func testBuildsEveryViewFromTheRealStyle() throws {
        let builder = StyleBuilder(assets: Self.assets)
        let pack = TestPacks.installed(TestPacks.netherlands)
        for mode in MapMode.allCases {
            let text = try builder.build(mode: mode, options: MapOptions(), packs: [pack])
            XCTAssertFalse(text.contains("global-state"), "\(mode) still has global-state")
            let style = try JSON(parsing: text)
            let layers = style["layers"]!.array!
            let ormLayers = layers.filter { ($0["id"]?.string ?? "").hasSuffix("__netherlands") }
            XCTAssertFalse(ormLayers.isEmpty, "\(mode) has no railway layers")
            for layer in ormLayers {
                XCTAssertNotEqual("none", layer["layout"]?["visibility"]?.string)
                if case .bool = layer["filter"] {
                    XCTFail("\(layer["id"]!) kept a constant filter")
                }
                let source = layer["source"]!.string!
                XCTAssertEqual(
                    "pmtiles://file://" + pack.railwayFile.path,
                    style["sources"]?[source]?["url"]?.string,
                    "\(source) of \(mode)"
                )
            }
            XCTAssertTrue(style["sprite"]!.string!.hasPrefix("file:///"))
            XCTAssertTrue(style["glyphs"]!.string!.hasSuffix("font/{fontstack}/{range}.pbf"))
            XCTAssertNotNil(style["sources"]?[WorldLayers.source], "\(mode) has no world overview")
        }
    }

    func testViewsShowDifferentLayers() throws {
        let builder = StyleBuilder(assets: Self.assets)
        for mode in MapMode.allCases {
            XCTAssertEqual(0, try builder.ormLayers(mode: mode, options: MapOptions()).unresolved, "\(mode)")
        }
        let standard = Set(try builder.ormLayers(mode: .standard, options: MapOptions()).layers.compactMap { $0["id"]?.string })
        let speed = Set(try builder.ormLayers(mode: .speed, options: MapOptions()).layers.compactMap { $0["id"]?.string })
        XCTAssertNotEqual(standard, speed)
        XCTAssertTrue(try builder.ormLayers(mode: .speed, options: MapOptions()).hidden > 0)
        XCTAssertEqual("speed", try builder.ormLayers(mode: .speed, options: MapOptions()).state["style"])
    }

    func testBasemapPacksGetTheWorldMask() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("style-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("basemap.pmtiles").path, contents: Data())
        let pack = InstalledPack(info: TestPacks.netherlands, dir: dir)
        XCTAssertNotNil(pack.basemapFile)

        let style = try JSON(parsing: StyleBuilder(assets: Self.assets).build(mode: .standard, options: MapOptions(), packs: [pack]))
        let ids = style["layers"]!.array!.compactMap { $0["id"]?.string }
        let mask = try XCTUnwrap(ids.firstIndex(of: WorldLayers.maskLayerId))
        let firstPackBasemap = try XCTUnwrap(ids.firstIndex { $0.hasSuffix("__netherlands") })
        XCTAssertLessThan(mask, firstPackBasemap)
        XCTAssertNotNil(style["sources"]?["basemap__netherlands"])
    }

    func testLegendDataLoads() throws {
        let builder = StyleBuilder(assets: Self.assets)
        let view = try builder.legendView(modeId: "standard")
        XCTAssertNotNil(view["sourceLayers"]?.object)
        let orm = try builder.ormLayers(mode: .standard, options: MapOptions())
        let entries = Legend.entries(legendView: view, layers: orm.layers, state: orm.state, zoom: 14, inView: nil)
        XCTAssertFalse(entries.isEmpty)
    }
}
