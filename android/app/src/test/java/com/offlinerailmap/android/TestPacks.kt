// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android

import com.offlinerailmap.android.data.InstalledPack
import com.offlinerailmap.android.data.PackInfo
import java.io.File

/**
 * Synthetic packs with simplified region polygons. The Netherlands ring deliberately has a
 * bounding box that reaches into Belgium (as the real Geofabrik one does), so that tests can
 * tell polygon-based checks apart from bounding-box checks.
 */
object TestPacks {
    private fun ring(vararg lonLat: Double): List<DoubleArray> =
        lonLat.toList().chunked(2).map { doubleArrayOf(it[0], it[1]) }

    val netherlandsRing = ring(
        3.3, 51.4, 4.2, 51.35, 5.5, 51.4, 5.6, 50.75, 6.2, 50.75, 6.1, 51.9, 7.2, 52.2, 7.2, 53.5, 4.5, 53.5, 3.3, 51.5,
    )
    val belgiumRing = ring(2.5, 49.5, 6.4, 49.5, 6.4, 50.7, 5.6, 50.75, 5.5, 51.4, 4.2, 51.35, 3.3, 51.4, 2.5, 51.1)
    val luxembourgRing = ring(5.7, 49.45, 6.5, 49.45, 6.5, 50.2, 5.7, 50.2)

    val netherlands = PackInfo(
        id = "netherlands", name = "Netherlands", region = "europe",
        railwayUrl = "http://packs/netherlands/railway.pmtiles", railwayBytes = 40_000_000,
        basemapUrl = null, basemapBytes = 0,
        bbox = doubleArrayOf(3.3, 50.75, 7.2, 53.5), dataDate = "2026-09-11", version = 1,
        coverage = listOf(netherlandsRing),
    )
    val belgium = netherlands.copy(
        id = "belgium", name = "Belgium", railwayUrl = "http://packs/belgium/railway.pmtiles",
        bbox = doubleArrayOf(2.5, 49.5, 6.4, 51.4), coverage = listOf(belgiumRing),
    )
    val benelux = netherlands.copy(
        id = "benelux", name = "Benelux", railwayUrl = "http://packs/benelux/railway.pmtiles",
        bbox = doubleArrayOf(2.5, 49.45, 7.2, 53.5), coverage = listOf(netherlandsRing, belgiumRing, luxembourgRing),
    )

    fun installed(info: PackInfo) = InstalledPack(info, File(System.getProperty("java.io.tmpdir"), "packs/${info.id}"))

    // Well-known points: lat, lon
    val amsterdam = 52.37 to 4.90
    val maastricht = 50.85 to 5.69
    val brussels = 50.845 to 4.35
    val copenhagen = 55.67 to 12.57
}
