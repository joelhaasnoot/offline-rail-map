// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.data

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** One downloadable country pack, as described by the manifest. */
data class PackInfo(
    val id: String,
    val name: String,
    val region: String,
    val railwayUrl: String,
    val railwayBytes: Long,
    val basemapUrl: String?,
    val basemapBytes: Long,
    /** west, south, east, north */
    val bbox: DoubleArray,
    val dataDate: String,
    val version: Int,
    /** Outer rings of the region polygon as [lon, lat] pairs; empty when unknown (fall back to bbox). */
    val coverage: List<List<DoubleArray>> = emptyList(),
    /** Display name of [region] from the manifest, e.g. "North America"; empty in older manifests. */
    val regionName: String = "",
) {
    /** Human-readable parent region: the manifest's name, or the id made readable. */
    val regionLabel: String get() = regionName.ifBlank { regionLabelFromId(region) }

    val totalBytes: Long get() = railwayBytes + basemapBytes

    /** True when the point lies inside the pack's region polygon (or its bbox when no polygon is known). */
    fun contains(lat: Double, lon: Double): Boolean {
        if (coverage.isEmpty()) {
            return lon >= bbox[0] && lon <= bbox[2] && lat >= bbox[1] && lat <= bbox[3]
        }
        return coverage.any { ring -> pointInRing(ring, lon, lat) }
    }

    private fun pointInRing(ring: List<DoubleArray>, x: Double, y: Double): Boolean {
        var inside = false
        var j = ring.size - 1
        for (i in ring.indices) {
            val xi = ring[i][0]
            val yi = ring[i][1]
            val xj = ring[j][0]
            val yj = ring[j][1]
            if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
                inside = !inside
            }
            j = i
        }
        return inside
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("name", name)
        put("region", region)
        put("region_name", regionName)
        put("railway_url", railwayUrl)
        put("railway_bytes", railwayBytes)
        put("basemap_url", basemapUrl ?: JSONObject.NULL)
        put("basemap_bytes", basemapBytes)
        put("bbox", JSONArray(bbox.toList()))
        put("data_date", dataDate)
        put("version", version)
        put("coverage", JSONArray(coverage.map { ring -> JSONArray(ring.map { JSONArray(it.toList()) }) }))
    }

    companion object {
        fun fromJson(o: JSONObject): PackInfo {
            val bboxArr = o.getJSONArray("bbox")
            return PackInfo(
                id = o.getString("id"),
                name = o.getString("name"),
                region = o.optString("region", ""),
                railwayUrl = o.getString("railway_url"),
                railwayBytes = o.optLong("railway_bytes", 0),
                basemapUrl = if (o.isNull("basemap_url")) null else o.optString("basemap_url").ifEmpty { null },
                basemapBytes = o.optLong("basemap_bytes", 0),
                bbox = DoubleArray(4) { bboxArr.getDouble(it) },
                dataDate = o.optString("data_date", ""),
                version = o.optInt("version", 1),
                coverage = parseCoverage(o.optJSONArray("coverage")),
                regionName = o.optString("region_name", ""),
            )
        }

        private val lowercaseWords = setOf("and", "of", "the")

        /** "north-america" -> "North America", "australia-oceania" -> "Australia Oceania". */
        fun regionLabelFromId(id: String): String =
            id.split('-', '_', ' ')
                .filter { it.isNotEmpty() }
                .mapIndexed { i, word ->
                    if (i > 0 && word in lowercaseWords) word else word.replaceFirstChar { it.uppercase() }
                }
                .joinToString(" ")

        private fun parseCoverage(arr: JSONArray?): List<List<DoubleArray>> {
            if (arr == null) {
                return emptyList()
            }
            return (0 until arr.length()).map { r ->
                val ring = arr.getJSONArray(r)
                (0 until ring.length()).map { i ->
                    val pt = ring.getJSONArray(i)
                    doubleArrayOf(pt.getDouble(0), pt.getDouble(1))
                }
            }
        }

        fun listFromManifest(manifest: JSONObject): List<PackInfo> {
            val arr = manifest.getJSONArray("packs")
            return (0 until arr.length()).map { fromJson(arr.getJSONObject(it)) }
        }
    }
}

/** A pack that is fully downloaded and stored on the device. */
data class InstalledPack(
    val info: PackInfo,
    val dir: File,
) {
    val railwayFile: File get() = File(dir, "railway.pmtiles")
    val basemapFile: File? get() = File(dir, "basemap.pmtiles").takeIf { it.isFile }
}

sealed class DownloadState {
    data class Running(val bytesDone: Long, val bytesTotal: Long, val stage: String) : DownloadState() {
        val fraction: Float get() = if (bytesTotal > 0) (bytesDone.toFloat() / bytesTotal).coerceIn(0f, 1f) else 0f
    }
    data class Failed(val message: String) : DownloadState()
}
