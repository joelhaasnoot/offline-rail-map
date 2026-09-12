// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap

import android.app.Application
import app.offlinerailwaymap.data.PackStore
import app.offlinerailwaymap.data.Prefs
import org.maplibre.android.MapLibre

class RailwayApp : Application() {
    override fun onCreate() {
        super.onCreate()
        MapLibre.getInstance(this)
        Prefs.init(this)
        PackStore.init(this)
    }
}
