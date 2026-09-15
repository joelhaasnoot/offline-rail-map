// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation

public struct LonLat: Hashable, Sendable {
    public var lon: Double
    public var lat: Double

    public init(_ lon: Double, _ lat: Double) {
        self.lon = lon
        self.lat = lat
    }
}

public struct BBox: Hashable, Sendable {
    public var west: Double
    public var south: Double
    public var east: Double
    public var north: Double

    public init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
    }

    public func contains(lat: Double, lon: Double) -> Bool {
        lon >= west && lon <= east && lat >= south && lat <= north
    }
}

public struct PackError: LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

/// One downloadable country pack, as described by the manifest.
public struct PackInfo: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var region: String
    public var railwayUrl: String
    public var railwayBytes: Int64
    public var basemapUrl: String?
    public var basemapBytes: Int64
    public var bbox: BBox
    public var dataDate: String
    public var version: Int
    /// Outer rings of the region polygon; empty when unknown (fall back to the bbox).
    public var coverage: [[LonLat]]
    /// Display name of `region` from the manifest, e.g. "North America"; empty in older manifests.
    public var regionName: String

    public init(
        id: String,
        name: String,
        region: String,
        railwayUrl: String,
        railwayBytes: Int64,
        basemapUrl: String?,
        basemapBytes: Int64,
        bbox: BBox,
        dataDate: String,
        version: Int,
        coverage: [[LonLat]] = [],
        regionName: String = ""
    ) {
        self.id = id
        self.name = name
        self.region = region
        self.railwayUrl = railwayUrl
        self.railwayBytes = railwayBytes
        self.basemapUrl = basemapUrl
        self.basemapBytes = basemapBytes
        self.bbox = bbox
        self.dataDate = dataDate
        self.version = version
        self.coverage = coverage
        self.regionName = regionName
    }

    /// Human-readable parent region: the manifest's name, or the id made readable.
    public var regionLabel: String {
        regionName.trimmingCharacters(in: .whitespaces).isEmpty ? Self.regionLabel(fromId: region) : regionName
    }

    public var totalBytes: Int64 {
        railwayBytes + basemapBytes
    }

    /// True when the point lies inside the pack's region polygon (or its bbox when no polygon is known).
    public func contains(lat: Double, lon: Double) -> Bool {
        if coverage.isEmpty {
            return bbox.contains(lat: lat, lon: lon)
        }
        return coverage.contains { ring in Self.pointInRing(ring, x: lon, y: lat) }
    }

    private static func pointInRing(_ ring: [LonLat], x: Double, y: Double) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let xi = ring[i].lon
            let yi = ring[i].lat
            let xj = ring[j].lon
            let yj = ring[j].lat
            if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    public func toJSON() -> JSON {
        [
            "id": .string(id),
            "name": .string(name),
            "region": .string(region),
            "region_name": .string(regionName),
            "railway_url": .string(railwayUrl),
            "railway_bytes": .number(Double(railwayBytes)),
            "basemap_url": basemapUrl.map(JSON.string) ?? .null,
            "basemap_bytes": .number(Double(basemapBytes)),
            "bbox": .array([bbox.west, bbox.south, bbox.east, bbox.north].map(JSON.number)),
            "data_date": .string(dataDate),
            "version": .number(Double(version)),
            "coverage": .array(coverage.map { ring in .array(ring.map { .array([.number($0.lon), .number($0.lat)]) }) }),
        ]
    }

    public static func fromJSON(_ o: JSON) throws -> PackInfo {
        guard let id = o["id"]?.string, let name = o["name"]?.string, let railwayUrl = o["railway_url"]?.string else {
            throw PackError("pack is missing id, name or railway_url")
        }
        guard let box = o["bbox"]?.array?.compactMap(\.double), box.count == 4 else {
            throw PackError("pack \(id) has no valid bbox")
        }
        let basemapUrl = o["basemap_url"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return PackInfo(
            id: id,
            name: name,
            region: o["region"]?.string ?? "",
            railwayUrl: railwayUrl,
            railwayBytes: Int64(o["railway_bytes"]?.double ?? 0),
            basemapUrl: basemapUrl,
            basemapBytes: Int64(o["basemap_bytes"]?.double ?? 0),
            bbox: BBox(west: box[0], south: box[1], east: box[2], north: box[3]),
            dataDate: o["data_date"]?.string ?? "",
            version: Int(o["version"]?.double ?? 1),
            coverage: parseCoverage(o["coverage"]),
            regionName: o["region_name"]?.string ?? ""
        )
    }

    private static let lowercaseWords: Set<String> = ["and", "of", "the"]

    /// "north-america" -> "North America", "australia-oceania" -> "Australia Oceania".
    public static func regionLabel(fromId id: String) -> String {
        id.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .enumerated()
            .map { index, word in
                let text = String(word)
                if index > 0 && lowercaseWords.contains(text) {
                    return text
                }
                return text.prefix(1).uppercased() + text.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func parseCoverage(_ value: JSON?) -> [[LonLat]] {
        guard let rings = value?.array else {
            return []
        }
        return rings.map { ring in
            (ring.array ?? []).compactMap { point in
                guard let lon = point[0]?.double, let lat = point[1]?.double else {
                    return nil
                }
                return LonLat(lon, lat)
            }
        }
    }

    public static func list(fromManifest manifest: JSON) throws -> [PackInfo] {
        guard let packs = manifest["packs"]?.array else {
            throw PackError("manifest has no packs")
        }
        return try packs.map(fromJSON)
    }
}

/// A pack that is fully downloaded and stored on the device.
public struct InstalledPack: Hashable, Sendable, Identifiable {
    public let info: PackInfo
    public let dir: URL
    /// The basemap file, when the pack has one on disk.
    public let basemapFile: URL?

    public init(info: PackInfo, dir: URL) {
        self.info = info
        self.dir = dir
        let basemap = dir.appendingPathComponent("basemap.pmtiles")
        basemapFile = FileManager.default.fileExists(atPath: basemap.path) ? basemap : nil
    }

    public var id: String {
        info.id
    }

    public var railwayFile: URL {
        dir.appendingPathComponent("railway.pmtiles")
    }
}

public enum DownloadState: Hashable, Sendable {
    case running(bytesDone: Int64, bytesTotal: Int64, stage: String)
    case failed(message: String)

    public var fraction: Double {
        guard case .running(let done, let total, _) = self, total > 0 else {
            return 0
        }
        return min(max(Double(done) / Double(total), 0), 1)
    }

    public var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}

/// "40 MB", "1.2 GB"; decimal units as in the Android app.
public func formatBytes(_ bytes: Int64) -> String {
    if bytes >= 1_000_000_000 {
        return String(format: "%.1f GB", Double(bytes) / 1e9)
    }
    if bytes >= 1_000_000 {
        return String(format: "%.0f MB", Double(bytes) / 1e6)
    }
    return String(format: "%.0f kB", Double(bytes) / 1e3)
}
