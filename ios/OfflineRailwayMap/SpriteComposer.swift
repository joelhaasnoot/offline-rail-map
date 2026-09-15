// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import ImageIO
import os
import RailwayMapCore
import UIKit

/**
 Draws the icons described by `ComposedImage` from the bundled sprite sheet, for the map's and the
 key's missing-image handling. An `sdf:` request gets the SDF variant as a template image, which
 MapLibre treats as SDF.

 MapLibre needs the image before the missing-image callback returns, so composing must be quick.
 Decoding the whole sheet is not (about 60 MB at 2x), so `warmUp` decodes it once in the background,
 keeps only the icons composed icons are made of and lets the sheet go.
 */
final class SpriteComposer: @unchecked Sendable {
    private static let log = Logger(subsystem: "app.offlinerailwaymap", category: "SpriteComposer")

    private let assets: MapAssets
    private let suffix: String
    private let lock = NSLock()
    private var spriteIndex: [String: ComposedImage.SpriteImage]?
    private var icons: [ComposedImage.SpriteImage: CGImage] = [:]
    private let composed = NSCache<NSString, UIImage>()
    private var failed = Set<String>()

    /// The composer for the sprite sheet MapLibre loads on this screen (`@2x` above scale 1).
    init(assets: MapAssets, screenScale: CGFloat) {
        self.assets = assets
        suffix = screenScale > 1 ? "@2x" : ""
        composed.totalCostLimit = 8 * 1024 * 1024
    }

    private var sprite: [String: ComposedImage.SpriteImage] {
        if let spriteIndex {
            return spriteIndex
        }
        let url = assets.root.appendingPathComponent("sprites/symbols\(suffix).json")
        let index = (try? JSON(contentsOf: url)).map(ComposedImage.parseSprite) ?? [:]
        spriteIndex = index
        return index
    }

    /// Decodes the icons used by the composed icons in legend.json. Call off the main thread.
    func warmUp() {
        let start = Date()
        guard let legend = try? JSON(contentsOf: assets.legend) else {
            return
        }
        lock.lock()
        let wanted = ComposedImage.components(ComposedImage.composites(legend), sprite: sprite).filter { icons[$0] == nil }
        lock.unlock()
        guard !wanted.isEmpty, let sheet = loadSheet() else {
            return
        }
        var decoded: [ComposedImage.SpriteImage: CGImage] = [:]
        for image in wanted {
            decoded[image] = Self.copy(image, from: sheet)
        }
        lock.lock()
        icons.merge(decoded) { current, _ in current }
        lock.unlock()
        Self.log.debug("decoded \(wanted.count) icons in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    /// The image for a requested name (with or without `sdf:`), or nil if it cannot be composed.
    func image(for requested: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        if let image = composed.object(forKey: requested as NSString) {
            return image
        }
        let id = ComposedImage.rawId(requested)
        if failed.contains(id) {
            return nil
        }
        guard let layout = ComposedImage.layout(id, sprite: sprite), let images = draw(layout) else {
            Self.log.warning("cannot compose missing image \(requested)")
            failed.insert(id)
            return nil
        }
        let cost = layout.pixelWidth * layout.pixelHeight * 5
        composed.setObject(images.normal, forKey: id as NSString, cost: cost)
        composed.setObject(images.sdf, forKey: (ComposedImage.sdfPrefix + id) as NSString, cost: cost)
        return ComposedImage.isSdf(requested) ? images.sdf : images.normal
    }

    /// Both variants of every composed icon among `ids`, e.g. to add to a style up front.
    func images(for ids: [String]) -> [(name: String, image: UIImage)] {
        ids.flatMap { id -> [(name: String, image: UIImage)] in
            let raw = ComposedImage.rawId(id)
            return [raw, ComposedImage.sdfPrefix + raw].compactMap { name in image(for: name).map { (name, $0) } }
        }
    }

    // MARK: - Drawing (called with the lock held)

    private func draw(_ layout: ComposedImage.Layout) -> (normal: UIImage, sdf: UIImage)? {
        let width = layout.pixelWidth
        let height = layout.pixelHeight
        guard width > 0, height > 0 else {
            return nil
        }
        let scale = CGFloat(layout.pixelRatio)
        var loadedSheet: CGImage?
        func icon(_ entry: ComposedImage.SpriteImage) -> CGImage? {
            if let cached = icons[entry] {
                return cached
            }
            // Not warmed up (yet): decode the sheet for this icon.
            if loadedSheet == nil {
                loadedSheet = loadSheet()
            }
            guard let sheet = loadedSheet, let copied = Self.copy(entry, from: sheet) else {
                return nil
            }
            icons[entry] = copied
            return copied
        }

        // Normal icons drawn over each other at their (possibly half pixel) offsets, as the website's canvas does.
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .default
        for placed in layout.images {
            guard let image = icon(placed.image) else {
                return nil
            }
            // Core Graphics has its origin at the bottom left; layout offsets are from the top left.
            let rect = CGRect(
                x: placed.x,
                y: Double(height) - placed.y - Double(placed.image.height),
                width: Double(placed.image.width),
                height: Double(placed.image.height)
            )
            context.draw(image, in: rect)
        }
        guard let normal = context.makeImage() else {
            return nil
        }

        var alphas: [[UInt8]] = []
        for placed in layout.images {
            guard let image = icon(placed.sdfImage) else {
                return nil
            }
            alphas.append(Self.alphaChannel(image))
        }
        let distances = ComposedImage.composeSdf(layout, alphas: alphas)
        guard let sdf = Self.alphaImage(distances, width: width, height: height) else {
            return nil
        }
        return (
            UIImage(cgImage: normal, scale: scale, orientation: .up),
            UIImage(cgImage: sdf, scale: scale, orientation: .up).withRenderingMode(.alwaysTemplate)
        )
    }

    private func loadSheet() -> CGImage? {
        let url = assets.root.appendingPathComponent("sprites/symbols\(suffix).png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            Self.log.error("cannot decode sprites/symbols\(self.suffix).png")
            return nil
        }
        return sheet
    }

    /// A standalone copy of one sprite icon, so the decoded sheet can be released.
    private static func copy(_ entry: ComposedImage.SpriteImage, from sheet: CGImage) -> CGImage? {
        guard let cropped = sheet.cropping(to: CGRect(x: entry.x, y: entry.y, width: entry.width, height: entry.height)),
              let context = CGContext(
                  data: nil, width: entry.width, height: entry.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: entry.width, height: entry.height))
        return context.makeImage()
    }

    /// The alpha channel of an image, top row first.
    private static func alphaChannel(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        alpha.withUnsafeMutableBytes { buffer in
            // Bitmap memory starts with the top row, although drawing coordinates start at the bottom.
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return alpha
    }

    /// A black image whose alpha is `alpha` (top row first), the form MapLibre expects for SDF icons.
    private static func alphaImage(_ alpha: [UInt8], width: Int, height: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for (i, value) in alpha.enumerated() {
            rgba[i * 4 + 3] = value
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
