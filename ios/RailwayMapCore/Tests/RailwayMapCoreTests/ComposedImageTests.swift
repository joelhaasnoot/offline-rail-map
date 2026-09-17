// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import XCTest
@testable import RailwayMapCore

private typealias SpriteImage = ComposedImage.SpriteImage

final class ComposedImageTests: XCTestCase {
    /// Icons a (10x20), b (15x6) and c (4x4); their SDF icons have 3 pixels of padding.
    private let sprite: [String: SpriteImage] = {
        var result: [String: SpriteImage] = [:]
        for (name, size) in [("a", (10, 20)), ("b", (15, 6)), ("c", (4, 4))] {
            result[name] = SpriteImage(x: 0, y: 0, width: size.0, height: size.1, pixelRatio: 1, sdf: false)
            result["sdf:\(name)"] = SpriteImage(x: 0, y: 0, width: size.0 + 6, height: size.1 + 6, pixelRatio: 1, sdf: true)
        }
        return result
    }()

    /// "width height x,y,sdfX,sdfY;..." as the website's layoutImages computes it.
    private func describe(_ layout: ComposedImage.Layout?) -> String {
        guard let layout else {
            return "nil"
        }
        let images = layout.images.map { "\(num($0.x)),\(num($0.y)),\($0.sdfX),\($0.sdfY)" }.joined(separator: ";")
        return "\(num(layout.width)) \(num(layout.height)) \(images)"
    }

    /// JavaScript number formatting: no ".0" on whole numbers.
    private func num(_ value: Double) -> String {
        value.rounded(.down) == value ? String(Int64(value)) : String(value)
    }

    // Expected values below were produced by running upstream's loadImages/layoutImages in Node.

    func testSingleImageIsPaddedToItsSdfSizeAndIgnoresPosition() {
        XCTAssertEqual("16 26 3,3,0,0", describe(ComposedImage.layout("a", sprite: sprite)))
        XCTAssertEqual("16 26 3,3,0,0", describe(ComposedImage.layout("a@top", sprite: sprite)))
    }

    func testCenterIsTheDefaultPosition() {
        XCTAssertEqual("21 26 5.5,3,2,0;3,10,0,7", describe(ComposedImage.layout("a|b", sprite: sprite)))
        XCTAssertEqual("21 26 5.5,3,2,0;3,10,0,7", describe(ComposedImage.layout("a|b@center", sprite: sprite)))
    }

    func testBottomAndTopStackVertically() {
        XCTAssertEqual("21 32 5.5,3,2,0;3,23,0,20", describe(ComposedImage.layout("a|b@bottom", sprite: sprite)))
        XCTAssertEqual("21 32 5.5,9,2,6;3,3,0,0", describe(ComposedImage.layout("a|b@top", sprite: sprite)))
    }

    func testRightAndLeftStackHorizontallyWithUpstreamsHalfWidthLeftOffset() {
        XCTAssertEqual("31 26 3,3,0,0;13,10,10,7", describe(ComposedImage.layout("a|b@right", sprite: sprite)))
        XCTAssertEqual("25 26 10.5,3,7,0;3,10,0,7", describe(ComposedImage.layout("a|b@left", sprite: sprite)))
    }

    func testLaterPartsArePlacedRelativeToEverythingBefore() {
        XCTAssertEqual("23 32 7.5,9,4,6;5,3,2,0;3,14,0,11", describe(ComposedImage.layout("a|b@top|c@left", sprite: sprite)))
        XCTAssertEqual(
            "35 30 8,10,5,7;3,3,0,0;13.5,23,10,20;28,13,25,10",
            describe(ComposedImage.layout("b|a@left|c@bottom|c@right", sprite: sprite))
        )
    }

    func testParsesPartsAndPositions() {
        XCTAssertEqual(
            [ComposedImage.Part("fi/t-270", .center), ComposedImage.Part("fi/t-271-top-{1}", .center)],
            ComposedImage.parse("fi/t-270|fi/t-271-top-{1}")
        )
        XCTAssertEqual(
            [ComposedImage.Part("gb/route-feather-unknown", .center), ComposedImage.Part("gb/route-theatre-{U}", .bottom)],
            ComposedImage.parse("gb/route-feather-unknown|gb/route-theatre-{U}@bottom")
        )
    }

    func testRejectsIdsTheWebsiteCannotParse() {
        XCTAssertNil(ComposedImage.parse(""))
        XCTAssertNil(ComposedImage.parse("a|"))
        XCTAssertNil(ComposedImage.parse("a@middle"))
        XCTAssertNil(ComposedImage.parse("a@bottom@top"))
    }

    func testMissingPartsOrSdfIconsGiveNoLayout() {
        XCTAssertNil(ComposedImage.layout("a|zzz@bottom", sprite: sprite))
        var withoutSdfB = sprite
        withoutSdfB["sdf:b"] = nil
        XCTAssertNil(ComposedImage.layout("a|b", sprite: withoutSdfB))
        XCTAssertNil(ComposedImage.layout("a@", sprite: sprite))
    }

    func testCompositeIds() {
        XCTAssertTrue(ComposedImage.isComposite("fi/t-270|fi/t-270-{2}"))
        XCTAssertTrue(ComposedImage.isComposite("au/LightRail/signals/PI/stop@bottom"))
        XCTAssertFalse(ComposedImage.isComposite("de/vr0"))
        XCTAssertFalse(ComposedImage.isComposite("signal"))
    }

    func testFindsCompositesInLegendJsonButNotInFeatureKeys() throws {
        let legend = try JSON(parsing: """
            {"signals":{"sourceLayers":{"s":{"features":[
              {"legend":"x","properties":{"railway":"signal","feature0":"a|b@bottom"},
               "variants":[{"properties":{"feature0":"c@top"}}],"keys":["signala|b"]},
              {"legend":"y","properties":{"feature0":"a"}}
            ]}}}}
            """)
        XCTAssertEqual(["a|b@bottom", "c@top"], Set(ComposedImage.composites(legend)))
    }

    func testComponentsIncludeSdfIconsAndOtherPlaceholderValues() {
        var icons = sprite
        icons["d-{1}"] = SpriteImage(x: 1, y: 0, width: 1, height: 1, pixelRatio: 1, sdf: false)
        icons["sdf:d-{1}"] = SpriteImage(x: 2, y: 0, width: 1, height: 1, pixelRatio: 1, sdf: true)
        icons["d-{2}"] = SpriteImage(x: 3, y: 0, width: 1, height: 1, pixelRatio: 1, sdf: false)
        icons["sdf:d-{2}"] = SpriteImage(x: 4, y: 0, width: 1, height: 1, pixelRatio: 1, sdf: true)
        icons["e-{1}"] = SpriteImage(x: 5, y: 0, width: 1, height: 1, pixelRatio: 1, sdf: false)
        icons["sdf:e-{1}"] = SpriteImage(x: 6, y: 0, width: 1, height: 1, pixelRatio: 1, sdf: true)
        let components = ComposedImage.components(["a|d-{1}@bottom", "zzz|b", "@"], sprite: icons)
        let expected = ["a", "sdf:a", "b", "sdf:b", "d-{1}", "sdf:d-{1}", "d-{2}", "sdf:d-{2}"].map { icons[$0]! }
        XCTAssertEqual(Set(expected), components)
    }

    func testSdfPrefix() {
        XCTAssertTrue(ComposedImage.isSdf("sdf:a|b@bottom"))
        XCTAssertFalse(ComposedImage.isSdf("a|b@bottom"))
        XCTAssertEqual("a|b@bottom", ComposedImage.rawId("sdf:a|b@bottom"))
        XCTAssertEqual("a|b@bottom", ComposedImage.rawId("a|b@bottom"))
    }

    func testComposedSdfTakesTheLargestDistanceValue() {
        let small: [String: SpriteImage] = [
            "p": SpriteImage(x: 0, y: 0, width: 1, height: 1, pixelRatio: 1, sdf: false),
            "sdf:p": SpriteImage(x: 0, y: 0, width: 3, height: 3, pixelRatio: 1, sdf: true),
            "q": SpriteImage(x: 0, y: 0, width: 1, height: 1, pixelRatio: 1, sdf: false),
            "sdf:q": SpriteImage(x: 0, y: 0, width: 3, height: 3, pixelRatio: 1, sdf: true),
        ]
        let layout = ComposedImage.layout("p|q@right", sprite: small)!
        XCTAssertEqual("4 3 1,1,0,0;2,1,1,0", describe(layout))
        let p: [UInt8] = [10, 20, 30, 40, 200, 60, 70, 80, 90]
        let q: [UInt8] = [100, 5, 5, 5, 250, 5, 5, 5, 5]
        XCTAssertEqual(
            [
                10, 100, 30, 5,
                40, 200, 250, 5,
                70, 80, 90, 5,
            ],
            ComposedImage.composeSdf(layout, alphas: [p, q])
        )
    }

    func testParsesSpriteIndex() throws {
        let parsed = ComposedImage.parseSprite(try JSON(parsing: """
            {"a":{"x":1,"y":2,"width":3,"height":4,"pixelRatio":2},"sdf:a":{"x":5,"y":6,"width":7,"height":8,"pixelRatio":2,"sdf":true}}
            """))
        XCTAssertEqual(SpriteImage(x: 1, y: 2, width: 3, height: 4, pixelRatio: 2, sdf: false), parsed["a"])
        XCTAssertEqual(SpriteImage(x: 5, y: 6, width: 7, height: 8, pixelRatio: 2, sdf: true), parsed["sdf:a"])
    }

    /// The real catalogue: every icon a legend composite needs is found.
    func testLegendCatalogueComponentsCoverEveryLegendComposite() throws {
        let assets = StyleBuilderTests.assets
        let legend = try JSON(contentsOf: assets.legend)
        let assetSprite = ComposedImage.parseSprite(try JSON(contentsOf: assets.root.appendingPathComponent("sprites/symbols@2x.json")))
        let composites = ComposedImage.composites(legend)
        XCTAssertGreaterThan(composites.count, 100)
        let components = ComposedImage.components(composites, sprite: assetSprite)
        for id in composites {
            let layout = try XCTUnwrap(ComposedImage.layout(id, sprite: assetSprite), id)
            for placed in layout.images {
                XCTAssertTrue(components.contains(placed.image) && components.contains(placed.sdfImage), id)
            }
        }
    }

    /// Every composed icon in legend.json, against the website's layout (see pipeline/composed_image_golden.mjs).
    func testMatchesWebsiteLayoutForEveryLegendIcon() throws {
        let assets = StyleBuilderTests.assets
        let goldenDir = assets.root
            .deletingLastPathComponent() // main
            .deletingLastPathComponent() // src
            .appendingPathComponent("test/resources/composed-image")
        for suffix in ["", "@2x"] {
            let assetSprite = ComposedImage.parseSprite(try JSON(contentsOf: assets.root.appendingPathComponent("sprites/symbols\(suffix).json")))
            let golden = try String(contentsOf: goldenDir.appendingPathComponent("golden\(suffix).tsv"), encoding: .utf8)
                .split(separator: "\n")
            XCTAssertGreaterThan(golden.count, 100, "golden\(suffix).tsv is empty")
            for line in golden {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                let layout = ComposedImage.layout(fields[0], sprite: assetSprite)
                XCTAssertEqual("\(fields[1]) \(fields[2]) \(fields[3])", describe(layout), "\(fields[0])\(suffix)")
                XCTAssertEqual(suffix.isEmpty ? 1 : 2, layout?.pixelRatio, "\(fields[0])\(suffix) pixel ratio")
            }
        }
    }
}
