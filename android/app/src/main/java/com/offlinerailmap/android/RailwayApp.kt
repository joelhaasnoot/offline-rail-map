// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android

import android.app.Application
import com.offlinerailmap.android.data.PackStore
import com.offlinerailmap.android.data.Prefs
import org.maplibre.android.MapLibre

class RailwayApp : Application() {
    override fun onCreate() {
        super.onCreate()
        MapLibre.getInstance(this)
        Prefs.init(this)
        PackStore.init(this)
    }
}
