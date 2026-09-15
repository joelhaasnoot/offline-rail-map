// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation

/// Supports `geo:lat,lon?z=zoom` and `geo:0,0?q=lat,lon` links from other apps.
public enum GeoLink {
    public static func parse(_ url: URL) -> SavedCamera? {
        guard url.scheme?.lowercased() == "geo" else {
            return nil
        }
        let text = url.absoluteString
        let raw = String(text[text.index(text.startIndex, offsetBy: 4)...]).removingPercentEncoding ?? ""
        let coords = #/(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/#
        let parts = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.first.map(String.init) ?? ""
        let query = parts.count > 1 ? String(parts[1]) : ""

        let fromQuery = query.firstMatch(of: #/q=([^&]*)/#).flatMap { String($0.1).firstMatch(of: coords) }
        guard let match = fromQuery ?? path.firstMatch(of: coords),
              let lat = Double(match.1), let lon = Double(match.2) else {
            return nil
        }
        if fromQuery == nil && lat == 0 && lon == 0 {
            return nil
        }
        let zoom = query.firstMatch(of: #/z=(\d+(?:\.\d+)?)/#).flatMap { Double($0.1) } ?? 14
        return SavedCamera(lat: lat, lon: lon, zoom: zoom)
    }
}
