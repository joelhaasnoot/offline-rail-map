// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import XCTest
@testable import RailwayMapCore

final class JSONTests: XCTestCase {
    func testBooleansAndNumbersStayApart() throws {
        let json = try JSON(parsing: #"{"a":true,"b":1,"c":0,"d":false,"e":1.5,"f":null}"#)
        XCTAssertEqual(true, json["a"])
        XCTAssertEqual(1, json["b"])
        XCTAssertEqual(0, json["c"])
        XCTAssertEqual(false, json["d"])
        XCTAssertEqual(1.5, json["e"])
        XCTAssertEqual(.null, json["f"])
        XCTAssertNil(json["missing"])
    }

    func testSerialisationIsCompactAndStable() {
        let json: JSON = ["b": [1, 2.5, true, nil], "a": "x/y"]
        XCTAssertEqual(#"{"a":"x/y","b":[1,2.5,true,null]}"#, json.serialized())
    }

    func testMutationThroughSubscripts() {
        var layer: JSON = ["id": "a", "layout": ["visibility": "none"]]
        let original = layer
        layer["layout"]?["visibility"] = "visible"
        layer.remove("id")
        XCTAssertEqual(#"{"layout":{"visibility":"visible"}}"#, layer.serialized())
        XCTAssertEqual("a", original["id"]) // copies are independent
    }

    func testFeatureAttributesConvert() {
        XCTAssertEqual(true, JSON(foundation: NSNumber(value: true)))
        XCTAssertEqual(3, JSON(foundation: NSNumber(value: 3)))
        XCTAssertEqual("x", JSON(foundation: "x" as NSString))
        XCTAssertEqual(.null, JSON(foundation: nil))
    }

    func testGeoLinks() {
        XCTAssertEqual(SavedCamera(lat: 52.1, lon: 4.3, zoom: 17), GeoLink.parse(URL(string: "geo:52.1,4.3?z=17")!))
        XCTAssertEqual(SavedCamera(lat: 50.85, lon: 5.69, zoom: 14), GeoLink.parse(URL(string: "geo:0,0?q=50.85,5.69")!))
        XCTAssertEqual(SavedCamera(lat: -33.9, lon: 18.4, zoom: 14), GeoLink.parse(URL(string: "geo:-33.9,18.4")!))
        XCTAssertNil(GeoLink.parse(URL(string: "geo:0,0")!))
        XCTAssertNil(GeoLink.parse(URL(string: "https://example.com/52.1,4.3")!))
    }
}
