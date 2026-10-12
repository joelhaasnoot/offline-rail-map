// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation

/**
 The map views of the OpenRailwayMap web app. Each one is a set of global-state values that the
 (single) upstream style reacts to: `knownStyles` in the web UI, which prepare_style.py copies into
 legend.json for the tests to compare with. `pois` and `signals` are lists of categories.
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
                "tracks": "usage", "stations": "station",
                "pois": ["radio", "facility", "equipment", "level_crossing", "train_protection"],
                "platforms": "plain", "substations": "none", "boxes": "none", "catenaries": "none",
                "switches": "plain", "signals": [],
            ]
        case .speed:
            return [
                "tracks": "speed", "stations": "none", "pois": [],
                "platforms": "none", "substations": "none", "boxes": "none", "catenaries": "none",
                "switches": "none", "signals": ["speed"],
            ]
        case .signals:
            return [
                "tracks": "train_protection", "stations": "none", "pois": ["vacancy_detection", "train_protection"],
                "platforms": "none", "substations": "none", "boxes": "plain", "catenaries": "none",
                "switches": "none",
                "signals": ["main", "distant", "train_protection", "station", "radio", "shunting", "other"],
            ]
        case .electrification:
            return [
                "tracks": "voltage_frequency", "stations": "none", "pois": ["electrical_equipment"],
                "platforms": "none", "substations": "plain", "boxes": "none", "catenaries": "plain",
                "switches": "none", "signals": ["electricity"],
            ]
        case .track:
            return [
                "tracks": "gauge", "stations": "none", "pois": [],
                "platforms": "none", "substations": "none", "boxes": "none", "catenaries": "none",
                "switches": "none", "signals": [],
            ]
        case .operator:
            return [
                "tracks": "operator", "stations": "operator", "pois": ["operator"],
                "platforms": "none", "substations": "none", "boxes": "operator", "catenaries": "none",
                "switches": "none", "signals": [],
            ]
        }
    }
}

/// User-configurable options that map onto upstream global-state keys.
public struct MapOptions: Hashable, Sendable {
    public var showConstruction = true
    public var showProposed = false
    public var showAbandoned = false
    public var showRazed = false
    /// voltageFrequency | maximumCurrent | power
    public var electrificationLine = "voltageFrequency"
    /// gauge | loadingGauge | trackClass | passengerLines
    public var trackLine = "gauge"
    /// trainProtection | radio
    public var signalsLine = "trainProtection"
    /// label | name | none
    public var stationLowZoomLabel = "label"

    public init() {}

    /// The global state these options set in `mode`, on top of the mode's own.
    public func toGlobalState(mode: MapMode) -> [String: JSON] {
        var state: [String: JSON] = [
            "showConstructionInfrastructure": .bool(showConstruction),
            "showProposedInfrastructure": .bool(showProposed),
            "showAbandonedInfrastructure": .bool(showAbandoned),
            "showRazedInfrastructure": .bool(showRazed),
            "stationLowZoomLabel": .string(stationLowZoomLabel),
        ]
        // The line colouring of these views; the web app offers them as `tracks` values.
        switch mode {
        case .electrification:
            switch electrificationLine {
            case "maximumCurrent":
                state["tracks"] = "maximum_current"
            case "power":
                state["tracks"] = "power"
            default:
                state["tracks"] = "voltage_frequency"
            }
        case .track:
            switch trackLine {
            case "loadingGauge":
                state["tracks"] = "loading_gauge"
            case "trackClass":
                state["tracks"] = "track_class"
            case "passengerLines":
                state["tracks"] = "passenger_lines"
            default:
                state["tracks"] = "gauge"
            }
        case .signals:
            switch signalsLine {
            case "radio":
                state["tracks"] = "radio"
            default:
                state["tracks"] = "train_protection"
            }
        default:
            break
        }
        return state
    }

    public func save(to prefs: Prefs) {
        prefs.showConstruction = showConstruction
        prefs.showProposed = showProposed
        prefs.showAbandoned = showAbandoned
        prefs.showRazed = showRazed
        prefs.electrificationLine = electrificationLine
        prefs.trackLine = trackLine
        prefs.signalsLine = signalsLine
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
        options.signalsLine = prefs.signalsLine
        options.stationLowZoomLabel = prefs.stationLowZoomLabel
        return options
    }
}
