// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.PrimaryScrollableTabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.offlinerailwaymap.data.DownloadState
import app.offlinerailwaymap.data.InstalledPack
import app.offlinerailwaymap.data.PackInfo
import app.offlinerailwaymap.data.PackStore
import app.offlinerailwaymap.map.MapMode
import app.offlinerailwaymap.map.MapOptions

fun formatBytes(bytes: Long): String = when {
    bytes >= 1_000_000_000 -> "%.1f GB".format(bytes / 1e9)
    bytes >= 1_000_000 -> "%.0f MB".format(bytes / 1e6)
    else -> "%.0f kB".format(bytes / 1e3)
}

enum class SheetTab(val label: String) { KEY("Key"), PACKS("Country packs"), OPTIONS("Map options"), ABOUT("About") }

/** The single bottom sheet behind the menu button: key, country packs, map options and about. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainSheet(
    initialTab: SheetTab,
    mode: MapMode,
    options: MapOptions,
    legendContext: LegendContext?,
    onChange: (MapOptions) -> Unit,
    onDismiss: () -> Unit,
    onShowPack: (InstalledPack) -> Unit,
) {
    var tab by remember { mutableStateOf(initialTab) }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.navigationBarsPadding()) {
            PrimaryScrollableTabRow(selectedTabIndex = tab.ordinal, edgePadding = 0.dp) {
                SheetTab.entries.forEach { t ->
                    Tab(selected = tab == t, onClick = { tab = t }, text = { Text(t.label) })
                }
            }
            Spacer(Modifier.height(12.dp))
            when (tab) {
                SheetTab.KEY -> KeyContent(mode, options, legendContext)
                SheetTab.PACKS -> PacksContent(onShowPack)
                SheetTab.OPTIONS -> OptionsContent(options, onChange)
                SheetTab.ABOUT -> AboutContent()
            }
        }
    }
}

@Composable
private fun PacksContent(onShowPack: (InstalledPack) -> Unit) {
    val available by PackStore.available.collectAsState()
    val installed by PackStore.installed.collectAsState()
    val downloads by PackStore.downloads.collectAsState()
    val error by PackStore.manifestError.collectAsState()
    val loading by PackStore.manifestLoading.collectAsState()

    LaunchedEffect(Unit) {
        if (available.isEmpty()) {
            PackStore.refreshManifest()
        }
    }

    // Installed packs that are no longer in the manifest still need to be listed.
    val installedById = installed.associateBy { it.info.id }
    val rows: List<PackInfo> = (available + installed.map { it.info }.filter { p -> available.none { it.id == p.id } })
        .sortedWith(compareBy({ it.regionLabel }, { it.name }))

    val listState = rememberLazyListState()
    // The error is inserted above the first row; the list would otherwise stay anchored to that
    // row and leave the message scrolled out of view.
    LaunchedEffect(error) {
        if (error != null) {
            listState.animateScrollToItem(0)
        }
    }

    Column(Modifier.padding(horizontal = 16.dp)) {
        PullToRefreshBox(
            isRefreshing = loading,
            onRefresh = { PackStore.refreshManifest() },
            modifier = Modifier.heightIn(max = 520.dp),
        ) {
            // A minimum height keeps the list pullable while it is still empty.
            LazyColumn(Modifier.fillMaxWidth().heightIn(min = 160.dp), state = listState) {
                if (error != null) {
                    item(key = "error") {
                        Text(
                            "Could not load the pack list: $error. Pull down to try again.",
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.padding(vertical = 8.dp),
                        )
                    }
                }
                items(rows, key = { it.id }) { pack ->
                    PackRow(
                        pack = pack,
                        installed = installedById[pack.id],
                        state = downloads[pack.id],
                        onShow = onShowPack,
                    )
                    HorizontalDivider()
                }
            }
        }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun PackRow(pack: PackInfo, installed: InstalledPack?, state: DownloadState?, onShow: (InstalledPack) -> Unit) {
    val updateAvailable = installed != null && installed.info.version < pack.version
    // Describe what is on the device; the update line below describes the newer version.
    val shown = installed?.info ?: pack
    Column(Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(pack.name, style = MaterialTheme.typography.titleMedium)
                val details = buildString {
                    append(shown.regionLabel)
                    append(" · ")
                    append(formatBytes(shown.totalBytes))
                    if (shown.dataDate.isNotEmpty()) {
                        append(" · data ")
                        append(shown.dataDate.take(10))
                    }
                }
                Text(details, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            when {
                state is DownloadState.Running -> TextButton(onClick = { PackStore.cancel(pack.id) }) { Text("Cancel") }
                installed != null -> {
                    TextButton(onClick = { PackStore.delete(pack.id) }) { Text("Delete") }
                    OutlinedButton(onClick = { onShow(installed) }) { Text("Show") }
                }
                else -> Button(onClick = { PackStore.download(pack) }) { Text("Download") }
            }
        }
        when (state) {
            is DownloadState.Running -> {
                Spacer(Modifier.height(6.dp))
                LinearProgressIndicator(progress = { state.fraction }, modifier = Modifier.fillMaxWidth())
                Text(
                    (if (installed != null) "Updating " else "") +
                        "${state.stage}: ${formatBytes(state.bytesDone)} of ${formatBytes(state.bytesTotal)}",
                    style = MaterialTheme.typography.labelSmall,
                )
            }
            is DownloadState.Failed -> {
                Spacer(Modifier.height(4.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        (if (installed != null) "Update failed: " else "Failed: ") + state.message,
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = { PackStore.dismissError(pack.id) }) { Text("Dismiss") }
                }
            }
            null -> {}
        }
        if (updateAvailable && state !is DownloadState.Running) {
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                val newer = buildString {
                    append("Update available")
                    if (pack.dataDate.isNotEmpty()) {
                        append(": data ")
                        append(pack.dataDate.take(10))
                    }
                    append(" · ")
                    append(formatBytes(pack.totalBytes))
                }
                Text(
                    newer,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.weight(1f),
                )
                Button(onClick = { PackStore.download(pack) }) { Text("Update") }
            }
        }
    }
}

@Composable
private fun OptionsContent(options: MapOptions, onChange: (MapOptions) -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp).verticalScroll(rememberScrollState())) {
            Text("Infrastructure", style = MaterialTheme.typography.titleSmall)
            SwitchRow("Under construction", options.showConstruction) { onChange(options.copy(showConstruction = it)) }
            SwitchRow("Proposed", options.showProposed) { onChange(options.copy(showProposed = it)) }
            SwitchRow("Abandoned", options.showAbandoned) { onChange(options.copy(showAbandoned = it)) }
            SwitchRow("Razed", options.showRazed) { onChange(options.copy(showRazed = it)) }

            Spacer(Modifier.height(8.dp))
            Text("Station labels at low zoom", style = MaterialTheme.typography.titleSmall)
            RadioRow("Short label", options.stationLowZoomLabel == "label") { onChange(options.copy(stationLowZoomLabel = "label")) }
            RadioRow("Full name", options.stationLowZoomLabel == "name") { onChange(options.copy(stationLowZoomLabel = "name")) }
            RadioRow("None", options.stationLowZoomLabel == "none") { onChange(options.copy(stationLowZoomLabel = "none")) }

            Spacer(Modifier.height(8.dp))
            Text("Electrification colours", style = MaterialTheme.typography.titleSmall)
            RadioRow("Voltage and frequency", options.electrificationLine == "voltageFrequency") { onChange(options.copy(electrificationLine = "voltageFrequency")) }
            RadioRow("Maximum current", options.electrificationLine == "maximumCurrent") { onChange(options.copy(electrificationLine = "maximumCurrent")) }
            RadioRow("Power supply", options.electrificationLine == "power") { onChange(options.copy(electrificationLine = "power")) }

            Spacer(Modifier.height(8.dp))
            Text("Gauge view shows", style = MaterialTheme.typography.titleSmall)
            RadioRow("Track gauge", options.trackLine == "gauge") { onChange(options.copy(trackLine = "gauge")) }
            RadioRow("Loading gauge", options.trackLine == "loadingGauge") { onChange(options.copy(trackLine = "loadingGauge")) }
            RadioRow("Track class", options.trackLine == "trackClass") { onChange(options.copy(trackLine = "trackClass")) }

            Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, onChecked: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChecked)
    }
}

@Composable
private fun RadioRow(label: String, selected: Boolean, onSelect: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().selectable(selected = selected, onClick = onSelect).padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onSelect)
        Text(label)
    }
}
