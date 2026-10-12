// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import RailwayMapCore
import SwiftUI

@main
struct OfflineRailwayMapApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iOS woke the app because pack downloads finished in the background. The session itself is
    /// created with the app model, which picks up the finished files.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == PackStore.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        PackStore.handleBackgroundEvents(completion: completionHandler)
    }
}
