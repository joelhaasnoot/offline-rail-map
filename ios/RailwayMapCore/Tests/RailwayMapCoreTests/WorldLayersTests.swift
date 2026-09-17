// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import XCTest
@testable import RailwayMapCore

final class WorldLayersTests: XCTestCase {
    private func layer(_ json: String) -> JSON {
        try! JSON(parsing: json)
    }

    func testWorldCopyReadsFromWorldSourceAndIsCapped() {
        let water = layer(#"{"id":"water","type":"fill","source":"basemap","source-layer":"water"}"#)
        let copy = WorldLayers.worldCopy(water)!
        XCTAssertEqual("water__world", copy["id"]?.string)
        XCTAssertEqual("world", copy["source"]?.string)
        XCTAssertEqual(WorldLayers.maxVisibleZoom, copy["maxzoom"]?.double)
        XCTAssertEqual("basemap", water["source"]?.string) // original untouched
    }

    func testWorldCopyKeepsALowerMaxzoom() {
        let country = layer(#"{"id":"place-country","type":"symbol","source":"basemap","maxzoom":8}"#)
        XCTAssertEqual(8.0, WorldLayers.worldCopy(country)?["maxzoom"]?.double)
    }

    func testLayersThatOnlyAppearWhenZoomedInAreSkipped() {
        let roadNames = layer(#"{"id":"road-name","type":"symbol","source":"basemap","minzoom":14}"#)
        XCTAssertNil(WorldLayers.worldCopy(roadNames))
    }

    func testLabelsPreferEnglishNames() {
        let city = layer(#"{"id":"place-city","type":"symbol","source":"basemap","layout":{"text-field":["get","name"]}}"#)
        let field = WorldLayers.worldCopy(city)?["layout"]?["text-field"]
        XCTAssertEqual(#"["coalesce",["get","name:en"],["get","name"]]"#, field?.serialized())
    }

    func testPreferEnglishReachesNestedExpressionsAndLeavesOthersAlone() {
        let expr = layer(#"["concat",["get","name"]," ",["get","ref"]]"#)
        XCTAssertEqual(
            #"["concat",["coalesce",["get","name:en"],["get","name"]]," ",["get","ref"]]"#,
            WorldLayers.preferEnglish(expr).serialized()
        )
        XCTAssertEqual("North America", WorldLayers.preferEnglish("North America"))
    }

    func testNoMaskWithoutPacks() {
        XCTAssertNil(WorldLayers.maskGeometry([]))
    }

    func testMaskUsesEveryRingAndClosesThem() {
        let mask = WorldLayers.maskGeometry([TestPacks.netherlands, TestPacks.benelux])!
        XCTAssertEqual("MultiPolygon", mask["type"]?.string)
        let polygons = mask["coordinates"]!.array!
        XCTAssertEqual(4, polygons.count) // Netherlands + Benelux (Netherlands, Belgium, Luxembourg)
        for polygon in polygons {
            let ring = polygon[0]!.array!
            XCTAssertEqual(ring.first, ring.last)
        }
        XCTAssertEqual("Feature", WorldLayers.maskSource(mask)["data"]?["type"]?.string)
    }

    func testMaskFallsBackToTheBoundingBox() {
        var pack = TestPacks.netherlands
        pack.coverage = []
        let ring = WorldLayers.maskGeometry([pack])!["coordinates"]![0]![0]!
        XCTAssertEqual(5, ring.array?.count)
        XCTAssertTrue(ring.serialized().contains("[3.3,50.75]"))
        XCTAssertTrue(ring.serialized().contains("[7.2,53.5]"))
    }

    func testWorldLabelsAreHiddenInsideDownloadedRegions() {
        let mask = WorldLayers.maskGeometry([TestPacks.netherlands])!
        let city = layer(#"{"id":"place-city__world","type":"symbol","source-layer":"place","filter":["==",["get","class"],"city"]}"#)
        let filter = WorldLayers.hideInsideMask(city, geometry: mask)["filter"]!
        XCTAssertEqual("all", filter[0]?.string)
        XCTAssertEqual(#"["==",["get","class"],"city"]"#, filter[1]?.serialized())
        XCTAssertEqual("!", filter[2]?[0]?.string)
        XCTAssertEqual("within", filter[2]?[1]?[0]?.string)

        let noFilter = layer(#"{"id":"water-name__world","type":"symbol","source-layer":"water_name"}"#)
        XCTAssertEqual("!", WorldLayers.hideInsideMask(noFilter, geometry: mask)["filter"]?[0]?.string)
    }

    func testContinentLabelsStayVisibleEverywhere() {
        let mask = WorldLayers.maskGeometry([TestPacks.netherlands])!
        let continent = layer(#"{"id":"place-continent__world","type":"symbol","source-layer":"place"}"#)
        XCTAssertFalse(WorldLayers.hideInsideMask(continent, geometry: mask).has("filter"))
    }
}
