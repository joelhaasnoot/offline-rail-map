// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation

/// Camera position as saved between launches.
public struct SavedCamera: Hashable, Sendable {
    public var lat: Double
    public var lon: Double
    public var zoom: Double

    public init(lat: Double, lon: Double, zoom: Double) {
        self.lat = lat
        self.lon = lon
        self.zoom = zoom
    }
}

/// Tiny wrapper around UserDefaults for the handful of things we persist; same keys as on Android.
public final class Prefs: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func string(_ key: String, _ fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    public var modeId: String {
        get { string("mode", "standard") }
        set { defaults.set(newValue, forKey: "mode") }
    }

    public var showConstruction: Bool {
        get { bool("showConstruction", true) }
        set { defaults.set(newValue, forKey: "showConstruction") }
    }

    public var showProposed: Bool {
        get { bool("showProposed", true) }
        set { defaults.set(newValue, forKey: "showProposed") }
    }

    public var showAbandoned: Bool {
        get { bool("showAbandoned", false) }
        set { defaults.set(newValue, forKey: "showAbandoned") }
    }

    public var showRazed: Bool {
        get { bool("showRazed", false) }
        set { defaults.set(newValue, forKey: "showRazed") }
    }

    public var electrificationLine: String {
        get { string("electrificationLine", "voltageFrequency") }
        set { defaults.set(newValue, forKey: "electrificationLine") }
    }

    public var trackLine: String {
        get { string("trackLine", "gauge") }
        set { defaults.set(newValue, forKey: "trackLine") }
    }

    public var stationLowZoomLabel: String {
        get { string("stationLowZoomLabel", "label") }
        set { defaults.set(newValue, forKey: "stationLowZoomLabel") }
    }

    /// Last camera position; nil when never saved.
    public var camera: SavedCamera? {
        get {
            guard defaults.object(forKey: "cam_lat") != nil else {
                return nil
            }
            return SavedCamera(
                lat: defaults.double(forKey: "cam_lat"),
                lon: defaults.double(forKey: "cam_lon"),
                zoom: defaults.double(forKey: "cam_zoom")
            )
        }
        set {
            if let camera = newValue {
                defaults.set(camera.lat, forKey: "cam_lat")
                defaults.set(camera.lon, forKey: "cam_lon")
                defaults.set(camera.zoom, forKey: "cam_zoom")
            } else {
                for key in ["cam_lat", "cam_lon", "cam_zoom"] {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }
}
