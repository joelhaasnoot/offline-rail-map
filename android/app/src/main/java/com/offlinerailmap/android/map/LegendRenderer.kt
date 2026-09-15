// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.map

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import android.util.LruCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.snapshotter.MapSnapshotter
import kotlin.coroutines.resume
import kotlin.math.pow

/** Loads legend.json once. */
object LegendData {
    private var legend: JSONObject? = null

    @Synchronized
    fun view(context: Context, modeId: String): JSONObject {
        val all = legend ?: JSONObject(context.assets.open("style/legend.json").bufferedReader().readText()).also { legend = it }
        return all.optJSONObject(modeId) ?: JSONObject()
    }
}

/**
 * Renders key rows with one reused [MapSnapshotter], strictly one snapshot at a time, and keeps
 * the results in memory while the key is open.
 */
class LegendRenderer(context: Context) {
    private val appContext = context.applicationContext
    private val density = context.resources.displayMetrics.density
    private val composer = SpriteComposer.forPixelRatio(context, density)
    private val mutex = Mutex()
    private var snapshotter: MapSnapshotter? = null
    private var loadedStyle: String? = null
    private val cache = object : LruCache<String, Bitmap>(24 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }

    val widthDp: Float = unitsToDp(Legend.ROW_WIDTH_UNITS).toFloat()
    val heightDp: Float = unitsToDp(Legend.ROW_HEIGHT_UNITS).toFloat()

    fun cached(styleKey: String, row: Int): Bitmap? = cache.get("$styleKey#$row")

    suspend fun render(styleKey: String, styleJson: String, row: Int): Bitmap? {
        val key = "$styleKey#$row"
        cache.get(key)?.let { return it }
        return mutex.withLock {
            cache.get(key)?.let { return@withLock it }
            currentCoroutineContext().ensureActive() // skip rows scrolled away while waiting
            // A started snapshot must finish before the next one starts, even if nobody wants it any more.
            // The timeout is a safety net: a snapshot that never reports back is abandoned and the
            // snapshotter recreated, so one bad row cannot stall the whole key.
            withContext(NonCancellable + Dispatchers.Main) {
                withTimeoutOrNull(SNAPSHOT_TIMEOUT_MS) { snapshot(styleJson, row) }
                    ?: run {
                        if (snapshotter != null) {
                            Log.w(TAG, "legend row $row timed out; recreating the snapshotter")
                        }
                        null
                    }
            }?.also { cache.put(key, it) }
        }
    }

    private suspend fun snapshot(styleJson: String, row: Int): Bitmap? = suspendCancellableCoroutine { cont ->
        val (lat, lon) = Legend.rowCenter(row)
        val camera = CameraPosition.Builder().target(LatLng(lat, lon)).zoom(Legend.RENDER_ZOOM).build()
        val snap = snapshotter ?: MapSnapshotter(
            appContext,
            MapSnapshotter.Options(widthDp.toInt(), heightDp.toInt())
                .withStyleJson(styleJson)
                .withCameraPosition(camera)
                .withPixelRatio(density)
                .withLogo(false)
                .withAttribution(false),
        ).also {
            // Some upstream icons (e.g. "...@bottom" signal compositions) are generated at runtime by
            // the website and are not in the sprite, so compose them here too. Anything that cannot be
            // composed gets a transparent placeholder: without an image the snapshot would wait forever.
            it.setObserver(object : MapSnapshotter.Observer {
                override fun onDidFinishLoadingStyle() {}

                override fun onStyleImageMissing(imageName: String) {
                    val images = composer.compose(imageName)
                    if (images != null) {
                        images.addTo(it::addImage)
                    } else {
                        it.addImage(imageName, placeholder, false)
                    }
                }
            })
            snapshotter = it
            loadedStyle = styleJson
        }
        if (loadedStyle != styleJson) {
            snap.setStyleJson(styleJson)
            loadedStyle = styleJson
        }
        snap.setCameraPosition(camera)
        cont.invokeOnCancellation {
            snap.cancel()
            snapshotter = null
            loadedStyle = null
        }
        snap.start(
            { result -> if (cont.isActive) cont.resume(result.bitmap) },
            { error ->
                Log.w(TAG, "legend row $row failed: $error")
                if (cont.isActive) cont.resume(null)
            },
        )
    }

    fun close() {
        snapshotter?.cancel()
        snapshotter = null
        cache.evictAll()
    }

    companion object {
        private const val TAG = "LegendRenderer"
        private const val SNAPSHOT_TIMEOUT_MS = 8_000L
        private val placeholder: Bitmap by lazy { Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888) }

        /** Legend units at the render zoom in dp (MapLibre uses 512 dp tiles). */
        fun unitsToDp(units: Double): Double = Legend.degrees(units) * 512.0 * 2.0.pow(Legend.RENDER_ZOOM) / 360.0
    }
}
