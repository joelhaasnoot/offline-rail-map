// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.map

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin

/**
 * The map key, ported from the OpenRailwayMap web legend (`legend.json` + `makeLegendStyle`).
 *
 * Every entry is drawn by MapLibre itself: sample lines and points carrying the entry's feature
 * properties are placed in rows on an empty "legend map" and styled with the very layers the map
 * uses, so colours, dashes and symbols always match. Rows are [ROW_SPACING] map units apart and
 * rendered one at a time by the snapshotter; the app shows the text next to them.
 */
object Legend {
    /** Zoom the legend map is rendered at, as on the website. */
    const val RENDER_ZOOM = 16.0

    /** Distance between row centres, in legend units. Wide enough that rows never bleed into each other. */
    const val ROW_SPACING = 2.0

    /** Size of one rendered row in legend units: the sample area itself is 1.5 units wide. */
    const val ROW_WIDTH_UNITS = 1.7
    const val ROW_HEIGHT_UNITS = 1.2

    private const val SAMPLE_START = -2.5
    private const val SAMPLE_WIDTH = 1.5
    const val ROW_CENTER_X = SAMPLE_START + SAMPLE_WIDTH / 2

    private const val MIN_ZOOM = 1
    private const val MAX_ZOOM = 20

    /** Separator the website uses between the parts of a feature key. */
    private const val KEY_SEPARATOR = "\u001E"

    /** Legend units to degrees, as on the website. */
    fun degrees(units: Double): Double = units * 2.0.pow(-11)

    /** Row centre as (latitude, longitude). */
    fun rowCenter(row: Int): Pair<Double, Double> = degrees(-row * ROW_SPACING) to degrees(ROW_CENTER_X)

    data class Entry(
        val label: String,
        val sourceName: String,
        /** GeoJSON features with geometry already placed in this entry's row. */
        val features: List<JSONObject>,
    )

    /** `source-sourceLayer`, the name legend.json uses for a style layer's data. */
    fun sourceName(layer: JSONObject): String = "${layer.optString("source")}-${layer.optString("source-layer")}"

    fun visibleAtZoom(layer: JSONObject, zoom: Int): Boolean =
        layer.optDouble("minzoom", MIN_ZOOM.toDouble()) <= zoom && zoom < layer.optDouble("maxzoom", MAX_ZOOM + 1.0)

    /**
     * The key entries for the layers visible at [zoom]: symbols (points and areas) first, then lines,
     * each group in style order. Symbols come first because the on-screen filter can tell them apart,
     * while many line entries share one key and are listed whenever any line is on screen.
     *
     * @param legendView the legend.json object for the current view (`{countries, sourceLayers}`)
     * @param state resolved global state (map options), for entries that depend on them
     * @param inView source name to feature keys found on screen; null lists every entry
     */
    fun entries(
        legendView: JSONObject,
        layers: List<JSONObject>,
        state: Map<String, Any?>,
        zoom: Int,
        inView: Map<String, Set<String>>?,
    ): List<Entry> {
        val sourceLayers = legendView.optJSONObject("sourceLayers") ?: JSONObject()
        val done = HashSet<String>()
        val symbols = ArrayList<Pair<JSONObject, String>>()
        val lines = ArrayList<Pair<JSONObject, String>>()
        for (layer in layers) {
            val name = sourceName(layer)
            if (name in done || !visibleAtZoom(layer, zoom)) {
                continue
            }
            done.add(name)
            val items = sourceLayers.optJSONObject(name)?.optJSONArray("features") ?: continue
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                if (!visibleAtZoom(item, zoom) || !stateMatches(item, state) || !inViewMatches(item, name, inView)) {
                    continue
                }
                if (item.optString("type") == "line") {
                    lines.add(item to name)
                } else {
                    symbols.add(item to name)
                }
            }
        }
        // Rows are numbered in display order: the sample geometry of each entry sits in its own row.
        return (symbols + lines).mapIndexed { row, (item, name) ->
            val variants = expandVariants(item).filter { stateMatches(it, state) }
            val features = variants.mapIndexed { index, variant -> placeFeature(variant, index, variants.size, row) }
            Entry(label(item, state), name, features)
        }
    }

    private fun stateMatches(item: JSONObject, state: Map<String, Any?>): Boolean {
        val required = item.optJSONObject("mapState") ?: return true
        return required.keys().asSequence().all { key -> valuesEqual(state[key], required.opt(key)) }
    }

    private fun valuesEqual(a: Any?, b: Any?): Boolean {
        if (a is Number && b is Number) {
            return a.toDouble() == b.toDouble()
        }
        return a == b
    }

    private fun inViewMatches(item: JSONObject, sourceName: String, inView: Map<String, Set<String>>?): Boolean {
        if (inView == null) {
            return true
        }
        val found = inView[sourceName] ?: return false
        val keys = item.optJSONArray("keys") ?: return true
        if (keys.length() == 0) {
            return true
        }
        return (0 until keys.length()).any { keys.getString(it) in found }
    }

    /** The item itself followed by its variants, each variant inheriting and overriding the item. */
    private fun expandVariants(item: JSONObject): List<JSONObject> {
        val out = arrayListOf(item)
        val variants = item.optJSONArray("variants") ?: return out
        for (i in 0 until variants.length()) {
            val variant = variants.getJSONObject(i)
            val merged = JSONObject(item.toString())
            merged.remove("variants")
            for (key in variant.keys()) {
                if (key != "properties") {
                    merged.put(key, variant.get(key))
                }
            }
            val props = JSONObject(item.optJSONObject("properties")?.toString() ?: "{}")
            variant.optJSONObject("properties")?.let { vp -> vp.keys().forEach { props.put(it, vp.get(it)) } }
            merged.put("properties", props)
            out.add(merged)
        }
        return out
    }

    private fun label(item: JSONObject, state: Map<String, Any?>): String {
        val base = item.optString("legend")
        val prefixed = if (item.has("country")) "(${item.getString("country")}) $base" else base
        val variants = item.optJSONArray("variants") ?: return prefixed
        val extra = (0 until variants.length()).map { variants.getJSONObject(it) }
            .filter { it.has("legend") && stateMatches(it, state) }
            .map { it.getString("legend") }
        return (listOf(prefixed) + extra).joinToString(", ")
    }

    private fun point(x: Double, y: Double): JSONArray = JSONArray().put(degrees(x)).put(degrees(y))

    /** Sample geometry for variant [index] of [count] in row [row]: lines split the row, points share it. */
    private fun placeFeature(item: JSONObject, index: Int, count: Int, row: Int): JSONObject {
        val y = -row * ROW_SPACING
        val left = SAMPLE_START + index.toDouble() / count * SAMPLE_WIDTH
        val right = SAMPLE_START + (index + 1.0) / count * SAMPLE_WIDTH
        val middle = (left + right) / 2
        val geometry = when (item.optString("type")) {
            "line" -> JSONObject().put("type", "LineString")
                .put("coordinates", JSONArray().put(point(left, y)).put(point(right, y)))
            "polygon" -> {
                val ring = JSONArray()
                for (i in 0..20) {
                    val phi = i * 2 * PI / 20
                    ring.put(point(cos(phi) * 0.1 + middle, sin(phi) * 0.1 + y))
                }
                JSONObject().put("type", "LineString").put("coordinates", ring)
            }
            else -> JSONObject().put("type", "Point").put("coordinates", point(middle, y))
        }
        return JSONObject()
            .put("type", "Feature")
            .put("geometry", geometry)
            .put("properties", JSONObject(item.optJSONObject("properties")?.toString() ?: "{}"))
    }

    /**
     * The style that draws [entries]: the visible layers at [zoom], each reading from a GeoJSON source
     * named after its data (`source-sourceLayer`), adapted as the website does for its legend map.
     */
    fun style(layers: List<JSONObject>, zoom: Int, entries: List<Entry>, sprite: String, glyphs: String): JSONObject {
        val styleLayers = JSONArray()
        val sourceNames = LinkedHashSet<String>()
        for (layer in layers) {
            if (!visibleAtZoom(layer, zoom)) {
                continue
            }
            val copy = JSONObject(layer.toString())
            val name = sourceName(layer)
            copy.remove("source-layer")
            copy.remove("minzoom")
            copy.remove("maxzoom")
            copy.put("source", name)
            copy.optJSONObject("layout")?.let { layout ->
                listOf("text-padding", "text-offset", "symbol-spacing", "icon-offset").forEach { layout.remove(it) }
                if (layout.optString("symbol-placement") == "line") {
                    layout.put("symbol-placement", "line-center")
                }
            }
            styleLayers.put(copy)
            sourceNames.add(name)
        }
        val sources = JSONObject()
        for (name in sourceNames) {
            val features = JSONArray()
            entries.filter { it.sourceName == name }.forEach { entry -> entry.features.forEach { features.put(it) } }
            sources.put(
                name,
                JSONObject().put("type", "geojson")
                    .put("data", JSONObject().put("type", "FeatureCollection").put("features", features)),
            )
        }
        return JSONObject()
            .put("version", 8)
            .put("name", "legend")
            .put("sprite", sprite)
            .put("glyphs", glyphs)
            .put("sources", sources)
            .put("layers", styleLayers)
    }

    /**
     * The keys of a feature seen on the map, computed as on the website: the values of the source
     * layer's `key` properties (and of each `matchKeys` list) joined with U+001E.
     */
    fun featureKeys(sourceLayer: JSONObject, property: (String) -> Any?): Set<String> {
        fun keyOf(parts: JSONArray): String = (0 until parts.length()).joinToString(KEY_SEPARATOR) { i ->
            keyPart(property(parts.getString(i)))
        }
        val keys = LinkedHashSet<String>()
        keys.add(keyOf(sourceLayer.optJSONArray("key") ?: JSONArray()))
        sourceLayer.optJSONArray("matchKeys")?.let { match ->
            for (i in 0 until match.length()) {
                keys.add(keyOf(match.getJSONArray(i)))
            }
        }
        return keys
    }

    private val placeholder = Regex("\\{[^}]+\\}") // closing brace escaped: Android's ICU regex rejects a bare one
    private val suffix = Regex("@([^|]+|$)")

    /** JavaScript `String(value ?? '')`, with `{...}` placeholders and `@...` suffixes normalised. */
    fun keyPart(value: Any?): String {
        val text = when (value) {
            null, JSONObject.NULL -> ""
            is Double -> if (!value.isInfinite() && value % 1.0 == 0.0) value.toLong().toString() else value.toString()
            is Float -> if (!value.isInfinite() && value % 1f == 0f) value.toLong().toString() else value.toString()
            else -> value.toString()
        }
        return placeholder.replaceFirst(text, "{}").replace(suffix, "")
    }
}
