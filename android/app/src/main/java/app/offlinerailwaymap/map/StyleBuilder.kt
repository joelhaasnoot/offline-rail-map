// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap.map

import android.content.Context
import android.util.Log
import app.offlinerailwaymap.data.InstalledPack
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Calendar

/**
 * Builds the MapLibre style JSON shown on the map.
 *
 * The upstream OpenRailwayMap style is a single style that switches between "Infrastructure",
 * "Speed", ... via `global-state` expressions. MapLibre Native does not evaluate those, so we
 * substitute the chosen state values into the expressions ourselves, evaluate each layer's
 * `visibility` expression to a constant and drop hidden layers.
 *
 * Every installed country pack gets its own copy of the sources and layers, pointing at the
 * PMTiles files on disk.
 */
object StyleBuilder {
    private const val TAG = "StyleBuilder"

    private var ormStyle: JSONObject? = null
    private var basemapStyle: JSONObject? = null

    @Synchronized
    private fun load(context: Context): Pair<JSONObject, JSONObject> {
        if (ormStyle == null) {
            ormStyle = JSONObject(context.assets.open("style/orm-style.json").bufferedReader().readText())
            basemapStyle = JSONObject(context.assets.open("style/basemap-style.json").bufferedReader().readText())
        }
        return ormStyle!! to basemapStyle!!
    }

    fun build(context: Context, mode: MapMode, options: MapOptions, packs: List<InstalledPack>): String {
        val (orm, base) = load(context)
        val state = globalState(orm, mode, options)

        val out = JSONObject()
        out.put("version", 8)
        out.put("name", "OpenRailwayMap offline · ${mode.label}")
        out.put("sprite", orm.getString("sprite"))
        out.put("glyphs", orm.getString("glyphs"))
        val sources = JSONObject()
        val layers = JSONArray()

        // --- Basemap (one source per pack that ships one) ---
        val basemapSource = base.getJSONObject("sources").getJSONObject("basemap")
        val basemapPacks = packs.filter { it.basemapFile != null }
        for (pack in basemapPacks) {
            val src = JSONObject(basemapSource.toString())
            src.put("url", pmtilesUrl(pack.basemapFile!!))
            sources.put("basemap__${pack.info.id}", src)
        }
        val baseLayers = base.getJSONArray("layers")
        for (i in 0 until baseLayers.length()) {
            val layer = baseLayers.getJSONObject(i)
            if (!layer.has("source")) {
                layers.put(JSONObject(layer.toString()))
                continue
            }
            val text = layer.toString()
            for (pack in basemapPacks) {
                val copy = JSONObject(text)
                copy.put("id", "${layer.getString("id")}__${pack.info.id}")
                copy.put("source", "basemap__${pack.info.id}")
                layers.put(copy)
            }
        }

        // --- OpenRailwayMap ---
        val ormSources = orm.getJSONObject("sources")
        val vectorSources = ormSources.keys().asSequence()
            .filter { ormSources.getJSONObject(it).optString("type") == "vector" }
            .toSet()
        for (pack in packs) {
            for (name in vectorSources) {
                val src = JSONObject(ormSources.getJSONObject(name).toString())
                src.put("url", pmtilesUrl(pack.railwayFile))
                sources.put("${name}__${pack.info.id}", src)
            }
        }
        val ormLayers = orm.getJSONArray("layers")
        var hidden = 0
        for (i in 0 until ormLayers.length()) {
            val layer = ormLayers.getJSONObject(i)
            val sourceName = layer.optString("source")
            if (sourceName !in vectorSources) {
                continue
            }
            val substituted = simplify(substitute(layer, state)) as JSONObject
            val layout = substituted.optJSONObject("layout")
            val visibility = layout?.opt("visibility")
            if (visibility is JSONArray) {
                Log.w(TAG, "visibility of ${layer.optString("id")} did not reduce to a constant: $visibility")
                layout.put("visibility", "visible")
            }
            if (layout?.optString("visibility") == "none") {
                hidden++
                continue
            }
            // Filters that reduced to a constant: drop the layer or drop the filter.
            val filter = substituted.opt("filter")
            if (filter is Boolean) {
                if (!filter) {
                    hidden++
                    continue
                }
                substituted.remove("filter")
            }
            val text = substituted.toString()
            for (pack in packs) {
                val copy = JSONObject(text)
                copy.put("id", "${layer.getString("id")}__${pack.info.id}")
                copy.put("source", "${sourceName}__${pack.info.id}")
                layers.put(copy)
            }
        }
        out.put("sources", sources)
        out.put("layers", layers)
        Log.i(TAG, "built style '${mode.id}' for ${packs.size} pack(s): ${layers.length()} layers, $hidden upstream layers hidden")
        return out.toString()
    }

    private fun pmtilesUrl(file: File): String = "pmtiles://file://" + file.absolutePath

    private fun globalState(orm: JSONObject, mode: MapMode, options: MapOptions): Map<String, Any?> {
        val state = HashMap<String, Any?>()
        val defaults = orm.optJSONObject("state")
        if (defaults != null) {
            for (key in defaults.keys()) {
                state[key] = defaults.getJSONObject(key).opt("default")
            }
        }
        state["style"] = mode.id
        state.putAll(mode.globalState)
        state.putAll(options.toGlobalState())
        state["theme"] = "light"
        state["pitched"] = false
        state["bearing"] = 0
        state["hillshade"] = false
        state["openHistoricalMap"] = false
        state["date"] = Calendar.getInstance().get(Calendar.YEAR)
        state["allDates"] = false
        return state
    }

    /** Deep-copies [value], replacing every `["global-state", key]` with the value of that key. */
    private fun substitute(value: Any?, state: Map<String, Any?>): Any? = when (value) {
        is JSONArray -> {
            if (value.length() == 2 && value.opt(0) == "global-state") {
                state[value.getString(1)] ?: JSONObject.NULL
            } else {
                val arr = JSONArray()
                for (i in 0 until value.length()) {
                    arr.put(substitute(value.opt(i), state))
                }
                arr
            }
        }
        is JSONObject -> {
            val obj = JSONObject()
            for (key in value.keys()) {
                obj.put(key, substitute(value.opt(key), state))
            }
            obj
        }
        else -> value
    }

    /**
     * Constant-folds sub-expressions whose operands are all constants (after `global-state`
     * substitution), so that e.g. `["==", "usage", "usage"]` becomes `true` and `["all", ...]`,
     * `["any", ...]` and `["case", ...]` collapse. Besides shrinking the style, this is required
     * because MapLibre Native parses a filter such as `["==", "a", "b"]` as a *legacy* filter
     * (property "a" equals "b") and rejects `["==", true, false]` outright.
     */
    private fun simplify(value: Any?): Any? {
        if (value is JSONObject) {
            val obj = JSONObject()
            for (key in value.keys()) {
                obj.put(key, simplify(value.opt(key)))
            }
            return obj
        }
        if (value !is JSONArray || value.length() == 0 || value.opt(0) !is String) {
            return value
        }
        val op = value.getString(0)
        if (op == "literal") {
            return value
        }
        val args = (1 until value.length()).map { simplify(value.opt(it)) }
        fun rebuild(): JSONArray = JSONArray().put(op).also { arr -> args.forEach { arr.put(it ?: JSONObject.NULL) } }
        when (op) {
            "all" -> {
                val remaining = ArrayList<Any?>()
                for (a in args) {
                    if (a == false) {
                        return false
                    }
                    if (a != true) {
                        remaining.add(a)
                    }
                }
                return when (remaining.size) {
                    0 -> true
                    1 -> remaining[0]
                    else -> JSONArray().put("all").also { arr -> remaining.forEach { arr.put(it) } }
                }
            }
            "any" -> {
                val remaining = ArrayList<Any?>()
                for (a in args) {
                    if (a == true) {
                        return true
                    }
                    if (a != false) {
                        remaining.add(a)
                    }
                }
                return when (remaining.size) {
                    0 -> false
                    1 -> remaining[0]
                    else -> JSONArray().put("any").also { arr -> remaining.forEach { arr.put(it) } }
                }
            }
            "case" -> {
                val kept = ArrayList<Any?>()
                var i = 0
                while (i + 1 < args.size) {
                    val cond = args[i]
                    if (cond == true) {
                        return if (kept.isEmpty()) args[i + 1] else finishCase(kept, args[i + 1])
                    }
                    if (cond != false && !(cond == null || cond === JSONObject.NULL)) {
                        kept.add(cond)
                        kept.add(args[i + 1])
                    }
                    i += 2
                }
                val fallback = args.last()
                return if (kept.isEmpty()) fallback else finishCase(kept, fallback)
            }
            "!" -> return if (args[0] is Boolean) !(args[0] as Boolean) else rebuild()
            "==", "!=", "<", "<=", ">", ">=", "in", "match", "coalesce" -> {
                val allConstant = args.all { it !is JSONArray || (it.length() > 0 && it.opt(0) == "literal") }
                if (allConstant) {
                    return try {
                        evaluate(rebuild())
                    } catch (e: Exception) {
                        rebuild()
                    }
                }
                return rebuild()
            }
            else -> return rebuild()
        }
    }

    private fun finishCase(pairs: List<Any?>, fallback: Any?): JSONArray {
        val arr = JSONArray().put("case")
        pairs.forEach { arr.put(it) }
        arr.put(fallback ?: JSONObject.NULL)
        return arr
    }

    // --- A very small expression evaluator, enough for the upstream `visibility` expressions ---

    private fun evaluate(e: Any?): Any? {
        if (e !is JSONArray || e.length() == 0 || e.opt(0) !is String) {
            return norm(e)
        }
        return when (val op = e.getString(0)) {
            "literal" -> e.opt(1)
            "case" -> {
                var i = 1
                while (i + 1 < e.length()) {
                    if (truthy(evaluate(e.opt(i)))) {
                        return evaluate(e.opt(i + 1))
                    }
                    i += 2
                }
                evaluate(e.opt(e.length() - 1))
            }
            "all" -> (1 until e.length()).all { truthy(evaluate(e.opt(it))) }
            "any" -> (1 until e.length()).any { truthy(evaluate(e.opt(it))) }
            "!" -> !truthy(evaluate(e.opt(1)))
            "==" -> eq(evaluate(e.opt(1)), evaluate(e.opt(2)))
            "!=" -> !eq(evaluate(e.opt(1)), evaluate(e.opt(2)))
            "<" -> compare(evaluate(e.opt(1)), evaluate(e.opt(2))) < 0
            "<=" -> compare(evaluate(e.opt(1)), evaluate(e.opt(2))) <= 0
            ">" -> compare(evaluate(e.opt(1)), evaluate(e.opt(2))) > 0
            ">=" -> compare(evaluate(e.opt(1)), evaluate(e.opt(2))) >= 0
            "in" -> {
                val needle = evaluate(e.opt(1))
                when (val haystack = evaluate(e.opt(2))) {
                    is JSONArray -> (0 until haystack.length()).any { eq(needle, norm(haystack.opt(it))) }
                    is String -> needle is String && haystack.contains(needle)
                    else -> false
                }
            }
            "match" -> {
                val input = evaluate(e.opt(1))
                var i = 2
                while (i + 1 < e.length() - 1) {
                    val labels = e.opt(i)
                    val matched = if (labels is JSONArray) {
                        (0 until labels.length()).any { eq(input, norm(labels.opt(it))) }
                    } else {
                        eq(input, norm(labels))
                    }
                    if (matched) {
                        return evaluate(e.opt(i + 1))
                    }
                    i += 2
                }
                evaluate(e.opt(e.length() - 1))
            }
            "coalesce" -> (1 until e.length()).asSequence().map { evaluate(e.opt(it)) }.firstOrNull { it != null }
            else -> throw IllegalArgumentException("unsupported expression operator '$op'")
        }
    }

    private fun norm(v: Any?): Any? = if (v == null || v === JSONObject.NULL) null else v

    private fun truthy(v: Any?): Boolean = when (v) {
        null -> false
        is Boolean -> v
        is Number -> v.toDouble() != 0.0
        is String -> v.isNotEmpty()
        else -> true
    }

    private fun eq(a: Any?, b: Any?): Boolean {
        if (a is Number && b is Number) {
            return a.toDouble() == b.toDouble()
        }
        return a == b
    }

    private fun compare(a: Any?, b: Any?): Int {
        if (a is Number && b is Number) {
            return a.toDouble().compareTo(b.toDouble())
        }
        if (a is String && b is String) {
            return a.compareTo(b)
        }
        throw IllegalArgumentException("cannot compare $a and $b")
    }
}
