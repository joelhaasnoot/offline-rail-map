// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation

/**
 The world overview that ships with the app: basemap layers drawn from a zoom 0-4 world file,
 plus a land-coloured mask over every downloaded basemap pack so the coarse world coastlines
 never show through the detailed pack underneath.
 */
public enum WorldLayers {
    public static let source = "world"
    public static let maskSource = "pack-mask"
    public static let maskLayerId = "pack-mask"

    /// World tiles stop at zoom 4; past this zoom their coastlines are too coarse to be useful.
    public static let maxVisibleZoom = 10.0

    private static let attribution =
        "<a href=\"https://www.openstreetmap.org/copyright\">© OpenStreetMap contributors</a> · " +
        "<a href=\"https://www.naturalearthdata.com\">Natural Earth</a>"

    public static func source(pmtilesUrl: String) -> JSON {
        ["type": "vector", "url": .string(pmtilesUrl), "attribution": .string(attribution)]
    }

    /**
     A copy of a basemap layer that reads from the world source, capped at `maxVisibleZoom` and
     with labels in English where available. Returns nil for layers that would never be visible.
     */
    public static func worldCopy(_ layer: JSON) -> JSON? {
        var copy = layer
        let maxzoom = min(layer["maxzoom"]?.double ?? 24, maxVisibleZoom)
        if (layer["minzoom"]?.double ?? 0) >= maxzoom {
            return nil
        }
        copy["id"] = .string("\(layer["id"]?.string ?? "")__\(source)")
        copy["source"] = .string(source)
        copy["maxzoom"] = .number(maxzoom)
        if let field = copy["layout"]?["text-field"] {
            copy["layout"]?["text-field"] = preferEnglish(field)
        }
        return copy
    }

    /// Replaces `["get", "name"]` with `["coalesce", ["get", "name:en"], ["get", "name"]]`.
    public static func preferEnglish(_ expression: JSON) -> JSON {
        guard case .array(let items) = expression else {
            return expression
        }
        if items == ["get", "name"] {
            return ["coalesce", ["get", "name:en"], ["get", "name"]]
        }
        return .array(items.map(preferEnglish))
    }

    /// Region outlines of the given packs as one MultiPolygon (bounding boxes when unknown).
    public static func maskGeometry(_ packs: [PackInfo]) -> JSON? {
        var polygons: [JSON] = []
        for pack in packs {
            let b = pack.bbox
            let rings = pack.coverage.isEmpty
                ? [[LonLat(b.west, b.south), LonLat(b.east, b.south), LonLat(b.east, b.north), LonLat(b.west, b.north)]]
                : pack.coverage
            for ring in rings where ring.count >= 3 {
                var coords = ring.map { JSON.array([.number($0.lon), .number($0.lat)]) }
                if ring.first != ring.last {
                    coords.append(.array([.number(ring[0].lon), .number(ring[0].lat)]))
                }
                polygons.append(.array([.array(coords)]))
            }
        }
        if polygons.isEmpty {
            return nil
        }
        return ["type": "MultiPolygon", "coordinates": .array(polygons)]
    }

    public static func maskSource(_ geometry: JSON) -> JSON {
        ["type": "geojson", "data": ["type": "Feature", "properties": [:], "geometry": geometry]]
    }

    /**
     World labels are drawn above the pack basemaps (whose low-zoom tiles span far beyond their
     country and would paint over them), so they must skip the downloaded regions where the pack
     shows its own labels. Continents are not in the packs and stay everywhere.
     */
    public static func hideInsideMask(_ layer: JSON, geometry: JSON) -> JSON {
        if layer["source-layer"]?.string == "place" && (layer["id"]?.string ?? "").hasPrefix("place-continent") {
            return layer
        }
        let outside: JSON = ["!", ["within", geometry]]
        var copy = layer
        if let filter = layer["filter"] {
            copy["filter"] = ["all", filter, outside]
        } else {
            copy["filter"] = outside
        }
        return copy
    }

    public static func maskLayer(color: String) -> JSON {
        [
            "id": .string(maskLayerId),
            "type": "fill",
            "source": .string(maskSource),
            "paint": ["fill-color": .string(color), "fill-antialias": false],
        ]
    }
}
