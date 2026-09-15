// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.map

import android.content.Context
import android.util.Log
import com.offlinerailmap.android.BuildConfig
import java.io.File
import java.io.IOException

/**
 * MapLibre cannot read PMTiles straight from the APK, so the bundled world file is copied to
 * internal storage once per app version.
 */
object WorldMap {
    private const val TAG = "WorldMap"
    private const val ASSET = "world/world.pmtiles"

    @Synchronized
    fun file(context: Context): File? = try {
        val dir = File(context.filesDir, "world").also { it.mkdirs() }
        val length = try {
            context.assets.openFd(ASSET).use { it.length }
        } catch (e: IOException) {
            -1L // asset stored compressed; fall back to the version alone
        }
        val target = File(dir, "world-${BuildConfig.VERSION_CODE}-$length.pmtiles")
        if (!target.isFile || (length >= 0 && target.length() != length)) {
            val tmp = File(dir, "${target.name}.part")
            context.assets.open(ASSET).use { input -> tmp.outputStream().use { input.copyTo(it) } }
            if (!tmp.renameTo(target)) {
                throw IOException("could not move ${tmp.name} into place")
            }
        }
        dir.listFiles()?.filter { it != target }?.forEach { it.delete() }
        target
    } catch (e: IOException) {
        Log.w(TAG, "world map unavailable", e)
        null
    }
}
