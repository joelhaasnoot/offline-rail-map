// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// Everything of the iOS app that does not need UIKit or MapLibre: style building, pack
// bookkeeping and downloads, the map key and coverage checks. Kept in a package so it can be
// built and unit tested on its own (`swift test`).
let package = Package(
    name: "RailwayMapCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RailwayMapCore", targets: ["RailwayMapCore"]),
    ],
    targets: [
        .target(name: "RailwayMapCore"),
        .testTarget(name: "RailwayMapCoreTests", dependencies: ["RailwayMapCore"]),
    ]
)
