// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation

/**
 Naming of pack folders under `Application Support/packs`, identical to the Android app.

 A download goes into `<id>@<timestamp>.download` and is renamed to `<id>@<timestamp>` once every
 file and `pack.json` are in place, so an installed pack is never half-written. An update therefore
 sits next to the previous copy for a moment; the newest copy wins and the older one is removed.
 Each copy has its own path, so the map never mixes cached data of two versions.
 */
public enum PackDirs {
    public static let stagingSuffix = ".download"

    public static func stagingName(id: String, timestamp: Int64) -> String {
        "\(id)@\(timestamp)\(stagingSuffix)"
    }

    public static func installedName(stagingName: String) -> String {
        stagingName.hasSuffix(stagingSuffix) ? String(stagingName.dropLast(stagingSuffix.count)) : stagingName
    }

    public static func isStaging(_ name: String) -> Bool {
        name.hasSuffix(stagingSuffix)
    }

    /// True for every folder, finished or not, that belongs to pack `id`.
    public static func belongsTo(_ name: String, id: String) -> Bool {
        name == id || name.hasPrefix("\(id)@")
    }

    private static func timestamp(_ name: String) -> Int64 {
        guard let at = name.lastIndex(of: "@") else {
            return 0
        }
        return Int64(installedName(stagingName: String(name[name.index(after: at)...]))) ?? 0
    }

    /**
     Splits installed copies into the one to use per pack id (highest version, then newest folder)
     and the superseded ones that can be deleted.
     */
    public static func choose<T>(
        _ copies: [T],
        id: (T) -> String,
        version: (T) -> Int,
        folderName: (T) -> String
    ) -> (chosen: [T], superseded: [T]) {
        var chosen: [T] = []
        var superseded: [T] = []
        var order: [String] = []
        var groups: [String: [T]] = [:]
        for copy in copies {
            let key = id(copy)
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(copy)
        }
        for key in order {
            let sorted = groups[key]!.sorted { a, b in
                if version(a) != version(b) {
                    return version(a) > version(b)
                }
                return timestamp(folderName(a)) > timestamp(folderName(b))
            }
            chosen.append(sorted[0])
            superseded.append(contentsOf: sorted.dropFirst())
        }
        return (chosen, superseded)
    }
}
