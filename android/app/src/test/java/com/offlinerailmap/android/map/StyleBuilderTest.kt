// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.map

import org.json.JSONArray
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

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
}
