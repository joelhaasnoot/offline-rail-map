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
    Credit(what: "Map data", who: "© OpenStreetMap contributors", license: "ODbL 1.0", url: "https://www.openstreetmap.org/copyright"),
    Credit(
        what: "Railway map style, symbols and tile pipeline",
        who: "OpenRailwayMap",
        license: "GPL-3.0",
        url: "https://github.com/hiddewie/OpenRailwayMap-vector",
        note: "by Hidde Wieringa, with earlier styles by Michael Reichert and Alexander Matheisen"
    ),
    Credit(what: "World overview", who: "Natural Earth", license: "public domain", url: "https://www.naturalearthdata.com"),
    Credit(what: "Basemap schema", who: "OpenMapTiles", license: "BSD-3-Clause and CC-BY 4.0", url: "https://openmaptiles.org"),
    Credit(what: "Map rendering", who: "MapLibre Native", license: "BSD-2-Clause", url: "https://maplibre.org"),
    Credit(what: "Monospace font", who: "Fira Code", license: "SIL Open Font License 1.1", url: "https://github.com/tonsky/FiraCode"),
]

struct AboutContent: View {
    let manifestURL: URL

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let dataHost = manifestURL.host ?? manifestURL.absoluteString

        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Offline Railway Map")
                    .font(.title2.bold())
                Text("Version \(version)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Railway infrastructure, speeds, train protection and electrification, available offline.")

                section("Disclaimer")
                Text("This is an independent project. It is not affiliated with or endorsed by OpenRailwayMap, OpenStreetMap or any railway company.")
                Text("The map shows OpenStreetMap data mapped by volunteers. It can be incomplete, out of date or wrong. Each country pack is a snapshot from the date shown in the pack list.")
                Text("Do not rely on this map for safety, navigation or railway operations. Never enter railway tracks or other areas without permission.")
                Text("The app is provided as is, without any warranty.")

                section("Privacy")
                Text("The app only connects to \(dataHost), to load the list of country packs and to download them. Your location is used on this device only and is never sent anywhere.")

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
