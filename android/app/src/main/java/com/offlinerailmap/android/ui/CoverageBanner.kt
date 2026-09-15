// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.offlinerailmap.android.data.DownloadState
import com.offlinerailmap.android.data.InstalledPack
import com.offlinerailmap.android.data.PackInfo
import com.offlinerailmap.android.data.PackStore
import org.maplibre.android.geometry.LatLngBounds

/** What the current viewport is showing in terms of pack coverage. */
sealed class Coverage {
    data object Covered : Coverage()
    data class Missing(val suggested: PackInfo?) : Coverage()
}

private fun intersects(b: LatLngBounds, bbox: DoubleArray): Boolean =
    !(bbox[0] > b.longitudeEast || bbox[2] < b.longitudeWest || bbox[1] > b.latitudeNorth || bbox[3] < b.latitudeSouth)

/** Zoomed out further than this, the viewport is so large that a coverage verdict is meaningless. */
private const val MIN_ZOOM_FOR_VERDICT = 6.0

fun coverageFor(viewport: LatLngBounds?, zoom: Double, installed: List<InstalledPack>, available: List<PackInfo>): Coverage {
    if (viewport == null || installed.isEmpty() || zoom < MIN_ZOOM_FOR_VERDICT) {
        return Coverage.Covered // the "no packs at all" card handles the empty case
    }
    // Centre plus the four corners: covered when any of them lies inside an installed pack.
    val c = viewport.center
    val probes = listOf(
        c.latitude to c.longitude,
        viewport.latitudeNorth to viewport.longitudeWest,
        viewport.latitudeNorth to viewport.longitudeEast,
        viewport.latitudeSouth to viewport.longitudeWest,
        viewport.latitudeSouth to viewport.longitudeEast,
    )
    val covered = installed.any { pack ->
        intersects(viewport, pack.info.bbox) && probes.any { (lat, lon) -> pack.info.contains(lat, lon) }
    }
    if (covered) {
        return Coverage.Covered
    }
    val installedIds = installed.map { it.info.id }.toSet()
    val suggestion = available
        .filter { it.id !in installedIds && it.contains(c.latitude, c.longitude) }
        // Prefer the smallest pack that contains the point (a region over a whole country).
        .minByOrNull { (it.bbox[2] - it.bbox[0]) * (it.bbox[3] - it.bbox[1]) }
    return Coverage.Missing(suggestion)
}

@Composable
fun CoverageBanner(coverage: Coverage.Missing, downloadState: DownloadState?, onOpenPacks: () -> Unit, modifier: Modifier = Modifier) {
    val pack = coverage.suggested
    Card(modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            if (pack == null) {
                Text("No railway data here yet", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(4.dp))
                Text(
                    "None of your downloaded country packs cover this area.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(8.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = androidx.compose.foundation.layout.Arrangement.End) {
                    TextButton(onClick = onOpenPacks) { Text("See available packs") }
                }
            } else {
                Text("${pack.name} isn't downloaded yet", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(4.dp))
                Text(
                    "Download the ${pack.name} pack (${formatBytes(pack.totalBytes)}) to see it offline.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(8.dp))
                when (downloadState) {
                    is DownloadState.Running -> {
                        LinearProgressIndicator(progress = { downloadState.fraction }, modifier = Modifier.fillMaxWidth())
                        Spacer(Modifier.height(4.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "${downloadState.stage}: ${formatBytes(downloadState.bytesDone)} of ${formatBytes(downloadState.bytesTotal)}",
                                style = MaterialTheme.typography.labelSmall,
                                modifier = Modifier.weight(1f),
                            )
                            TextButton(onClick = { PackStore.cancel(pack.id) }) { Text("Cancel") }
                        }
                    }
                    is DownloadState.Failed -> {
                        Text(
                            "Download failed: ${downloadState.message}",
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                        )
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = androidx.compose.foundation.layout.Arrangement.End) {
                            TextButton(onClick = { PackStore.dismissError(pack.id) }) { Text("Dismiss") }
                            Button(onClick = { PackStore.download(pack) }) { Text("Retry") }
                        }
                    }
                    null -> Row(Modifier.fillMaxWidth(), horizontalArrangement = androidx.compose.foundation.layout.Arrangement.End) {
                        TextButton(onClick = onOpenPacks) { Text("All countries") }
                        Button(onClick = { PackStore.download(pack) }) { Text("Download") }
                    }
                }
            }
        }
    }
}
