// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.offlinerailwaymap.map.Legend
import app.offlinerailwaymap.map.LegendData
import app.offlinerailwaymap.map.LegendRenderer
import app.offlinerailwaymap.map.MapMode
import app.offlinerailwaymap.map.MapOptions
import app.offlinerailwaymap.map.StyleBuilder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** What the main map shows right now, captured when the sheet opens. */
data class LegendContext(
    val zoom: Int,
    /** Legend source name to the feature keys rendered on screen. */
    val inView: Map<String, Set<String>>,
)

private class KeyModel(val entries: List<Legend.Entry>, val styleJson: String, val styleKey: String)

@Composable
fun KeyContent(mode: MapMode, options: MapOptions, legendContext: LegendContext?) {
    val context = LocalContext.current
    var showAll by rememberSaveable { mutableStateOf(false) }
    val renderer = remember { LegendRenderer(context) }
    DisposableEffect(renderer) {
        onDispose { renderer.close() }
    }

    if (legendContext == null) {
        Box(Modifier.fillMaxWidth().height(160.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator()
        }
        return
    }
    val zoom = legendContext.zoom

    val model by produceState<KeyModel?>(null, mode, options, zoom, showAll, legendContext) {
        value = null
        value = withContext(Dispatchers.Default) {
            val orm = StyleBuilder.ormLayers(context, mode, options)
            val view = LegendData.view(context, mode.id)
            val inView = if (showAll) null else legendContext.inView
            val entries = Legend.entries(view, orm.layers, orm.state, zoom, inView)
            val style = Legend.style(orm.layers, zoom, entries, orm.sprite, orm.glyphs).toString()
            KeyModel(entries, style, "${mode.id}|$options|$zoom|$showAll|${inView?.hashCode()}")
        }
    }

    Column(Modifier.padding(horizontal = 16.dp)) {
        Text(
            "What the colours and symbols mean in the ${mode.label} view at zoom $zoom.",
            style = MaterialTheme.typography.bodyMedium,
        )
        Row {
            FilterChip(selected = !showAll, onClick = { showAll = false }, label = { Text("On screen") })
            Spacer(Modifier.width(8.dp))
            FilterChip(selected = showAll, onClick = { showAll = true }, label = { Text("Everything") })
        }
        val current = model
        when {
            current == null -> Box(Modifier.fillMaxWidth().height(160.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            current.entries.isEmpty() -> Text(
                if (showAll) {
                    "This view has nothing to explain at this zoom level."
                } else {
                    "Nothing on screen needs explaining. Move the map to railway lines, or choose Everything."
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 24.dp),
            )
            else -> LazyColumn(Modifier.heightIn(max = 520.dp)) {
                itemsIndexed(current.entries, key = { index, _ -> "${current.styleKey}#$index" }) { index, entry ->
                    KeyRow(renderer, current, index, entry)
                }
            }
        }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun KeyRow(renderer: LegendRenderer, model: KeyModel, index: Int, entry: Legend.Entry) {
    val bitmap by produceState(renderer.cached(model.styleKey, index), model.styleKey, index) {
        if (value == null) {
            value = renderer.render(model.styleKey, model.styleJson, index)
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Box(Modifier.size(renderer.widthDp.dp, renderer.heightDp.dp), contentAlignment = Alignment.Center) {
            bitmap?.let {
                Image(it.asImageBitmap(), contentDescription = null, modifier = Modifier.size(renderer.widthDp.dp, renderer.heightDp.dp))
            }
        }
        Spacer(Modifier.width(12.dp))
        Text(entry.label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
    }
}
