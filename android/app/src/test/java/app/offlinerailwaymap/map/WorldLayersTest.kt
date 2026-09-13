// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap.map

import app.offlinerailwaymap.TestPacks
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorldLayersTest {
    private fun layer(json: String) = JSONObject(json)

    @Test
    fun worldCopyReadsFromWorldSourceAndIsCapped() {
        val water = layer("""{"id":"water","type":"fill","source":"basemap","source-layer":"water"}""")
        val copy = WorldLayers.worldCopy(water)!!
        assertEquals("water__world", copy.getString("id"))
        assertEquals("world", copy.getString("source"))
        assertEquals(WorldLayers.MAX_VISIBLE_ZOOM, copy.getDouble("maxzoom"), 0.0)
        assertEquals("basemap", water.getString("source")) // original untouched
    }

    @Test
    fun worldCopyKeepsALowerMaxzoom() {
        val country = layer("""{"id":"place-country","type":"symbol","source":"basemap","maxzoom":8}""")
        assertEquals(8.0, WorldLayers.worldCopy(country)!!.getDouble("maxzoom"), 0.0)
    }

    @Test
    fun layersThatOnlyAppearWhenZoomedInAreSkipped() {
        val roadNames = layer("""{"id":"road-name","type":"symbol","source":"basemap","minzoom":14}""")
        assertNull(WorldLayers.worldCopy(roadNames))
    }

    @Test
    fun labelsPreferEnglishNames() {
        val city = layer("""{"id":"place-city","type":"symbol","source":"basemap","layout":{"text-field":["get","name"]}}""")
        val field = WorldLayers.worldCopy(city)!!.getJSONObject("layout").getJSONArray("text-field")
        assertEquals("""["coalesce",["get","name:en"],["get","name"]]""", field.toString())
    }

    @Test
    fun preferEnglishReachesNestedExpressionsAndLeavesOthersAlone() {
        val expr = JSONArray("""["concat",["get","name"]," ",["get","ref"]]""")
        assertEquals(
            """["concat",["coalesce",["get","name:en"],["get","name"]]," ",["get","ref"]]""",
            WorldLayers.preferEnglish(expr).toString(),
        )
        assertEquals("North America", WorldLayers.preferEnglish("North America"))
    }

    @Test
    fun noMaskWithoutPacks() {
        assertNull(WorldLayers.maskGeometry(emptyList()))
    }

    @Test
    fun maskUsesEveryRingAndClosesThem() {
        val mask = WorldLayers.maskGeometry(listOf(TestPacks.netherlands, TestPacks.benelux))!!
        assertEquals("MultiPolygon", mask.getString("type"))
        val polygons = mask.getJSONArray("coordinates")
        assertEquals(4, polygons.length()) // Netherlands + Benelux (Netherlands, Belgium, Luxembourg)
        for (i in 0 until polygons.length()) {
            val ring = polygons.getJSONArray(i).getJSONArray(0)
            assertEquals(ring.getJSONArray(0).toString(), ring.getJSONArray(ring.length() - 1).toString())
        }
        assertEquals("Feature", WorldLayers.maskSource(mask).getJSONObject("data").getString("type"))
    }

    @Test
    fun maskFallsBackToTheBoundingBox() {
        val pack = TestPacks.netherlands.copy(coverage = emptyList())
        val ring = WorldLayers.maskGeometry(listOf(pack))!!.getJSONArray("coordinates").getJSONArray(0).getJSONArray(0)
        assertEquals(5, ring.length())
        assertTrue(ring.toString().contains("[3.3,50.75]"))
        assertTrue(ring.toString().contains("[7.2,53.5]"))
    }

    @Test
    fun worldLabelsAreHiddenInsideDownloadedRegions() {
        val mask = WorldLayers.maskGeometry(listOf(TestPacks.netherlands))!!
        val city = layer("""{"id":"place-city__world","type":"symbol","source-layer":"place","filter":["==",["get","class"],"city"]}""")
        val filter = WorldLayers.hideInsideMask(city, mask).getJSONArray("filter")
        assertEquals("all", filter.getString(0))
        assertEquals("""["==",["get","class"],"city"]""", filter.getJSONArray(1).toString())
        assertEquals("!", filter.getJSONArray(2).getString(0))
        assertEquals("within", filter.getJSONArray(2).getJSONArray(1).getString(0))

        val noFilter = layer("""{"id":"water-name__world","type":"symbol","source-layer":"water_name"}""")
        assertEquals("!", WorldLayers.hideInsideMask(noFilter, mask).getJSONArray("filter").getString(0))
    }

    @Test
    fun continentLabelsStayVisibleEverywhere() {
        val mask = WorldLayers.maskGeometry(listOf(TestPacks.netherlands))!!
        val continent = layer("""{"id":"place-continent__world","type":"symbol","source-layer":"place"}""")
        assertTrue(!WorldLayers.hideInsideMask(continent, mask).has("filter"))
    }
}
