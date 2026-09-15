// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import XCTest
@testable import RailwayMapCore

final class PackInfoTests: XCTestCase {
    func testContainsUsesTheRegionPolygonNotTheBoundingBox() {
        let nl = TestPacks.netherlands
        XCTAssertTrue(nl.contains(lat: TestPacks.amsterdam.lat, lon: TestPacks.amsterdam.lon))
        XCTAssertTrue(nl.contains(lat: TestPacks.maastricht.lat, lon: TestPacks.maastricht.lon))
        // Brussels lies inside the Netherlands bounding box but outside its polygon.
        let (lat, lon) = TestPacks.brussels
        XCTAssertTrue(nl.bbox.contains(lat: lat, lon: lon))
        XCTAssertFalse(nl.contains(lat: lat, lon: lon))
    }

    func testContainsFallsBackToBoundingBoxWithoutPolygon() {
        var nl = TestPacks.netherlands
        nl.coverage = []
        XCTAssertTrue(nl.contains(lat: TestPacks.brussels.lat, lon: TestPacks.brussels.lon))
        XCTAssertFalse(nl.contains(lat: TestPacks.copenhagen.lat, lon: TestPacks.copenhagen.lon))
    }

    func testMultiPolygonCoverageChecksEveryRing() {
        let benelux = TestPacks.benelux
        XCTAssertTrue(benelux.contains(lat: TestPacks.brussels.lat, lon: TestPacks.brussels.lon))
        XCTAssertTrue(benelux.contains(lat: TestPacks.amsterdam.lat, lon: TestPacks.amsterdam.lon))
        XCTAssertTrue(benelux.contains(lat: 49.6, lon: 6.1)) // Luxembourg
        XCTAssertFalse(benelux.contains(lat: TestPacks.copenhagen.lat, lon: TestPacks.copenhagen.lon))
    }

    func testJsonRoundTripKeepsCoverageAndBbox() throws {
        let original = TestPacks.belgium
        let restored = try PackInfo.fromJSON(JSON(parsing: original.toJSON().serialized()))
        XCTAssertEqual(original, restored)
        XCTAssertTrue(restored.contains(lat: TestPacks.brussels.lat, lon: TestPacks.brussels.lon))
        XCTAssertNil(restored.basemapUrl)
    }

    func testManifestWithoutCoverageStillParses() throws {
        let json = try JSON(parsing: """
            {"id":"x","name":"X","region":"r","railway_url":"u","railway_bytes":1,"basemap_url":null,
             "basemap_bytes":0,"bbox":[0,0,1,1],"data_date":"","version":2}
            """)
        let info = try PackInfo.fromJSON(json)
        XCTAssertTrue(info.coverage.isEmpty)
        XCTAssertTrue(info.contains(lat: 0.5, lon: 0.5))
        XCTAssertEqual(2, info.version)
    }

    func testManifestListsPacks() throws {
        let manifest: JSON = ["packs": [TestPacks.netherlands.toJSON(), TestPacks.belgium.toJSON()]]
        XCTAssertEqual(["netherlands", "belgium"], try PackInfo.list(fromManifest: manifest).map(\.id))
        XCTAssertThrowsError(try PackInfo.list(fromManifest: [:]))
    }

    func testRegionLabelMakesGeofabrikIdsReadable() {
        XCTAssertEqual("North America", PackInfo.regionLabel(fromId: "north-america"))
        XCTAssertEqual("Europe", PackInfo.regionLabel(fromId: "europe"))
        XCTAssertEqual("Australia Oceania", PackInfo.regionLabel(fromId: "australia-oceania"))
        XCTAssertEqual("Ireland and Northern Ireland", PackInfo.regionLabel(fromId: "ireland-and-northern-ireland"))
        XCTAssertEqual("", PackInfo.regionLabel(fromId: ""))
    }

    func testRegionLabelPrefersTheManifestName() throws {
        var canada = TestPacks.netherlands
        canada.id = "canada"
        canada.region = "north-america"
        XCTAssertEqual("North America", canada.regionLabel)
        var oceania = canada
        oceania.region = "australia-oceania"
        oceania.regionName = "Australia and Oceania"
        XCTAssertEqual("Australia and Oceania", oceania.regionLabel)
        let restored = try PackInfo.fromJSON(JSON(parsing: oceania.toJSON().serialized()))
        XCTAssertEqual("Australia and Oceania", restored.regionLabel)
    }

    func testFormatBytes() {
        XCTAssertEqual("40 MB", formatBytes(40_000_000))
        XCTAssertEqual("1.2 GB", formatBytes(1_234_000_000))
        XCTAssertEqual("512 kB", formatBytes(512_000))
    }

    func testDownloadFraction() {
        XCTAssertEqual(0.25, DownloadState.running(bytesDone: 25, bytesTotal: 100, stage: "railway").fraction)
        XCTAssertEqual(1, DownloadState.running(bytesDone: 120, bytesTotal: 100, stage: "railway").fraction)
        XCTAssertEqual(0, DownloadState.running(bytesDone: 10, bytesTotal: 0, stage: "railway").fraction)
        XCTAssertEqual(0, DownloadState.failed(message: "x").fraction)
    }
}
