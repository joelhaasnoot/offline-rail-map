// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap.map

import app.offlinerailwaymap.map.ComposedImage.Part
import app.offlinerailwaymap.map.ComposedImage.Position
import app.offlinerailwaymap.map.ComposedImage.SpriteImage
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ComposedImageTest {
    /** Icons a (10x20), b (15x6) and c (4x4); their SDF icons have 3 pixels of padding. */
    private val sprite: Map<String, SpriteImage> = buildMap {
        for ((name, size) in mapOf("a" to (10 to 20), "b" to (15 to 6), "c" to (4 to 4))) {
            put(name, SpriteImage(0, 0, size.first, size.second, 1.0, false))
            put("sdf:$name", SpriteImage(0, 0, size.first + 6, size.second + 6, 1.0, true))
        }
    }

    /** "width height x,y,sdfX,sdfY;..." as the website's layoutImages computes it. */
    private fun describe(layout: ComposedImage.Layout?): String {
        assertNotNull(layout)
        val images = layout!!.images.joinToString(";") { "${num(it.x)},${num(it.y)},${it.sdfX},${it.sdfY}" }
        return "${num(layout.width)} ${num(layout.height)} $images"
    }

    /** JavaScript number formatting: no ".0" on whole numbers. */
    private fun num(value: Double): String = if (value == Math.floor(value)) value.toLong().toString() else value.toString()

    // Expected values below were produced by running upstream's loadImages/layoutImages in Node.

    @Test
    fun singleImageIsPaddedToItsSdfSizeAndIgnoresPosition() {
        assertEquals("16 26 3,3,0,0", describe(ComposedImage.layout("a", sprite)))
        assertEquals("16 26 3,3,0,0", describe(ComposedImage.layout("a@top", sprite)))
    }

    @Test
    fun centerIsTheDefaultPosition() {
        assertEquals("21 26 5.5,3,2,0;3,10,0,7", describe(ComposedImage.layout("a|b", sprite)))
        assertEquals("21 26 5.5,3,2,0;3,10,0,7", describe(ComposedImage.layout("a|b@center", sprite)))
    }

    @Test
    fun bottomAndTopStackVertically() {
        assertEquals("21 32 5.5,3,2,0;3,23,0,20", describe(ComposedImage.layout("a|b@bottom", sprite)))
        assertEquals("21 32 5.5,9,2,6;3,3,0,0", describe(ComposedImage.layout("a|b@top", sprite)))
    }

    @Test
    fun rightAndLeftStackHorizontallyWithUpstreamsHalfWidthLeftOffset() {
        assertEquals("31 26 3,3,0,0;13,10,10,7", describe(ComposedImage.layout("a|b@right", sprite)))
        assertEquals("25 26 10.5,3,7,0;3,10,0,7", describe(ComposedImage.layout("a|b@left", sprite)))
    }

    @Test
    fun laterPartsArePlacedRelativeToEverythingBefore() {
        assertEquals("23 32 7.5,9,4,6;5,3,2,0;3,14,0,11", describe(ComposedImage.layout("a|b@top|c@left", sprite)))
        assertEquals(
            "35 30 8,10,5,7;3,3,0,0;13.5,23,10,20;28,13,25,10",
            describe(ComposedImage.layout("b|a@left|c@bottom|c@right", sprite)),
        )
    }

    @Test
    fun parsesPartsAndPositions() {
        assertEquals(
            listOf(Part("fi/t-270", Position.CENTER), Part("fi/t-271-top-{1}", Position.CENTER)),
            ComposedImage.parse("fi/t-270|fi/t-271-top-{1}"),
        )
        assertEquals(
            listOf(Part("gb/route-feather-unknown", Position.CENTER), Part("gb/route-theatre-{U}", Position.BOTTOM)),
            ComposedImage.parse("gb/route-feather-unknown|gb/route-theatre-{U}@bottom"),
        )
    }

    @Test
    fun rejectsIdsTheWebsiteCannotParse() {
        assertNull(ComposedImage.parse(""))
        assertNull(ComposedImage.parse("a|"))
        assertNull(ComposedImage.parse("a@middle"))
        assertNull(ComposedImage.parse("a@bottom@top"))
    }

    @Test
    fun missingPartsOrSdfIconsGiveNoLayout() {
        assertNull(ComposedImage.layout("a|zzz@bottom", sprite))
        assertNull(ComposedImage.layout("a|b", sprite - "sdf:b"))
        assertNull(ComposedImage.layout("a@", sprite))
    }

    @Test
    fun compositeIds() {
        assertTrue(ComposedImage.isComposite("fi/t-270|fi/t-270-{2}"))
        assertTrue(ComposedImage.isComposite("au/LightRail/signals/PI/stop@bottom"))
        assertFalse(ComposedImage.isComposite("de/vr0"))
        assertFalse(ComposedImage.isComposite("signal"))
    }

    @Test
    fun findsCompositesInLegendJsonButNotInFeatureKeys() {
        val legend = JSONObject(
            """{"signals":{"sourceLayers":{"s":{"features":[
              {"legend":"x","properties":{"railway":"signal","feature0":"a|b@bottom"},
               "variants":[{"properties":{"feature0":"c@top"}}],"keys":["signala|b"]},
              {"legend":"y","properties":{"feature0":"a"}}
            ]}}}}""",
        )
        assertEquals(setOf("a|b@bottom", "c@top"), ComposedImage.composites(legend))
    }

    @Test
    fun componentsIncludeSdfIconsAndOtherPlaceholderValues() {
        val icons = sprite + mapOf(
            "d-{1}" to SpriteImage(1, 0, 1, 1, 1.0, false),
            "sdf:d-{1}" to SpriteImage(2, 0, 1, 1, 1.0, true),
            "d-{2}" to SpriteImage(3, 0, 1, 1, 1.0, false),
            "sdf:d-{2}" to SpriteImage(4, 0, 1, 1, 1.0, true),
            "e-{1}" to SpriteImage(5, 0, 1, 1, 1.0, false),
            "sdf:e-{1}" to SpriteImage(6, 0, 1, 1, 1.0, true),
        )
        val components = ComposedImage.components(listOf("a|d-{1}@bottom", "zzz|b", "@"), icons)
        val expected = listOf("a", "sdf:a", "b", "sdf:b", "d-{1}", "sdf:d-{1}", "d-{2}", "sdf:d-{2}").map { icons.getValue(it) }
        assertEquals(expected.toSet(), components)
    }

    @Test
    fun bandsGroupIconsIntoStripsOfLimitedHeight() {
        val a = SpriteImage(10, 0, 5, 10, 1.0, false)
        val b = SpriteImage(40, 4, 8, 20, 1.0, false)
        val c = SpriteImage(0, 30, 4, 4, 1.0, false)
        val tall = SpriteImage(7, 40, 3, 100, 1.0, false)
        assertEquals(
            listOf(
                ComposedImage.Band(10, 0, 48, 24, listOf(a, b)),
                ComposedImage.Band(0, 30, 4, 34, listOf(c)),
                ComposedImage.Band(7, 40, 10, 140, listOf(tall)),
            ),
            ComposedImage.bands(listOf(tall, c, b, a), maxHeight = 30),
        )
        assertTrue(ComposedImage.bands(emptyList(), 30).isEmpty())
    }

    /** The real catalogue: every icon a legend composite needs is found, in few strips. */
    @Test
    fun legendCatalogueComponentsCoverEveryLegendComposite() {
        val legend = JSONObject(File("src/main/assets/style/legend.json").readText())
        val assetSprite = ComposedImage.parseSprite(File("src/main/assets/sprites/symbols@2x.json").readText())
        val composites = ComposedImage.composites(legend)
        val components = ComposedImage.components(composites, assetSprite)
        for (id in composites) {
            val layout = ComposedImage.layout(id, assetSprite)
            assertNotNull(id, layout)
            for (placed in layout!!.images) {
                assertTrue(id, placed.image in components && placed.sdfImage in components)
            }
        }
        val bands = ComposedImage.bands(components, 512)
        assertEquals(components.size, bands.sumOf { it.images.size })
        assertTrue(bands.all { band -> band.images.all { it.x >= band.left && it.x + it.width <= band.right } })
    }

    @Test
    fun sdfPrefix() {
        assertTrue(ComposedImage.isSdf("sdf:a|b@bottom"))
        assertFalse(ComposedImage.isSdf("a|b@bottom"))
        assertEquals("a|b@bottom", ComposedImage.rawId("sdf:a|b@bottom"))
        assertEquals("a|b@bottom", ComposedImage.rawId("a|b@bottom"))
    }

    @Test
    fun composedSdfTakesTheLargestDistanceValue() {
        val small = mapOf(
            "p" to SpriteImage(0, 0, 1, 1, 1.0, false),
            "sdf:p" to SpriteImage(0, 0, 3, 3, 1.0, true),
            "q" to SpriteImage(0, 0, 1, 1, 1.0, false),
            "sdf:q" to SpriteImage(0, 0, 3, 3, 1.0, true),
        )
        val layout = ComposedImage.layout("p|q@right", small)!!
        assertEquals("4 3 1,1,0,0;2,1,1,0", describe(layout))
        val p = intArrayOf(10, 20, 30, 40, 200, 60, 70, 80, 90)
        val q = intArrayOf(100, 5, 5, 5, 250, 5, 5, 5, 5)
        assertArrayEquals(
            intArrayOf(
                10, 100, 30, 5,
                40, 200, 250, 5,
                70, 80, 90, 5,
            ),
            ComposedImage.composeSdf(layout, listOf(p, q)),
        )
    }

    @Test
    fun parsesSpriteIndex() {
        val parsed = ComposedImage.parseSprite(
            """{"a":{"x":1,"y":2,"width":3,"height":4,"pixelRatio":2},"sdf:a":{"x":5,"y":6,"width":7,"height":8,"pixelRatio":2,"sdf":true}}""",
        )
        assertEquals(SpriteImage(1, 2, 3, 4, 2.0, false), parsed["a"])
        assertEquals(SpriteImage(5, 6, 7, 8, 2.0, true), parsed["sdf:a"])
    }

    /** Every composed icon in legend.json, against the website's layout (see pipeline/composed_image_golden.mjs). */
    @Test
    fun matchesWebsiteLayoutForEveryLegendIcon() {
        for (suffix in listOf("", "@2x")) {
            val assetSprite = ComposedImage.parseSprite(File("src/main/assets/sprites/symbols$suffix.json").readText())
            val golden = javaClass.getResource("/composed-image/golden$suffix.tsv")!!.readText().trim().lines()
            assertTrue("golden$suffix.tsv is empty", golden.size > 100)
            for (line in golden) {
                val (id, width, height, images) = line.split("\t")
                val layout = ComposedImage.layout(id, assetSprite)
                assertEquals("$id$suffix", "$width $height $images", describe(layout))
                assertEquals("$id$suffix pixel ratio", if (suffix == "") 1.0 else 2.0, layout!!.pixelRatio, 0.0)
            }
        }
    }
}
