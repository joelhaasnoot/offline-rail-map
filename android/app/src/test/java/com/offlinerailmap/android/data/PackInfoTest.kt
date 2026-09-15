// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.data

import com.offlinerailmap.android.TestPacks
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PackInfoTest {
    @Test
    fun containsUsesTheRegionPolygonNotTheBoundingBox() {
        val nl = TestPacks.netherlands
        assertTrue(nl.contains(TestPacks.amsterdam.first, TestPacks.amsterdam.second))
        assertTrue(nl.contains(TestPacks.maastricht.first, TestPacks.maastricht.second))
        // Brussels lies inside the Netherlands bounding box but outside its polygon.
        val (lat, lon) = TestPacks.brussels
        assertTrue(lon >= nl.bbox[0] && lon <= nl.bbox[2] && lat >= nl.bbox[1] && lat <= nl.bbox[3])
        assertFalse(nl.contains(lat, lon))
    }

    @Test
    fun containsFallsBackToBoundingBoxWithoutPolygon() {
        val nl = TestPacks.netherlands.copy(coverage = emptyList())
        assertTrue(nl.contains(TestPacks.brussels.first, TestPacks.brussels.second))
        assertFalse(nl.contains(TestPacks.copenhagen.first, TestPacks.copenhagen.second))
    }

    @Test
    fun multiPolygonCoverageChecksEveryRing() {
        val benelux = TestPacks.benelux
        assertTrue(benelux.contains(TestPacks.brussels.first, TestPacks.brussels.second))
        assertTrue(benelux.contains(TestPacks.amsterdam.first, TestPacks.amsterdam.second))
        assertTrue(benelux.contains(49.6, 6.1)) // Luxembourg
        assertFalse(benelux.contains(TestPacks.copenhagen.first, TestPacks.copenhagen.second))
    }

    @Test
    fun jsonRoundTripKeepsCoverageAndBbox() {
        val original = TestPacks.belgium
        val restored = PackInfo.fromJson(JSONObject(original.toJson().toString()))
        assertEquals(original.id, restored.id)
        assertEquals(original.name, restored.name)
        assertArrayEquals(original.bbox, restored.bbox, 1e-9)
        assertEquals(original.coverage.size, restored.coverage.size)
        assertEquals(original.coverage[0].size, restored.coverage[0].size)
        assertTrue(restored.contains(TestPacks.brussels.first, TestPacks.brussels.second))
        assertEquals(null, restored.basemapUrl)
    }

    @Test
    fun manifestWithoutCoverageStillParses() {
        val json = JSONObject(
            """{"id":"x","name":"X","region":"r","railway_url":"u","railway_bytes":1,"basemap_url":null,
               "basemap_bytes":0,"bbox":[0,0,1,1],"data_date":"","version":2}""",
        )
        val info = PackInfo.fromJson(json)
        assertTrue(info.coverage.isEmpty())
        assertTrue(info.contains(0.5, 0.5))
        assertEquals(2, info.version)
    }

    @Test
    fun regionLabelMakesGeofabrikIdsReadable() {
        assertEquals("North America", PackInfo.regionLabelFromId("north-america"))
        assertEquals("Europe", PackInfo.regionLabelFromId("europe"))
        assertEquals("Australia Oceania", PackInfo.regionLabelFromId("australia-oceania"))
        assertEquals("", PackInfo.regionLabelFromId(""))
    }

    @Test
    fun regionLabelPrefersTheManifestName() {
        val canada = TestPacks.netherlands.copy(id = "canada", region = "north-america")
        assertEquals("North America", canada.regionLabel)
        val oceania = canada.copy(region = "australia-oceania", regionName = "Australia and Oceania")
        assertEquals("Australia and Oceania", oceania.regionLabel)
        val restored = PackInfo.fromJson(JSONObject(oceania.toJson().toString()))
        assertEquals("Australia and Oceania", restored.regionLabel)
    }
}
