// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation
@testable import RailwayMapCore

/**
 Synthetic packs with simplified region polygons. The Netherlands ring deliberately has a
 bounding box that reaches into Belgium (as the real Geofabrik one does), so that tests can
 tell polygon-based checks apart from bounding-box checks.
 */
enum TestPacks {
    private static func ring(_ lonLat: Double...) -> [LonLat] {
        stride(from: 0, to: lonLat.count, by: 2).map { LonLat(lonLat[$0], lonLat[$0 + 1]) }
    }

    static let netherlandsRing = ring(
        3.3, 51.4, 4.2, 51.35, 5.5, 51.4, 5.6, 50.75, 6.2, 50.75, 6.1, 51.9, 7.2, 52.2, 7.2, 53.5, 4.5, 53.5, 3.3, 51.5
    )
    static let belgiumRing = ring(2.5, 49.5, 6.4, 49.5, 6.4, 50.7, 5.6, 50.75, 5.5, 51.4, 4.2, 51.35, 3.3, 51.4, 2.5, 51.1)
    static let luxembourgRing = ring(5.7, 49.45, 6.5, 49.45, 6.5, 50.2, 5.7, 50.2)

    static let netherlands = PackInfo(
        id: "netherlands", name: "Netherlands", region: "europe",
        railwayUrl: "http://packs/netherlands/railway.pmtiles", railwayBytes: 40_000_000,
        basemapUrl: nil, basemapBytes: 0,
        bbox: BBox(west: 3.3, south: 50.75, east: 7.2, north: 53.5), dataDate: "2026-09-11", version: 1,
        coverage: [netherlandsRing]
    )

    static let belgium: PackInfo = {
        var pack = netherlands
        pack.id = "belgium"
        pack.name = "Belgium"
        pack.railwayUrl = "http://packs/belgium/railway.pmtiles"
        pack.bbox = BBox(west: 2.5, south: 49.5, east: 6.4, north: 51.4)
        pack.coverage = [belgiumRing]
        return pack
    }()

    static let benelux: PackInfo = {
        var pack = netherlands
        pack.id = "benelux"
        pack.name = "Benelux"
        pack.railwayUrl = "http://packs/benelux/railway.pmtiles"
        pack.bbox = BBox(west: 2.5, south: 49.45, east: 7.2, north: 53.5)
        pack.coverage = [netherlandsRing, belgiumRing, luxembourgRing]
        return pack
    }()

    static func installed(_ info: PackInfo) -> InstalledPack {
        InstalledPack(info: info, dir: FileManager.default.temporaryDirectory.appendingPathComponent("packs/\(info.id)"))
    }

    // Well-known points: lat, lon
    static let amsterdam = (lat: 52.37, lon: 4.90)
    static let maastricht = (lat: 50.85, lon: 5.69)
    static let brussels = (lat: 50.845, lon: 4.35)
    static let copenhagen = (lat: 55.67, lon: 12.57)
}
