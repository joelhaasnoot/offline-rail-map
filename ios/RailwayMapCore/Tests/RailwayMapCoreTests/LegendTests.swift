// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import XCTest
@testable import RailwayMapCore

final class LegendTests: XCTestCase {
    private let sep = "\u{1E}"

    private let lines = try! JSON(parsing: """
        {"id":"railway_line_high","type":"line","source":"high","source-layer":"railway_line_high","minzoom":7}
        """)
    private let lineCasing = try! JSON(parsing: """
        {"id":"railway_line_high_casing","type":"line","source":"high","source-layer":"railway_line_high","minzoom":7}
        """)
    private let signals = try! JSON(parsing: """
        {"id":"signals","type":"symbol","source":"openrailwaymap_signals","source-layer":"signals_railway_signals",
         "minzoom":13,"layout":{"icon-image":["get","feature0"],"symbol-placement":"line","icon-offset":[0,1],"text-padding":2}}
        """)

    private lazy var legendView = try! JSON(parsing: """
        {"countries":["DE"],"sourceLayers":{
          "high-railway_line_high":{"key":["usage"],"features":[
            {"legend":"Main line","type":"line","properties":{"usage":"main"},"keys":["main"]},
            {"legend":"Standard gauge","type":"line","properties":{"gauge0":"1435"},"mapState":{"trackRailwayLine":"gauge"},"keys":[""]},
            {"legend":"Siding","type":"line","minzoom":14,"properties":{"usage":"siding"},"keys":["siding"]},
            {"legend":"Ferry","type":"line","properties":{"feature":"ferry"},"keys":[]}
          ]},
          "openrailwaymap_signals-signals_railway_signals":{"key":["railway","feature0"],"matchKeys":[["railway"]],"features":[
            {"legend":"Distant signal","type":"point","country":"DE","properties":{"railway":"signal","feature0":"de/vr0"},
             "variants":[{"legend":"with repeater","properties":{"feature0":"de/vr0-repeater"}}],
             "keys":["signal\\u001ede/vr0"]}
          ]}
        }}
        """)

    private let gaugeState: [String: JSON] = ["trackRailwayLine": "gauge"]

    func testKeyPartBehavesLikeJavaScriptString() {
        XCTAssertEqual("", Legend.keyPart(nil))
        XCTAssertEqual("", Legend.keyPart(.null))
        XCTAssertEqual("true", Legend.keyPart(true))
        XCTAssertEqual("100", Legend.keyPart(100.0))
        XCTAssertEqual("1.5", Legend.keyPart(1.5))
        XCTAssertEqual("main", Legend.keyPart("main"))
    }

    func testKeyPartNormalisesPlaceholdersAndSuffixes() {
        XCTAssertEqual("at/speed-{}", Legend.keyPart("at/speed-{80}"))
        XCTAssertEqual("de/zs3-{}-{90}", Legend.keyPart("de/zs3-{80}-{90}")) // only the first placeholder, as upstream
        XCTAssertEqual("de/hp|de/ks", Legend.keyPart("de/hp@1|de/ks@2"))
    }

    func testFeatureKeysJoinKeyPartsAndAddMatchKeys() {
        let source = legendView["sourceLayers"]!["openrailwaymap_signals-signals_railway_signals"]!
        let props: [String: JSON] = ["railway": "signal", "feature0": "de/vr0"]
        XCTAssertEqual(["signal\(sep)de/vr0", "signal"], Legend.featureKeys(sourceLayer: source) { props[$0] })
    }

    func testFeatureKeysWithoutKeyPropertiesIsTheEmptyKey() {
        let source: JSON = ["key": [], "features": []]
        XCTAssertEqual([""], Legend.featureKeys(sourceLayer: source) { _ in nil })
    }

    func testEntriesFollowZoomAndMapOptions() {
        let entries = Legend.entries(legendView: legendView, layers: [lines, signals], state: gaugeState, zoom: 12, inView: nil)
        XCTAssertEqual(["Main line", "Standard gauge", "Ferry"], entries.map(\.label))

        let loadingGauge = Legend.entries(
            legendView: legendView, layers: [lines], state: ["trackRailwayLine": "loadingGauge"], zoom: 12, inView: nil
        )
        XCTAssertFalse(loadingGauge.contains { $0.label == "Standard gauge" })

        let zoomedIn = Legend.entries(legendView: legendView, layers: [lines, signals], state: gaugeState, zoom: 14, inView: nil)
        XCTAssertEqual(
            ["(DE) Distant signal, with repeater", "Main line", "Standard gauge", "Siding", "Ferry"],
            zoomedIn.map(\.label)
        )
    }

    func testSymbolsComeBeforeLines() {
        // Style order puts the lines first; the key lists the signal above them anyway.
        let entries = Legend.entries(legendView: legendView, layers: [lines, signals], state: gaugeState, zoom: 14, inView: nil)
        XCTAssertEqual("openrailwaymap_signals-signals_railway_signals", entries.first?.sourceName)
        XCTAssertEqual(["high-railway_line_high"], Set(entries.dropFirst().map(\.sourceName)))
    }

    func testLayersSharingDataAreListedOnce() {
        let entries = Legend.entries(legendView: legendView, layers: [lines, lineCasing], state: gaugeState, zoom: 12, inView: nil)
        XCTAssertEqual(3, entries.count)
    }

    func testOnScreenFilterUsesFeatureKeys() {
        let inView: [String: Set<String>] = ["high-railway_line_high": ["main"]]
        let entries = Legend.entries(legendView: legendView, layers: [lines, signals], state: gaugeState, zoom: 14, inView: inView)
        // "Ferry" lists no keys, so it matches any line on screen; "Standard gauge" needs the empty key,
        // which only features of a source layer without key properties produce.
        XCTAssertEqual(["Main line", "Ferry"], entries.map(\.label))

        let signalsOnly = Legend.entries(
            legendView: legendView, layers: [lines, signals], state: gaugeState, zoom: 14,
            inView: ["openrailwaymap_signals-signals_railway_signals": ["signal\(sep)de/vr0"]]
        )
        XCTAssertEqual(["(DE) Distant signal, with repeater"], signalsOnly.map(\.label))

        XCTAssertTrue(Legend.entries(legendView: legendView, layers: [lines, signals], state: gaugeState, zoom: 14, inView: [:]).isEmpty)
    }

    func testSamplesArePlacedInTheirRowAndVariantsShareIt() {
        let entries = Legend.entries(legendView: legendView, layers: [lines, signals], state: gaugeState, zoom: 14, inView: nil)
        let signal = entries[0]
        XCTAssertEqual(2, signal.features.count)
        let first = signal.features[0]["geometry"]!["coordinates"]!
        let second = signal.features[1]["geometry"]!["coordinates"]!
        XCTAssertEqual(0.0, first[1]!.double!, accuracy: 1e-12)
        XCTAssertEqual(Legend.degrees(-2.125), first[0]!.double!, accuracy: 1e-12)
        XCTAssertEqual(Legend.degrees(-1.375), second[0]!.double!, accuracy: 1e-12)
        XCTAssertEqual("de/vr0-repeater", signal.features[1]["properties"]?["feature0"]?.string)
        XCTAssertEqual("signal", signal.features[1]["properties"]?["railway"]?.string)

        let siding = entries[3]
        XCTAssertEqual("Siding", siding.label)
        XCTAssertEqual(1, siding.features.count)
        let geometry = siding.features[0]["geometry"]!
        XCTAssertEqual("LineString", geometry["type"]?.string)
        let coords = geometry["coordinates"]!
        let y = Legend.degrees(-3 * Legend.rowSpacing)
        XCTAssertEqual(Legend.degrees(-2.5), coords[0]![0]!.double!, accuracy: 1e-12)
        XCTAssertEqual(Legend.degrees(-1.0), coords[1]![0]!.double!, accuracy: 1e-12)
        XCTAssertEqual(y, coords[0]![1]!.double!, accuracy: 1e-12)
        XCTAssertEqual(y, Legend.rowCenter(3).lat)
        XCTAssertEqual(Legend.degrees(Legend.rowCenterX), Legend.rowCenter(3).lon)
    }

    func testLegendStyleReadsFromOneGeoJsonSourcePerDataSet() {
        let entries = Legend.entries(legendView: legendView, layers: [lines, signals], state: gaugeState, zoom: 14, inView: nil)
        let style = Legend.style(
            layers: [lines, lineCasing, signals], zoom: 14, entries: entries,
            sprite: "file:///sprites/symbols", glyphs: "file:///font/{fontstack}/{range}.pbf"
        )
        let layers = style["layers"]!.array!
        XCTAssertEqual(3, layers.count)
        let signalLayer = layers[2]
        XCTAssertEqual("openrailwaymap_signals-signals_railway_signals", signalLayer["source"]?.string)
        XCTAssertFalse(signalLayer.has("source-layer"))
        XCTAssertFalse(signalLayer.has("minzoom"))
        let layout = signalLayer["layout"]!
        XCTAssertEqual("line-center", layout["symbol-placement"]?.string)
        XCTAssertFalse(layout.has("icon-offset"))
        XCTAssertFalse(layout.has("text-padding"))

        let sources = style["sources"]!.object!
        XCTAssertEqual(2, sources.count)
        XCTAssertEqual(4, sources["high-railway_line_high"]?["data"]?["features"]?.array?.count)
        XCTAssertEqual(2, sources["openrailwaymap_signals-signals_railway_signals"]?["data"]?["features"]?.array?.count)
    }

    func testLegendStyleSkipsLayersHiddenAtTheZoom() {
        let style = Legend.style(layers: [lines, signals], zoom: 10, entries: [], sprite: "s", glyphs: "g")
        XCTAssertEqual(1, style["layers"]?.array?.count)
        XCTAssertEqual(1, style["sources"]?.object?.count)
    }

    func testRowSizeInPoints() {
        XCTAssertEqual(77.4, Legend.unitsToPoints(Legend.rowWidthUnits), accuracy: 0.1)
        XCTAssertEqual(54.6, Legend.unitsToPoints(Legend.rowHeightUnits), accuracy: 0.1)
    }
}
