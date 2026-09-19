// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.map

import android.os.SystemClock
import android.util.Log
import org.maplibre.android.maps.MapView

/**
 * Debug and benchmark builds only: logs a summary of the frames MapLibre drew since the map last went idle, for
 * comparing rendering cost on slow phones (`adb logcat -s FrameStats`).
 */
object FrameStats {
    private const val TAG = "FrameStats"

    fun attach(view: MapView) {
        val encode = ArrayList<Double>()
        val render = ArrayList<Double>()
        var drawCalls = 0
        var memBuffers = 0
        var memTextures = 0
        var busySince = 0L
        view.addOnDidFinishRenderingFrameListener { _, stats ->
            if (encode.isEmpty()) {
                busySince = SystemClock.elapsedRealtime()
            }
            encode.add(stats.encodingTime * 1000)
            render.add(stats.renderingTime * 1000)
            drawCalls = maxOf(drawCalls, stats.numDrawCalls)
            memBuffers = stats.memBuffers
            memTextures = stats.memTextures
        }
        view.addOnDidBecomeIdleListener {
            if (encode.isEmpty()) {
                return@addOnDidBecomeIdleListener
            }
            val total = encode.indices.map { encode[it] + render[it] }.sorted()
            Log.i(
                TAG,
                "frames=${total.size} busy=${SystemClock.elapsedRealtime() - busySince}ms " +
                    "frame avg=%.1f p50=%.1f p90=%.1f max=%.1f ms (encode avg=%.1f) drawCalls<=%d buffers=%dMB textures=%dMB".format(
                        total.average(), total[total.size / 2], total[(total.size * 9) / 10], total.last(),
                        encode.average(), drawCalls, memBuffers shr 20, memTextures shr 20,
                    ),
            )
            encode.clear()
            render.clear()
            drawCalls = 0
        }
    }
}
