// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation

/**
 Icons the style asks for but the sprite does not contain, composed from sprite icons, ported from
 the OpenRailwayMap website (`generateImage`, `loadImages` and `layoutImages` in proxy/js/ui.js) and
 identical to the Android app's `ComposedImage`.

 An id such as `fi/t-270|fi/t-271-top-{1}` stacks several sprite icons; each part after the first
 may carry a position (`@center`, `@bottom`, `@top`, `@right`, `@left`, default centre) relative to
 what has been composed so far. A request for `sdf:<id>` wants the SDF variant of the same id,
 composed from the `sdf:` icons of the parts. Sizes are in sprite pixels.

 This type only parses ids and computes the layout; drawing happens in the app.
 */
public enum ComposedImage {
    public static let sdfPrefix = "sdf:"

    public enum Position: String, Sendable {
        case center, bottom, top, right, left
    }

    public struct Part: Hashable, Sendable {
        public let id: String
        public let position: Position

        public init(_ id: String, _ position: Position) {
            self.id = id
            self.position = position
        }
    }

    /// One icon of the sprite sheet (an entry of `symbols*.json`).
    public struct SpriteImage: Hashable, Sendable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        public let pixelRatio: Double
        public let sdf: Bool

        public init(x: Int, y: Int, width: Int, height: Int, pixelRatio: Double, sdf: Bool) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.pixelRatio = pixelRatio
            self.sdf = sdf
        }
    }

    /**
     A part placed in the composed image: `x`/`y` is the top left corner of the normal icon (may be
     a half pixel, as on the website), `sdfX`/`sdfY` that of its larger SDF icon.
     */
    public struct Placed: Hashable, Sendable {
        public let part: Part
        public let image: SpriteImage
        public let sdfImage: SpriteImage
        public let x: Double
        public let y: Double
        public let sdfX: Int
        public let sdfY: Int
    }

    public struct Layout: Hashable, Sendable {
        public let width: Double
        public let height: Double
        public let images: [Placed]

        /// Bitmap size: a canvas truncates a fractional size, as the website's canvas does.
        public var pixelWidth: Int {
            Int(width)
        }

        public var pixelHeight: Int {
            Int(height)
        }

        public var pixelRatio: Double {
            images[0].image.pixelRatio
        }
    }

    /// The id without an `sdf:` prefix; both variants of a composed image are registered under it.
    public static func rawId(_ requested: String) -> String {
        requested.hasPrefix(sdfPrefix) ? String(requested.dropFirst(sdfPrefix.count)) : requested
    }

    public static func isSdf(_ requested: String) -> Bool {
        requested.hasPrefix(sdfPrefix)
    }

    /// Whether a string looks like a composed icon id (stacked or positioned), as opposed to a plain sprite icon.
    public static func isComposite(_ value: String) -> Bool {
        value.contains("|") || value.contains("@")
    }

    /// The parts of a raw id, or nil when a part cannot be parsed (the website throws).
    public static func parse(_ rawId: String) -> [Part]? {
        var parts: [Part] = []
        for imageId in rawId.split(separator: "|", omittingEmptySubsequences: false) {
            guard let match = String(imageId).wholeMatch(of: #/([^@]+)(@(center|bottom|top|right|left))?/#) else {
                return nil
            }
            let position = match.3.flatMap { Position(rawValue: String($0)) } ?? .center
            parts.append(Part(String(match.1), position))
        }
        return parts
    }

    /// Sprite index from a `symbols*.json` file.
    public static func parseSprite(_ json: JSON) -> [String: SpriteImage] {
        var result: [String: SpriteImage] = [:]
        for (name, entry) in json.object ?? [:] {
            guard let x = entry["x"]?.double, let y = entry["y"]?.double,
                  let width = entry["width"]?.double, let height = entry["height"]?.double else {
                continue
            }
            result[name] = SpriteImage(
                x: Int(x),
                y: Int(y),
                width: Int(width),
                height: Int(height),
                pixelRatio: entry["pixelRatio"]?.double ?? 1,
                sdf: entry["sdf"]?.bool ?? false
            )
        }
        return result
    }

    /// Layout for a raw id, or nil when it cannot be parsed or a part (or its SDF icon) is not in the sprite.
    public static func layout(_ rawId: String, sprite: [String: SpriteImage]) -> Layout? {
        guard let parts = parse(rawId) else {
            return nil
        }
        return layout(parts: parts, sprite: sprite)
    }

    public static func layout(parts: [Part], sprite: [String: SpriteImage]) -> Layout? {
        guard !parts.isEmpty else {
            return nil
        }
        var images: [SpriteImage] = []
        var sdfImages: [SpriteImage] = []
        for part in parts {
            guard let image = sprite[part.id], let sdfImage = sprite[sdfPrefix + part.id] else {
                return nil
            }
            images.append(image)
            sdfImages.append(sdfImage)
        }

        // Ignore position of first image. The width and height grow as more images are composed.
        var width = Double(images[0].width)
        var height = Double(images[0].height)

        // Top left corner of each image.
        var xs = [Double](repeating: 0, count: parts.count)
        var ys = [Double](repeating: 0, count: parts.count)

        // Offset of the top left corner of the composed image, so images can be added to the top or
        // left without moving the images placed before.
        var globalX = 0.0
        var globalY = 0.0

        for i in parts.indices.dropFirst() {
            let w = Double(images[i].width)
            let h = Double(images[i].height)
            switch parts[i].position {
            case .center:
                xs[i] = globalX + width / 2 - w / 2
                ys[i] = globalY + height / 2 - h / 2
                width = max(width, w)
                height = max(height, h)
            case .bottom:
                xs[i] = globalX + width / 2 - w / 2
                ys[i] = globalY + height
                width = max(width, w)
                height += h
            case .top:
                xs[i] = globalX + width / 2 - w / 2
                ys[i] = globalY - h
                width = max(width, w)
                height += h
            case .right:
                xs[i] = globalX + width
                ys[i] = globalY + height / 2 - h / 2
                width += w
                height = max(height, h)
            case .left:
                // Upstream places it half its width to the left, not its full width.
                xs[i] = globalX - w / 2
                ys[i] = globalY + height / 2 - h / 2
                width += w
                height = max(height, h)
            }
            globalX = min(globalX, xs[i])
            globalY = min(globalY, ys[i])
        }

        // SDF images are larger than the normal images due to padding pixels.
        for i in parts.indices {
            width = max(width, xs[i] - globalX + Double(sdfImages[i].width))
            height = max(height, ys[i] - globalY + Double(sdfImages[i].height))
        }
        for i in parts.indices {
            globalX = min(globalX, xs[i] + Double(images[i].width) / 2 - Double(sdfImages[i].width) / 2)
            globalY = min(globalY, ys[i] + Double(images[i].height) / 2 - Double(sdfImages[i].height) / 2)
        }

        let placed = parts.indices.map { i -> Placed in
            let x = xs[i] - globalX
            let y = ys[i] - globalY
            return Placed(
                part: parts[i],
                image: images[i],
                sdfImage: sdfImages[i],
                x: x,
                y: y,
                sdfX: Int((x + Double(images[i].width) / 2 - Double(sdfImages[i].width) / 2).rounded(.down)),
                sdfY: Int((y + Double(images[i].height) / 2 - Double(sdfImages[i].height) / 2).rounded(.down))
            )
        }
        return Layout(width: width, height: height, images: placed)
    }

    /// Composed icon ids among the string values of a JSON tree, such as legend.json (feature keys are skipped).
    public static func composites(_ json: JSON) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func walk(_ value: JSON) {
            switch value {
            case .object(let values):
                for key in values.keys.sorted() where key != "keys" {
                    walk(values[key]!)
                }
            case .array(let values):
                values.forEach(walk)
            case .string(let text):
                if isComposite(text) && seen.insert(text).inserted {
                    result.append(text)
                }
            default:
                break
            }
        }
        walk(json)
        return result
    }

    /**
     The sprite icons (normal and SDF) that `composites` are made of, plus the other values of icons
     with a `{value}` placeholder (e.g. every `fi/t-271-top-{n}` when one is used), which the map data
     combines in ways the legend does not list.
     */
    public static func components(_ composites: [String], sprite: [String: SpriteImage]) -> Set<SpriteImage> {
        var names = Set(composites.flatMap { parse($0) ?? [] }.map(\.id).filter { sprite[$0] != nil })
        let families = Set(names.filter { $0.contains("{") }.map(placeholderFamily))
        if !families.isEmpty {
            for name in sprite.keys where !isSdf(name) && name.contains("{") && families.contains(placeholderFamily(name)) {
                names.insert(name)
            }
        }
        return Set(names.flatMap { [sprite[$0], sprite[sdfPrefix + $0]].compactMap { $0 } })
    }

    private static func placeholderFamily(_ name: String) -> String {
        name.replacing(#/\{[^}]+\}/#, with: "{}")
    }

    /**
     The composed SDF image: per pixel the largest distance value (alpha) of the SDF icons covering it.

     - Parameter alphas: alpha channel of each placed part's SDF icon, row by row, in `Layout.images` order
     - Returns: alpha per pixel of the `pixelWidth` x `pixelHeight` image, row by row
     */
    public static func composeSdf(_ layout: Layout, alphas: [[UInt8]]) -> [UInt8] {
        let width = layout.pixelWidth
        let height = layout.pixelHeight
        var result = [UInt8](repeating: 0, count: width * height)
        for (index, placed) in layout.images.enumerated() {
            let source = alphas[index]
            let sw = placed.sdfImage.width
            let sh = placed.sdfImage.height
            for y in stride(from: max(0, placed.sdfY), to: min(height, placed.sdfY + sh), by: 1) {
                for x in stride(from: max(0, placed.sdfX), to: min(width, placed.sdfX + sw), by: 1) {
                    let value = source[(y - placed.sdfY) * sw + (x - placed.sdfX)]
                    let i = y * width + x
                    if value > result[i] {
                        result[i] = value
                    }
                }
            }
        }
        return result
    }
}
