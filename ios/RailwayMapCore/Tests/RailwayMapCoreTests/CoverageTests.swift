// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import XCTest
@testable import RailwayMapCore

final class CoverageTests: XCTestCase {
    /// A viewport of roughly a city at zoom 12, centred on the given point.
    private func viewportAround(_ point: (lat: Double, lon: Double), halfSize: Double = 0.05) -> GeoBounds {
        GeoBounds(south: point.lat - halfSize, west: point.lon - halfSize, north: point.lat + halfSize, east: point.lon + halfSize)
    }

    private let installedNl = [TestPacks.installed(TestPacks.netherlands)]
    private let available = [TestPacks.netherlands, TestPacks.belgium, TestPacks.benelux]

    func testAreaInsideAnInstalledPackIsCovered() {
        let result = Coverage.of(viewport: viewportAround(TestPacks.amsterdam), zoom: 12, installed: installedNl, available: available)
        XCTAssertEqual(.covered, result)
    }

    func testBrusselsIsMissingAndSuggestsBelgiumEvenThoughItIsInsideTheDutchBbox() {
        let result = Coverage.of(viewport: viewportAround(TestPacks.brussels), zoom: 12, installed: installedNl, available: available)
        XCTAssertEqual(.missing(suggested: TestPacks.belgium), result)
    }

    func testSmallestPackContainingThePointIsSuggested() {
        // Both Belgium and Benelux contain Brussels; Belgium is the smaller pack.
        let result = Coverage.of(
            viewport: viewportAround(TestPacks.brussels), zoom: 12, installed: installedNl, available: available.reversed()
        )
        XCTAssertEqual(.missing(suggested: TestPacks.belgium), result)
    }

    func testAreaNobodyCoversIsMissingWithoutSuggestion() {
        let result = Coverage.of(viewport: viewportAround(TestPacks.copenhagen), zoom: 12, installed: installedNl, available: available)
        XCTAssertEqual(.missing(suggested: nil), result)
    }

    func testInstalledPacksAreNeverSuggested() {
        let installed = [TestPacks.installed(TestPacks.netherlands), TestPacks.installed(TestPacks.belgium)]
        let result = Coverage.of(viewport: viewportAround(TestPacks.brussels), zoom: 12, installed: installed, available: available)
        XCTAssertEqual(.covered, result)
    }

    func testViewportTouchingAPackAtItsEdgeIsCovered() {
        // Centre just outside the polygon but a corner inside it.
        let viewport = GeoBounds(south: 51.2, west: 3.7, north: 51.5, east: 4.0)
        XCTAssertEqual(.covered, Coverage.of(viewport: viewport, zoom: 10, installed: installedNl, available: available))
    }

    func testZoomedOutViewsNeverShowTheBanner() {
        let result = Coverage.of(
            viewport: viewportAround(TestPacks.copenhagen, halfSize: 20), zoom: 3, installed: installedNl, available: available
        )
        XCTAssertEqual(.covered, result)
    }

    func testNoInstalledPacksIsHandledElsewhere() {
        XCTAssertEqual(.covered, Coverage.of(viewport: viewportAround(TestPacks.copenhagen), zoom: 12, installed: [], available: available))
        XCTAssertEqual(.covered, Coverage.of(viewport: nil, zoom: 12, installed: installedNl, available: available))
    }
}
