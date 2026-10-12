// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.map

import com.offlinerailmap.android.data.Prefs

/**
 * The map views of the OpenRailwayMap web app. Each one is a set of global-state values that the
 * (single) upstream style reacts to: `knownStyles` in the web UI, which prepare_style.py copies into
 * legend.json for the tests to compare with. `pois` and `signals` are lists of categories.
 */
enum class MapMode(val id: String, val label: String, val globalState: Map<String, Any>) {
    STANDARD(
        "standard", "Infrastructure",
        mapOf(
            "tracks" to "usage", "stations" to "station",
            "pois" to listOf("radio", "facility", "equipment", "level_crossing", "train_protection"),
            "platforms" to "plain", "substations" to "none", "boxes" to "none", "catenaries" to "none",
            "switches" to "plain", "signals" to emptyList<String>(),
        ),
    ),
    SPEED(
        "speed", "Speed",
        mapOf(
            "tracks" to "speed", "stations" to "none", "pois" to emptyList<String>(),
            "platforms" to "none", "substations" to "none", "boxes" to "none", "catenaries" to "none",
            "switches" to "none", "signals" to listOf("speed"),
        ),
    ),
    SIGNALS(
        "signals", "Train protection",
        mapOf(
            "tracks" to "train_protection", "stations" to "none", "pois" to listOf("vacancy_detection", "train_protection"),
            "platforms" to "none", "substations" to "none", "boxes" to "plain", "catenaries" to "none",
            "switches" to "none",
            "signals" to listOf("main", "distant", "train_protection", "station", "radio", "shunting", "other"),
        ),
    ),
    ELECTRIFICATION(
        "electrification", "Electrification",
        mapOf(
            "tracks" to "voltage_frequency", "stations" to "none", "pois" to listOf("electrical_equipment"),
            "platforms" to "none", "substations" to "plain", "boxes" to "none", "catenaries" to "plain",
            "switches" to "none", "signals" to listOf("electricity"),
        ),
    ),
    TRACK(
        "track", "Gauge",
        mapOf(
            "tracks" to "gauge", "stations" to "none", "pois" to emptyList<String>(),
            "platforms" to "none", "substations" to "none", "boxes" to "none", "catenaries" to "none",
            "switches" to "none", "signals" to emptyList<String>(),
        ),
    ),
    OPERATOR(
        "operator", "Operator",
        mapOf(
            "tracks" to "operator", "stations" to "operator", "pois" to listOf("operator"),
            "platforms" to "none", "substations" to "none", "boxes" to "operator", "catenaries" to "none",
            "switches" to "none", "signals" to emptyList<String>(),
        ),
    );

    companion object {
        fun fromId(id: String): MapMode = entries.firstOrNull { it.id == id } ?: STANDARD
    }
}

/** User-configurable options that map onto upstream global-state keys. */
data class MapOptions(
    val showConstruction: Boolean = true,
    val showProposed: Boolean = false,
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

    /** The global state these options set in [mode], on top of the mode's own. */
    fun toGlobalState(mode: MapMode): Map<String, Any> {
        val state = mutableMapOf<String, Any>(
            "showConstructionInfrastructure" to showConstruction,
            "showProposedInfrastructure" to showProposed,
            "showAbandonedInfrastructure" to showAbandoned,
            "showRazedInfrastructure" to showRazed,
            "stationLowZoomLabel" to stationLowZoomLabel,
        )
        // The line colouring of these views; the web app offers them as `tracks` values.
        when (mode) {
            MapMode.ELECTRIFICATION -> state["tracks"] = when (electrificationLine) {
                "maximumCurrent" -> "maximum_current"
                "power" -> "power"
                else -> "voltage_frequency"
            }
            MapMode.TRACK -> state["tracks"] = when (trackLine) {
                "loadingGauge" -> "loading_gauge"
                "trackClass" -> "track_class"
                else -> "gauge"
            }
            else -> {}
        }
        return state
    }

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
