// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.map

import com.offlinerailmap.android.data.Prefs

/**
 * The map "styles" of the OpenRailwayMap web app. Each one is a set of global-state values
 * that the (single) upstream style reacts to; see `knownStyles` in the web UI.
 */
enum class MapMode(val id: String, val label: String, val globalState: Map<String, Any>) {
    STANDARD(
        "standard", "Infrastructure",
        mapOf(
            "tracks" to "usage", "stations" to "station", "pois" to "standard", "turntables" to "plain",
            "platforms" to "plain", "substations" to "none", "boxes" to "none", "catenaries" to "none",
            "switches" to "plain", "signals" to "none",
        ),
    ),
    SPEED(
        "speed", "Speed",
        mapOf(
            "tracks" to "speed", "stations" to "none", "pois" to "none", "turntables" to "none",
            "platforms" to "none", "substations" to "none", "boxes" to "none", "catenaries" to "none",
            "switches" to "none", "signals" to "speed",
        ),
    ),
    SIGNALS(
        "signals", "Train protection",
        mapOf(
            "tracks" to "train_protection", "stations" to "none", "pois" to "signals", "turntables" to "none",
            "platforms" to "none", "substations" to "none", "boxes" to "plain", "catenaries" to "none",
            "switches" to "none", "signals" to "signals",
        ),
    ),
    ELECTRIFICATION(
        "electrification", "Electrification",
        mapOf(
            "tracks" to "electrification", "stations" to "none", "pois" to "electrification", "turntables" to "none",
            "platforms" to "none", "substations" to "plain", "boxes" to "none", "catenaries" to "plain",
            "switches" to "none", "signals" to "electrification",
        ),
    ),
    TRACK(
        "track", "Gauge",
        mapOf(
            "tracks" to "track", "stations" to "none", "pois" to "none", "turntables" to "none",
            "platforms" to "none", "substations" to "none", "boxes" to "none", "catenaries" to "none",
            "switches" to "none", "signals" to "none",
        ),
    ),
    OPERATOR(
        "operator", "Operator",
        mapOf(
            "tracks" to "operator", "stations" to "operator", "pois" to "operator", "turntables" to "none",
            "platforms" to "none", "substations" to "none", "boxes" to "operator", "catenaries" to "none",
            "switches" to "none", "signals" to "none",
        ),
    );

    companion object {
        fun fromId(id: String): MapMode = entries.firstOrNull { it.id == id } ?: STANDARD
    }
}

/** User-configurable options that map onto upstream global-state keys. */
data class MapOptions(
    val showConstruction: Boolean = true,
    val showProposed: Boolean = true,
    val showAbandoned: Boolean = false,
    val showRazed: Boolean = false,
    /** voltageFrequency | maximumCurrent | power */
    val electrificationLine: String = "voltageFrequency",
    /** gauge | loadingGauge | trackClass */
    val trackLine: String = "gauge",
    /** label | name | none */
    val stationLowZoomLabel: String = "label",
) {
    fun save() {
        Prefs.showConstruction = showConstruction
        Prefs.showProposed = showProposed
        Prefs.showAbandoned = showAbandoned
        Prefs.showRazed = showRazed
        Prefs.electrificationLine = electrificationLine
        Prefs.trackLine = trackLine
        Prefs.stationLowZoomLabel = stationLowZoomLabel
    }

    fun toGlobalState(): Map<String, Any> = mapOf(
        "showConstructionInfrastructure" to showConstruction,
        "showProposedInfrastructure" to showProposed,
        "showAbandonedInfrastructure" to showAbandoned,
        "showRazedInfrastructure" to showRazed,
        "electrificationRailwayLine" to electrificationLine,
        "trackRailwayLine" to trackLine,
        "stationLowZoomLabel" to stationLowZoomLabel,
    )

    companion object {
        fun fromPrefs() = MapOptions(
            showConstruction = Prefs.showConstruction,
            showProposed = Prefs.showProposed,
            showAbandoned = Prefs.showAbandoned,
            showRazed = Prefs.showRazed,
            electrificationLine = Prefs.electrificationLine,
            trackLine = Prefs.trackLine,
            stationLowZoomLabel = Prefs.stationLowZoomLabel,
        )
    }
}
