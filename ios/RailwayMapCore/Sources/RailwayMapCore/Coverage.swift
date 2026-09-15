// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation

/// A visible map area.
public struct GeoBounds: Hashable, Sendable {
    public var south: Double
    public var west: Double
    public var north: Double
    public var east: Double

    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }

    public var center: (lat: Double, lon: Double) {
        ((south + north) / 2, (west + east) / 2)
    }

    func intersects(_ bbox: BBox) -> Bool {
        !(bbox.west > east || bbox.east < west || bbox.south > north || bbox.north < south)
    }
}

/// What the current viewport is showing in terms of pack coverage.
public enum Coverage: Hashable, Sendable {
    case covered
    case missing(suggested: PackInfo?)

    /// Zoomed out further than this, the viewport is so large that a coverage verdict is meaningless.
    static let minZoomForVerdict = 6.0

    public static func of(
        viewport: GeoBounds?,
        zoom: Double,
        installed: [InstalledPack],
        available: [PackInfo]
    ) -> Coverage {
        guard let viewport, !installed.isEmpty, zoom >= minZoomForVerdict else {
            return .covered // the "no packs at all" card handles the empty case
        }
        // Centre plus the four corners: covered when any of them lies inside an installed pack.
        let c = viewport.center
        let probes = [
            (c.lat, c.lon),
            (viewport.north, viewport.west),
            (viewport.north, viewport.east),
            (viewport.south, viewport.west),
            (viewport.south, viewport.east),
        ]
        let covered = installed.contains { pack in
            viewport.intersects(pack.info.bbox) && probes.contains { pack.info.contains(lat: $0.0, lon: $0.1) }
        }
        if covered {
            return .covered
        }
        let installedIds = Set(installed.map(\.info.id))
        let suggestion = available
            .filter { !installedIds.contains($0.id) && $0.contains(lat: c.lat, lon: c.lon) }
            // Prefer the smallest pack that contains the point (a region over a whole country).
            .min { area($0.bbox) < area($1.bbox) }
        return .missing(suggested: suggestion)
    }

    private static func area(_ b: BBox) -> Double {
        (b.east - b.west) * (b.north - b.south)
    }
}
