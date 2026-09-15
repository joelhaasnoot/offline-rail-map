// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation

/**
 The map "styles" of the OpenRailwayMap web app. Each one is a set of global-state values
 that the (single) upstream style reacts to; see `knownStyles` in the web UI.
 */
public enum MapMode: String, CaseIterable, Identifiable, Sendable {
    case standard
    case speed
    case signals
    case electrification
    case track
    case `operator`

    public var id: String {
        rawValue
    }

    public static func fromId(_ id: String) -> MapMode {
        MapMode(rawValue: id) ?? .standard
    }

    public var label: String {
        switch self {
        case .standard:
            return "Infrastructure"
        case .speed:
            return "Speed"
        case .signals:
            return "Train protection"
        case .electrification:
            return "Electrification"
        case .track:
            return "Gauge"
        case .operator:
            return "Operator"
        }
    }

    public var globalState: [String: JSON] {
        switch self {
        case .standard:
            return [
                "tracks": "usage", "stations": "station", "pois": "standard", "turntables": "plain",
                "platforms": "plain", "substations": "none", "boxes": "none", "catenaries": "none",
                "switches": "plain", "signals": "none",
            ]
        case .speed:
            return [
                "tracks": "speed", "stations": "none", "pois": "none", "turntables": "none",
                "platforms": "none", "substations": "none", "boxes": "none", "catenaries": "none",
                "switches": "none", "signals": "speed",
            ]
        case .signals:
            return [
                "tracks": "train_protection", "stations": "none", "pois": "signals", "turntables": "none",
                "platforms": "none", "substations": "none", "boxes": "plain", "catenaries": "none",
                "switches": "none", "signals": "signals",
            ]
        case .electrification:
            return [
                "tracks": "electrification", "stations": "none", "pois": "electrification", "turntables": "none",
                "platforms": "none", "substations": "plain", "boxes": "none", "catenaries": "plain",
                "switches": "none", "signals": "electrification",
            ]
        case .track:
            return [
                "tracks": "track", "stations": "none", "pois": "none", "turntables": "none",
                "platforms": "none", "substations": "none", "boxes": "none", "catenaries": "none",
                "switches": "none", "signals": "none",
            ]
        case .operator:
            return [
                "tracks": "operator", "stations": "operator", "pois": "operator", "turntables": "none",
                "platforms": "none", "substations": "none", "boxes": "operator", "catenaries": "none",
                "switches": "none", "signals": "none",
            ]
        }
    }
}

/// User-configurable options that map onto upstream global-state keys.
public struct MapOptions: Hashable, Sendable {
    public var showConstruction = true
    public var showProposed = true
    public var showAbandoned = false
    public var showRazed = false
    /// voltageFrequency | maximumCurrent | power
    public var electrificationLine = "voltageFrequency"
    /// gauge | loadingGauge | trackClass
    public var trackLine = "gauge"
    /// label | name | none
    public var stationLowZoomLabel = "label"

    public init() {}

    public func toGlobalState() -> [String: JSON] {
        [
            "showConstructionInfrastructure": .bool(showConstruction),
            "showProposedInfrastructure": .bool(showProposed),
            "showAbandonedInfrastructure": .bool(showAbandoned),
            "showRazedInfrastructure": .bool(showRazed),
            "electrificationRailwayLine": .string(electrificationLine),
            "trackRailwayLine": .string(trackLine),
            "stationLowZoomLabel": .string(stationLowZoomLabel),
        ]
    }

    public func save(to prefs: Prefs) {
        prefs.showConstruction = showConstruction
        prefs.showProposed = showProposed
        prefs.showAbandoned = showAbandoned
        prefs.showRazed = showRazed
        prefs.electrificationLine = electrificationLine
        prefs.trackLine = trackLine
        prefs.stationLowZoomLabel = stationLowZoomLabel
    }

    public static func from(_ prefs: Prefs) -> MapOptions {
        var options = MapOptions()
        options.showConstruction = prefs.showConstruction
        options.showProposed = prefs.showProposed
        options.showAbandoned = prefs.showAbandoned
        options.showRazed = prefs.showRazed
        options.electrificationLine = prefs.electrificationLine
        options.trackLine = prefs.trackLine
        options.stationLowZoomLabel = prefs.stationLowZoomLabel
        return options
    }
}
