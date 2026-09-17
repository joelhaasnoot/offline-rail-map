// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import SwiftUI

private let sourceURL = "https://github.com/joelhaasnoot/offline-rail-map"

/// One credit line: what it is, who made it (linked), extra people, its licence.
private struct Credit: Identifiable {
    let what: String
    let who: String
    let license: String
    let url: String
    var note = ""

    var id: String {
        what
    }
}

private let credits = [
    Credit(what: "Map Data", who: "© OpenStreetMap contributors", license: "ODbL 1.0", url: "https://www.openstreetmap.org/copyright"),
    Credit(
        what: "Railway Map Style, Symbols and Tile Pipeline",
        who: "OpenRailwayMap",
        license: "GPL-3.0",
        url: "https://github.com/hiddewie/OpenRailwayMap-vector",
        note: "by Hidde Wieringa, with earlier styles by Michael Reichert and Alexander Matheisen"
    ),
    Credit(what: "World Overview", who: "Natural Earth", license: "public domain", url: "https://www.naturalearthdata.com"),
    Credit(what: "Basemap Schema", who: "OpenMapTiles", license: "BSD-3-Clause and CC-BY 4.0", url: "https://openmaptiles.org"),
    Credit(what: "Map Rendering", who: "MapLibre Native", license: "BSD-2-Clause", url: "https://maplibre.org"),
    Credit(what: "Monospace Font", who: "Fira Code", license: "SIL Open Font License 1.1", url: "https://github.com/tonsky/FiraCode"),
]

struct AboutContent: View {
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Offline Rail Map")
                    .font(.title2.bold())
                Text("Version \(version)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                section("Disclaimer")
                Text("Do not rely on this map for safety, navigation or railway operations. This app is not affiliated with or endorsed by OpenRailwayMap, OpenStreetMap or any railway company. The app is provided as is, without any warranty.")

                section("Privacy")
                Text("This app only contacts our servers to download new packs. Your location stays on your phone and is never processed or logged. We use no Third-Party SDKs. The app has no accounts.")

                section("Credits")
                ForEach(credits) { credit in
                    Text(markdown("\(credit.what): [\(credit.who)](\(credit.url))\(credit.note.isEmpty ? "" : " \(credit.note)") (\(credit.license))"))
                        .padding(.vertical, 2)
                }

                section("License")
                Text(markdown("This app is free software, released under the GNU General Public License version 3 or later. [The source code is on GitHub.](\(sourceURL))"))
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func section(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.top, 12)
            Text(title)
                .font(.headline)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
