// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation
import Observation
import os
import RailwayMapCore
import UIKit

enum SheetTab: String, CaseIterable, Identifiable {
    case key
    case packs
    case options
    case about

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .key:
            return "Key"
        case .packs:
            return "Packs"
        case .options:
            return "Options"
        case .about:
            return "About"
        }
    }
}

/// What the main map shows right now, captured when the sheet opens.
struct LegendContext: Hashable {
    let zoom: Int
    /// Legend source name to the feature keys rendered on screen.
    let inView: [String: Set<String>]
}

/// App-wide state: the selected view and options, the pack store and the map.
@MainActor
@Observable
final class AppModel {
    private static let log = Logger(subsystem: "com.offlinerailmap.ios", category: "AppModel")

    let prefs = Prefs()
    let packs: PackStore
    let styles: StyleBuilder
    let composer: SpriteComposer
    let map = MapController()

    var mode: MapMode {
        didSet {
            prefs.modeId = mode.id
        }
    }

    var options: MapOptions {
        didSet {
            options.save(to: prefs)
        }
    }

    var sheetTab: SheetTab?
    var legendContext: LegendContext?
    var styleError: String?

    init() {
        let assets = MapAssets(root: Bundle.main.resourceURL!.appendingPathComponent("assets", isDirectory: true))
        styles = StyleBuilder(assets: assets)
        // Stacked and positioned signal icons ("a|b@bottom") are not in the sprite; the website composes
        // them when the map asks for them, and so do we. Decode their parts before the map first asks.
        let composer = SpriteComposer(assets: assets, screenScale: UIScreen.main.scale)
        self.composer = composer
        Task.detached(priority: .utility) {
            composer.warmUp()
        }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let manifest = (Bundle.main.object(forInfoDictionaryKey: "ManifestURL") as? String)
            .flatMap(URL.init(string:)) ?? URL(string: "https://data.offlinerailmap.com/manifest.json")!
        packs = PackStore(packsDir: support.appendingPathComponent("packs", isDirectory: true), manifestURL: manifest)

        mode = MapMode.fromId(prefs.modeId)
        options = MapOptions.from(prefs)
        map.prefs = prefs
        map.composer = composer
    }

    var coverage: Coverage {
        Coverage.of(viewport: map.viewport, zoom: map.zoom, installed: packs.installed, available: packs.available)
    }

    /// Rebuilds the style for the current view, options and packs and hands it to the map.
    func applyStyle() async {
        let styles = styles
        let mode = mode
        let options = options
        let installed = packs.installed
        do {
            let json = try await Task.detached(priority: .userInitiated) {
                try styles.build(mode: mode, options: options, packs: installed)
            }.value
            if Task.isCancelled {
                return
            }
            map.setStyle(json)
        } catch {
            Self.log.error("style build failed: \(error.localizedDescription)")
            styleError = error.localizedDescription
        }
    }

    /// Captures what the map shows when the sheet opens, for the key's "On screen" filter.
    func captureLegendContext() async {
        legendContext = nil
        let styles = styles
        let mode = mode
        let options = options
        let loaded = try? await Task.detached(priority: .userInitiated) {
            (try styles.legendView(modeId: mode.id), try styles.ormLayers(mode: mode, options: options))
        }.value
        guard let loaded else {
            legendContext = LegendContext(zoom: Int(map.zoom.rounded(.down)), inView: [:])
            return
        }
        legendContext = map.legendContext(legendView: loaded.0, layers: loaded.1.layers, packs: packs.installed)
    }

    func showPack(_ pack: InstalledPack) {
        sheetTab = nil
        map.fit(to: [pack])
    }
}
