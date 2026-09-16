// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.data

import android.content.Context
import android.content.SharedPreferences

/** Tiny wrapper around SharedPreferences for the handful of things we persist. */
object Prefs {
    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        prefs = context.applicationContext.getSharedPreferences("offline_railway_map", Context.MODE_PRIVATE)
    }

    var modeId: String
        get() = prefs.getString("mode", "standard") ?: "standard"
        set(value) = prefs.edit().putString("mode", value).apply()

    var showConstruction: Boolean
        get() = prefs.getBoolean("showConstruction", true)
        set(v) = prefs.edit().putBoolean("showConstruction", v).apply()

    var showProposed: Boolean
        get() = prefs.getBoolean("showProposed", false)
        set(v) = prefs.edit().putBoolean("showProposed", v).apply()

    var showAbandoned: Boolean
        get() = prefs.getBoolean("showAbandoned", false)
        set(v) = prefs.edit().putBoolean("showAbandoned", v).apply()

    var showRazed: Boolean
        get() = prefs.getBoolean("showRazed", false)
        set(v) = prefs.edit().putBoolean("showRazed", v).apply()

    var electrificationLine: String
        get() = prefs.getString("electrificationLine", "voltageFrequency") ?: "voltageFrequency"
        set(v) = prefs.edit().putString("electrificationLine", v).apply()

    var trackLine: String
        get() = prefs.getString("trackLine", "gauge") ?: "gauge"
        set(v) = prefs.edit().putString("trackLine", v).apply()

    var stationLowZoomLabel: String
        get() = prefs.getString("stationLowZoomLabel", "label") ?: "label"
        set(v) = prefs.edit().putString("stationLowZoomLabel", v).apply()

    var darkTheme: Boolean
        get() = prefs.getBoolean("darkTheme", false)
        set(v) = prefs.edit().putBoolean("darkTheme", v).apply()

    /** Last camera position as lat, lon, zoom; null when never saved. */
    var camera: Triple<Double, Double, Double>?
        get() {
            if (!prefs.contains("cam_lat")) {
                return null
            }
            return Triple(
                prefs.getFloat("cam_lat", 0f).toDouble(),
                prefs.getFloat("cam_lon", 0f).toDouble(),
                prefs.getFloat("cam_zoom", 0f).toDouble(),
            )
        }
        set(v) {
            if (v == null) {
                prefs.edit().remove("cam_lat").remove("cam_lon").remove("cam_zoom").apply()
            } else {
                prefs.edit()
                    .putFloat("cam_lat", v.first.toFloat())
                    .putFloat("cam_lon", v.second.toFloat())
                    .putFloat("cam_zoom", v.third.toFloat())
                    .apply()
            }
        }
}
