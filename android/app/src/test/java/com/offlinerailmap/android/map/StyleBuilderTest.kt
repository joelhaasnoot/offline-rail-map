// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.map

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class StyleBuilderTest {
    // The base filter of the dashed railway lines with proposed/abandoned/razed hidden, as the style
    // builder leaves it after substituting the options.
    private val dashBase = """
        ["all",
          ["in", ["get", "state"], ["literal", ["construction", "proposed", "razed", "abandoned", "disused"]]],
          ["match", ["get", "state"], "construction", true, "proposed", false, "abandoned", false, "razed", false, true],
          ["!=", ["get", "bridge"], true]]
    """

    private fun never(json: String) = StyleBuilder.neverMatches(JSONArray(json))

    @Test
    fun splitBranchExcludedByTheBaseFilterNeverMatches() {
        assertTrue(never("""["all", $dashBase, ["in", ["get", "state"], ["literal", ["proposed"]]]]"""))
    }

    @Test
    fun fallbackBranchOutsideTheBaseListNeverMatches() {
        assertTrue(
            never(
                """["all", $dashBase, ["!", ["in", ["get", "state"], ["literal", ["construction", "proposed", "razed", "abandoned", "disused"]]]]]""",
            ),
        )
    }

    @Test
    fun branchTheBaseFilterAllowsIsKept() {
        assertFalse(never("""["all", $dashBase, ["in", ["get", "state"], ["literal", ["construction"]]]]"""))
        assertFalse(never("""["all", $dashBase, ["in", ["get", "state"], ["literal", ["disused"]]]]"""))
    }

    @Test
    fun filtersOnOtherExpressionsAreKept() {
        assertFalse(never("""["all", ["==", ["geometry-type"], "LineString"], ["in", ["get", "class"], ["literal", ["motorway", "trunk"]]]]"""))
        assertFalse(
            never("""["all", ["any", ["==", ["geometry-type"], "Polygon"], ["==", ["geometry-type"], "MultiPolygon"]], ["!=", ["get", "name"], null]]"""),
        )
    }

    @Test
    fun propertiesUsedInOtherWaysAreNotGuessed() {
        // `>=` is not a comparison the check understands, so nothing may be concluded from it.
        assertFalse(never("""["all", [">=", ["get", "speed"], 100], ["==", ["get", "speed"], 50]]"""))
    }

    @Test
    fun missingPropertyCountsAsAValue() {
        assertFalse(never("""["==", ["get", "name"], null]"""))
        assertTrue(never("""["all", ["==", ["get", "name"], null], ["!=", ["get", "name"], null]]"""))
    }

    private val orm by lazy { JSONObject(File("src/main/assets/style/orm-style.json").readText()) }

    private fun layerIds(mode: MapMode, options: MapOptions = MapOptions()) =
        StyleBuilder.resolveLayers(orm, mode, options).layers.map { it.getString("id") }.toSet()

    @Test
    fun everyViewOfTheRealStyleResolves() {
        for (mode in MapMode.entries) {
            val resolved = StyleBuilder.resolveLayers(orm, mode, MapOptions())
            assertEquals("$mode", 0, resolved.unresolved)
            assertTrue("$mode has no layers", resolved.layers.isNotEmpty())
            resolved.layers.forEach { assertFalse("${it.getString("id")} in $mode", it.toString().contains("global-state")) }
        }
        assertNotEquals(layerIds(MapMode.STANDARD), layerIds(MapMode.SPEED))
    }

    @Test
    fun listStateSelectsCategories() {
        // `signals` and `pois` are lists of categories: the speed view shows speed signals only.
        val speed = StyleBuilder.resolveLayers(orm, MapMode.SPEED, MapOptions()).layers
        val signalFilters = speed.filter { it.optString("source-layer") == "railway_signals" }.map { it.opt("filter").toString() }
        assertTrue(signalFilters.isNotEmpty())
        assertTrue(signalFilters.any { it.contains("[\"literal\",[\"speed\"]]") })
        assertTrue(layerIds(MapMode.SPEED).none { it.startsWith("railway_symbols") })
        assertTrue(layerIds(MapMode.STANDARD).any { it.startsWith("railway_symbols") })
    }

    @Test
    fun optionsChooseTheLineColouring() {
        val state = StyleBuilder.resolveLayers(orm, MapMode.TRACK, MapOptions(trackLine = "loadingGauge")).state
        assertEquals("loading_gauge", state["tracks"])
        assertEquals("power", StyleBuilder.resolveLayers(orm, MapMode.ELECTRIFICATION, MapOptions(electrificationLine = "power")).state["tracks"])
        assertEquals("usage", StyleBuilder.resolveLayers(orm, MapMode.STANDARD, MapOptions(trackLine = "loadingGauge")).state["tracks"])
        assertNotEquals(layerIds(MapMode.TRACK), layerIds(MapMode.TRACK, MapOptions(trackLine = "loadingGauge")))
    }

    @Test
    fun viewsMatchTheWebsite() {
        // prepare_style.py copies the website's views (knownStyles) into legend.json.
        val legend = JSONObject(File("src/main/assets/style/legend.json").readText())
        for (mode in MapMode.entries) {
            val website = legend.getJSONObject(mode.id).getJSONObject("state")
            assertEquals("$mode", website.keys().asSequence().toSet(), mode.globalState.keys)
            for ((key, value) in mode.globalState) {
                val expected = website.get(key)
                val actual = if (value is List<*>) JSONArray(value) else value
                assertEquals("$mode $key", expected.toString(), actual.toString())
            }
        }
    }
}
