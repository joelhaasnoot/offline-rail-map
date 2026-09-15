// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.map

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LegendTest {
    private val sep = "\u001E"

    private val lines = JSONObject(
        """{"id":"railway_line_high","type":"line","source":"high","source-layer":"railway_line_high","minzoom":7}""",
    )
    private val lineCasing = JSONObject(
        """{"id":"railway_line_high_casing","type":"line","source":"high","source-layer":"railway_line_high","minzoom":7}""",
    )
    private val signals = JSONObject(
        """{"id":"signals","type":"symbol","source":"openrailwaymap_signals","source-layer":"signals_railway_signals",
            "minzoom":13,"layout":{"icon-image":["get","feature0"],"symbol-placement":"line","icon-offset":[0,1],"text-padding":2}}""",
    )

    private val legendView = JSONObject(
        """{"countries":["DE"],"sourceLayers":{
          "high-railway_line_high":{"key":["usage"],"features":[
            {"legend":"Main line","type":"line","properties":{"usage":"main"},"keys":["main"]},
            {"legend":"Standard gauge","type":"line","properties":{"gauge0":"1435"},"mapState":{"trackRailwayLine":"gauge"},"keys":[""]},
            {"legend":"Siding","type":"line","minzoom":14,"properties":{"usage":"siding"},"keys":["siding"]},
            {"legend":"Ferry","type":"line","properties":{"feature":"ferry"},"keys":[]}
          ]},
          "openrailwaymap_signals-signals_railway_signals":{"key":["railway","feature0"],"matchKeys":[["railway"]],"features":[
            {"legend":"Distant signal","type":"point","country":"DE","properties":{"railway":"signal","feature0":"de/vr0"},
             "variants":[{"legend":"with repeater","properties":{"feature0":"de/vr0-repeater"}}],
             "keys":["signal${sep}de/vr0"]}
          ]}
        }}""",
    )

    private val gaugeState = mapOf<String, Any?>("trackRailwayLine" to "gauge")

    @Test
    fun keyPartBehavesLikeJavaScriptString() {
        assertEquals("", Legend.keyPart(null))
        assertEquals("", Legend.keyPart(JSONObject.NULL))
        assertEquals("true", Legend.keyPart(true))
        assertEquals("100", Legend.keyPart(100.0))
        assertEquals("1.5", Legend.keyPart(1.5))
        assertEquals("main", Legend.keyPart("main"))
    }

    @Test
    fun keyPartNormalisesPlaceholdersAndSuffixes() {
        assertEquals("at/speed-{}", Legend.keyPart("at/speed-{80}"))
        assertEquals("de/zs3-{}-{90}", Legend.keyPart("de/zs3-{80}-{90}")) // only the first placeholder, as upstream
        assertEquals("de/hp|de/ks", Legend.keyPart("de/hp@1|de/ks@2"))
    }

    @Test
    fun featureKeysJoinKeyPartsAndAddMatchKeys() {
        val source = legendView.getJSONObject("sourceLayers").getJSONObject("openrailwaymap_signals-signals_railway_signals")
        val props = mapOf("railway" to "signal", "feature0" to "de/vr0")
        assertEquals(setOf("signal${sep}de/vr0", "signal"), Legend.featureKeys(source) { props[it] })
    }

    @Test
    fun featureKeysWithoutKeyPropertiesIsTheEmptyKey() {
        val source = JSONObject("""{"key":[],"features":[]}""")
        assertEquals(setOf(""), Legend.featureKeys(source) { null })
    }

    @Test
    fun entriesFollowZoomAndMapOptions() {
        val entries = Legend.entries(legendView, listOf(lines, signals), gaugeState, zoom = 12, inView = null)
        assertEquals(listOf("Main line", "Standard gauge", "Ferry"), entries.map { it.label })

        val loadingGauge = Legend.entries(legendView, listOf(lines), mapOf("trackRailwayLine" to "loadingGauge"), 12, null)
        assertFalse(loadingGauge.any { it.label == "Standard gauge" })

        val zoomedIn = Legend.entries(legendView, listOf(lines, signals), gaugeState, zoom = 14, inView = null)
        assertEquals(
            listOf("(DE) Distant signal, with repeater", "Main line", "Standard gauge", "Siding", "Ferry"),
            zoomedIn.map { it.label },
        )
    }

    @Test
    fun symbolsComeBeforeLines() {
        // Style order puts the lines first; the key lists the signal above them anyway.
        val entries = Legend.entries(legendView, listOf(lines, signals), gaugeState, 14, null)
        assertEquals("openrailwaymap_signals-signals_railway_signals", entries.first().sourceName)
        assertEquals(setOf("high-railway_line_high"), entries.drop(1).map { it.sourceName }.toSet())
    }

    @Test
    fun layersSharingDataAreListedOnce() {
        val entries = Legend.entries(legendView, listOf(lines, lineCasing), gaugeState, 12, null)
        assertEquals(3, entries.size)
    }

    @Test
    fun onScreenFilterUsesFeatureKeys() {
        val inView = mapOf("high-railway_line_high" to setOf("main"))
        val entries = Legend.entries(legendView, listOf(lines, signals), gaugeState, 14, inView)
        // "Ferry" lists no keys, so it matches any line on screen; "Standard gauge" needs the empty key,
        // which only features of a source layer without key properties produce.
        assertEquals(listOf("Main line", "Ferry"), entries.map { it.label })

        val signalsOnly = Legend.entries(legendView, listOf(lines, signals), gaugeState, 14,
            mapOf("openrailwaymap_signals-signals_railway_signals" to setOf("signal${sep}de/vr0")))
        assertEquals(listOf("(DE) Distant signal, with repeater"), signalsOnly.map { it.label })

        assertTrue(Legend.entries(legendView, listOf(lines, signals), gaugeState, 14, emptyMap()).isEmpty())
    }

    @Test
    fun samplesArePlacedInTheirRowAndVariantsShareIt() {
        val entries = Legend.entries(legendView, listOf(lines, signals), gaugeState, 14, null)
        val signal = entries[0]
        assertEquals(2, signal.features.size)
        val first = signal.features[0].getJSONObject("geometry").getJSONArray("coordinates")
        val second = signal.features[1].getJSONObject("geometry").getJSONArray("coordinates")
        assertEquals(0.0, first.getDouble(1), 1e-12)
        assertEquals(Legend.degrees(-2.125), first.getDouble(0), 1e-12)
        assertEquals(Legend.degrees(-1.375), second.getDouble(0), 1e-12)
        assertEquals("de/vr0-repeater", signal.features[1].getJSONObject("properties").getString("feature0"))
        assertEquals("signal", signal.features[1].getJSONObject("properties").getString("railway"))

        val siding = entries[3]
        assertEquals("Siding", siding.label)
        val geometry = siding.features.single().getJSONObject("geometry")
        assertEquals("LineString", geometry.getString("type"))
        val coords = geometry.getJSONArray("coordinates")
        val y = Legend.degrees(-3 * Legend.ROW_SPACING)
        assertEquals(Legend.degrees(-2.5), coords.getJSONArray(0).getDouble(0), 1e-12)
        assertEquals(Legend.degrees(-1.0), coords.getJSONArray(1).getDouble(0), 1e-12)
        assertEquals(y, coords.getJSONArray(0).getDouble(1), 1e-12)
        assertEquals(y to Legend.degrees(Legend.ROW_CENTER_X), Legend.rowCenter(3))
    }

    @Test
    fun legendStyleReadsFromOneGeoJsonSourcePerDataSet() {
        val entries = Legend.entries(legendView, listOf(lines, signals), gaugeState, 14, null)
        val style = Legend.style(listOf(lines, lineCasing, signals), 14, entries, "asset://sprites/symbols", "asset://font/{fontstack}/{range}.pbf")
        val layers = style.getJSONArray("layers")
        assertEquals(3, layers.length())
        val signalLayer = layers.getJSONObject(2)
        assertEquals("openrailwaymap_signals-signals_railway_signals", signalLayer.getString("source"))
        assertFalse(signalLayer.has("source-layer"))
        assertFalse(signalLayer.has("minzoom"))
        val layout = signalLayer.getJSONObject("layout")
        assertEquals("line-center", layout.getString("symbol-placement"))
        assertFalse(layout.has("icon-offset"))
        assertFalse(layout.has("text-padding"))

        val sources = style.getJSONObject("sources")
        assertEquals(2, sources.length())
        assertEquals(4, sources.getJSONObject("high-railway_line_high").getJSONObject("data").getJSONArray("features").length())
        assertEquals(2, sources.getJSONObject("openrailwaymap_signals-signals_railway_signals").getJSONObject("data").getJSONArray("features").length())
    }

    @Test
    fun legendStyleSkipsLayersHiddenAtTheZoom() {
        val style = Legend.style(listOf(lines, signals), 10, emptyList(), "s", "g")
        assertEquals(1, style.getJSONArray("layers").length())
        assertEquals(1, style.getJSONObject("sources").length())
    }
}
