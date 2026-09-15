// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import RailwayMapCore
import SwiftUI

@main
struct OfflineRailwayMapApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MapScreen(model: model)
                .tint(Theme.orange)
                .onOpenURL { url in
                    if let camera = GeoLink.parse(url) {
                        model.map.pendingCamera = camera
                    }
                }
        }
    }
}
