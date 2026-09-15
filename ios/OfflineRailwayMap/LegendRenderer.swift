// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import MapLibre
import os
import RailwayMapCore
import UIKit

/**
 Renders key rows with one reused `MLNMapSnapshotter`, strictly one snapshot at a time, and keeps
 the results in memory while the key is open.
 */
@MainActor
final class LegendRenderer {
    private static let log = Logger(subsystem: "com.offlinerailmap.ios", category: "LegendRenderer")
    private static let snapshotTimeout: Duration = .seconds(8)

    static let size = CGSize(
        width: Legend.unitsToPoints(Legend.rowWidthUnits),
        height: Legend.unitsToPoints(Legend.rowHeightUnits)
    )

    private let cache = NSCache<NSString, UIImage>()
    private var snapshotter: MLNMapSnapshotter?
    private var styleFiles: [String: URL] = [:]
    /// The snapshot queue: every render waits for the one before it.
    private var tail: Task<Void, Never>?
    private let styleImages: StyleImages

    init(composer: SpriteComposer) {
        cache.totalCostLimit = 24 * 1024 * 1024
        styleImages = StyleImages(composer: composer)
    }

    func cached(styleKey: String, row: Int) -> UIImage? {
        cache.object(forKey: "\(styleKey)#\(row)" as NSString)
    }

    /// Renders row `row` of a key style; `composites` are the composed icon ids the style's samples use.
    func render(styleKey: String, styleJSON: String, composites: [String], row: Int) async -> UIImage? {
        if let image = cached(styleKey: styleKey, row: row) {
            return image
        }
        let wanted = Wanted()
        let previous = tail
        let job = Task { () -> UIImage? in
            await previous?.value
            if let image = cached(styleKey: styleKey, row: row) {
                return image
            }
            // Skip rows scrolled away while waiting. A started snapshot always finishes first.
            if !wanted.value {
                return nil
            }
            styleImages.composites = composites
            let image = await snapshot(styleURL: styleFile(styleKey: styleKey, json: styleJSON), row: row)
            if let image {
                let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
                cache.setObject(image, forKey: "\(styleKey)#\(row)" as NSString, cost: cost)
            }
            return image
        }
        tail = Task {
            _ = await job.value
        }
        return await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            wanted.value = false
        }
    }

    /// The snapshotter only reads styles from URLs, so each key style is written to a temporary file.
    private func styleFile(styleKey: String, json: String) -> URL {
        if let url = styleFiles[styleKey] {
            return url
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("legend", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).json")
        do {
            try Data(json.utf8).write(to: url)
        } catch {
            Self.log.warning("could not write legend style: \(error.localizedDescription)")
        }
        styleFiles[styleKey] = url
        return url
    }

    private func snapshot(styleURL: URL, row: Int) async -> UIImage? {
        let center = Legend.rowCenter(row)
        let camera = MLNMapCamera()
        camera.centerCoordinate = CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon)
        let options = MLNMapSnapshotOptions(styleURL: styleURL, camera: camera, size: Self.size)
        options.zoomLevel = Legend.renderZoom
        options.showsLogo = false
        options.showsAttribution = false

        let snap: MLNMapSnapshotter
        if let snapshotter {
            snapshotter.options = options
            snap = snapshotter
        } else {
            snap = MLNMapSnapshotter(options: options)
            snap.delegate = styleImages
            snapshotter = snap
        }

        return await withCheckedContinuation { continuation in
            let once = Once()
            // A snapshot that never reports back is abandoned and the snapshotter recreated,
            // so one bad row cannot stall the whole key.
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: Self.snapshotTimeout)
                if once.claim() {
                    Self.log.warning("legend row \(row) timed out; recreating the snapshotter")
                    snap.cancel()
                    if self.snapshotter === snap {
                        self.snapshotter = nil
                    }
                    continuation.resume(returning: nil)
                }
            }
            snap.start { snapshot, error in
                guard once.claim() else {
                    return
                }
                timeout.cancel()
                if let error {
                    Self.log.warning("legend row \(row) failed: \(error.localizedDescription)")
                }
                continuation.resume(returning: snapshot?.image)
            }
        }
    }

    func close() {
        snapshotter?.cancel()
        snapshotter = nil
        cache.removeAllObjects()
        for url in styleFiles.values {
            try? FileManager.default.removeItem(at: url)
        }
        styleFiles.removeAll()
    }
}

/**
 Some upstream icons (e.g. "...@bottom" signal compositions) are generated at runtime by the website
 and are not in the sprite. The snapshotter cannot ask for them while rendering, so every composed
 icon the key samples use is added as soon as the style has loaded.
 */
private final class StyleImages: NSObject, MLNMapSnapshotterDelegate, @unchecked Sendable {
    private let composer: SpriteComposer
    var composites: [String] = []

    init(composer: SpriteComposer) {
        self.composer = composer
    }

    func mapSnapshotter(_ snapshotter: MLNMapSnapshotter, didFinishLoading style: MLNStyle) {
        for (name, image) in composer.images(for: composites) {
            style.setImage(image, forName: name)
        }
    }
}

private final class Wanted: @unchecked Sendable {
    var value = true
}

private final class Once: @unchecked Sendable {
    private var done = false

    /// True for the first caller only; everything runs on the main thread.
    func claim() -> Bool {
        if done {
            return false
        }
        done = true
        return true
    }
}
