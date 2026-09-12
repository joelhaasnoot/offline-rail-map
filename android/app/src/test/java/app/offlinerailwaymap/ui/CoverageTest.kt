// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap.ui

import app.offlinerailwaymap.TestPacks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.maplibre.android.geometry.LatLngBounds

class CoverageTest {
    /** A viewport of roughly a city at zoom 12, centred on the given point. */
    private fun viewportAround(point: Pair<Double, Double>, halfSize: Double = 0.05): LatLngBounds =
        LatLngBounds.from(point.first + halfSize, point.second + halfSize, point.first - halfSize, point.second - halfSize)

    private val installedNl = listOf(TestPacks.installed(TestPacks.netherlands))
    private val available = listOf(TestPacks.netherlands, TestPacks.belgium, TestPacks.benelux)

    @Test
    fun areaInsideAnInstalledPackIsCovered() {
        val result = coverageFor(viewportAround(TestPacks.amsterdam), 12.0, installedNl, available)
        assertEquals(Coverage.Covered, result)
    }

    @Test
    fun brusselsIsMissingAndSuggestsBelgiumEvenThoughItIsInsideTheDutchBbox() {
        val result = coverageFor(viewportAround(TestPacks.brussels), 12.0, installedNl, available)
        assertTrue(result is Coverage.Missing)
        assertEquals("belgium", (result as Coverage.Missing).suggested?.id)
    }

    @Test
    fun smallestPackContainingThePointIsSuggested() {
        // Both Belgium and Benelux contain Brussels; Belgium is the smaller pack.
        val result = coverageFor(viewportAround(TestPacks.brussels), 12.0, installedNl, available.reversed())
        assertEquals("belgium", (result as Coverage.Missing).suggested?.id)
    }

    @Test
    fun areaNobodyCoversIsMissingWithoutSuggestion() {
        val result = coverageFor(viewportAround(TestPacks.copenhagen), 12.0, installedNl, available)
        assertEquals(Coverage.Missing(null), result)
    }

    @Test
    fun installedPacksAreNeverSuggested() {
        val installed = listOf(TestPacks.installed(TestPacks.netherlands), TestPacks.installed(TestPacks.belgium))
        assertEquals(Coverage.Covered, coverageFor(viewportAround(TestPacks.brussels), 12.0, installed, available))
    }

    @Test
    fun viewportTouchingAPackAtItsEdgeIsCovered() {
        // Centre just outside the polygon but a corner inside it.
        val viewport = LatLngBounds.from(51.5, 4.0, 51.2, 3.7)
        assertEquals(Coverage.Covered, coverageFor(viewport, 10.0, installedNl, available))
    }

    @Test
    fun zoomedOutViewsNeverShowTheBanner() {
        val result = coverageFor(viewportAround(TestPacks.copenhagen, halfSize = 20.0), 3.0, installedNl, available)
        assertEquals(Coverage.Covered, result)
    }

    @Test
    fun noInstalledPacksIsHandledElsewhere() {
        assertEquals(Coverage.Covered, coverageFor(viewportAround(TestPacks.copenhagen), 12.0, emptyList(), available))
        assertEquals(Coverage.Covered, coverageFor(null, 12.0, installedNl, available))
    }
}
