// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap.map

import app.offlinerailwaymap.data.PackInfo
import org.json.JSONArray
import org.json.JSONObject

/**
 * The world overview that ships with the app: basemap layers drawn from a zoom 0-4 world file,
 * plus a land-coloured mask over every downloaded basemap pack so the coarse world coastlines
 * never show through the detailed pack underneath.
 */
object WorldLayers {
    const val SOURCE = "world"
    const val MASK_SOURCE = "pack-mask"
    const val MASK_LAYER = "pack-mask"

    /** World tiles stop at zoom 4; past this zoom their coastlines are too coarse to be useful. */
    const val MAX_VISIBLE_ZOOM = 10.0

    private const val ATTRIBUTION =
        "<a href=\"https://www.openstreetmap.org/copyright\">© OpenStreetMap contributors</a> · " +
            "<a href=\"https://www.naturalearthdata.com\">Natural Earth</a>"

    fun source(pmtilesUrl: String): JSONObject = JSONObject()
        .put("type", "vector")
        .put("url", pmtilesUrl)
        .put("attribution", ATTRIBUTION)

    /**
     * A copy of a basemap layer that reads from the world source, capped at [MAX_VISIBLE_ZOOM] and
     * with labels in English where available. Returns null for layers that would never be visible.
     */
    fun worldCopy(layer: JSONObject): JSONObject? {
        val copy = JSONObject(layer.toString())
        val maxzoom = minOf(copy.optDouble("maxzoom", 24.0), MAX_VISIBLE_ZOOM)
        if (copy.optDouble("minzoom", 0.0) >= maxzoom) {
            return null
        }
        copy.put("id", "${layer.getString("id")}__$SOURCE")
        copy.put("source", SOURCE)
        copy.put("maxzoom", maxzoom)
        copy.optJSONObject("layout")?.let { layout ->
            layout.opt("text-field")?.let { layout.put("text-field", preferEnglish(it)) }
        }
        return copy
    }

    /** Replaces `["get", "name"]` with `["coalesce", ["get", "name:en"], ["get", "name"]]`. */
    fun preferEnglish(expression: Any): Any {
        if (expression !is JSONArray) {
            return expression
        }
        if (expression.length() == 2 && expression.opt(0) == "get" && expression.opt(1) == "name") {
            return JSONArray()
                .put("coalesce")
                .put(JSONArray().put("get").put("name:en"))
                .put(JSONArray().put("get").put("name"))
        }
        val out = JSONArray()
        for (i in 0 until expression.length()) {
            out.put(preferEnglish(expression.opt(i)))
        }
        return out
    }

    /** Region outlines of the given packs as one MultiPolygon (bounding boxes when unknown). */
    fun maskGeometry(packs: List<PackInfo>): JSONObject? {
        val polygons = JSONArray()
        for (pack in packs) {
            val rings = pack.coverage.ifEmpty {
                val (w, s, e, n) = pack.bbox.toList()
                listOf(listOf(doubleArrayOf(w, s), doubleArrayOf(e, s), doubleArrayOf(e, n), doubleArrayOf(w, n)))
            }
            for (ring in rings) {
                if (ring.size < 3) {
                    continue
                }
                val coords = JSONArray()
                ring.forEach { coords.put(JSONArray().put(it[0]).put(it[1])) }
                if (!ring.first().contentEquals(ring.last())) {
                    coords.put(JSONArray().put(ring.first()[0]).put(ring.first()[1]))
                }
                polygons.put(JSONArray().put(coords))
            }
        }
        if (polygons.length() == 0) {
            return null
        }
        return JSONObject().put("type", "MultiPolygon").put("coordinates", polygons)
    }

    fun maskSource(geometry: JSONObject): JSONObject = JSONObject()
        .put("type", "geojson")
        .put("data", JSONObject().put("type", "Feature").put("properties", JSONObject()).put("geometry", geometry))

    /**
     * World labels are drawn above the pack basemaps (whose low-zoom tiles span far beyond their
     * country and would paint over them), so they must skip the downloaded regions where the pack
     * shows its own labels. Continents are not in the packs and stay everywhere.
     */
    fun hideInsideMask(layer: JSONObject, geometry: JSONObject): JSONObject {
        if (layer.optString("source-layer") == "place" && layer.getString("id").startsWith("place-continent")) {
            return layer
        }
        val outside = JSONArray().put("!").put(JSONArray().put("within").put(JSONObject(geometry.toString())))
        val filter = layer.opt("filter")
        layer.put("filter", if (filter == null) outside else JSONArray().put("all").put(filter).put(outside))
        return layer
    }

    fun maskLayer(color: String): JSONObject = JSONObject()
        .put("id", MASK_LAYER)
        .put("type", "fill")
        .put("source", MASK_SOURCE)
        .put("paint", JSONObject().put("fill-color", color).put("fill-antialias", false))
}
