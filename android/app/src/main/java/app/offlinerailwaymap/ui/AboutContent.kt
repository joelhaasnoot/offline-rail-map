// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap.ui

import android.net.Uri
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import app.offlinerailwaymap.BuildConfig
import app.offlinerailwaymap.R
import app.offlinerailwaymap.data.PackStore

private const val SOURCE_URL = "https://github.com/joelhaasnoot/offline-rail-map"

/** One credit line: what it is, who made it (linked), extra people, its licence. */
private data class Credit(val what: String, val who: String, val license: String, val url: String, val note: String = "")

private val credits = listOf(
    Credit("Map data", "© OpenStreetMap contributors", "ODbL 1.0", "https://www.openstreetmap.org/copyright"),
    Credit(
        "Railway map style, symbols and tile pipeline",
        "OpenRailwayMap",
        "GPL-3.0",
        "https://github.com/hiddewie/OpenRailwayMap-vector",
        note = "by Hidde Wieringa, with earlier styles by Michael Reichert and Alexander Matheisen",
    ),
    Credit("World overview", "Natural Earth", "public domain", "https://www.naturalearthdata.com"),
    Credit("Basemap schema", "OpenMapTiles", "BSD-3-Clause and CC-BY 4.0", "https://openmaptiles.org"),
    Credit("Map rendering", "MapLibre Native", "BSD-2-Clause", "https://maplibre.org"),
    Credit("Monospace font", "Fira Code", "SIL Open Font License 1.1", "https://github.com/tonsky/FiraCode"),
)

@Composable
fun AboutContent() {
    val linkStyle = TextLinkStyles(
        SpanStyle(color = MaterialTheme.colorScheme.primary, textDecoration = TextDecoration.Underline),
    )
    val dataHost = Uri.parse(PackStore.manifestUrl).host ?: PackStore.manifestUrl

    Column(Modifier.padding(horizontal = 16.dp).verticalScroll(rememberScrollState())) {
        Text(stringResource(R.string.app_name), style = MaterialTheme.typography.titleLarge)
        Text(
            "Version ${BuildConfig.VERSION_NAME}",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            "Railway infrastructure, speeds, train protection and electrification, available offline.",
            style = MaterialTheme.typography.bodyMedium,
        )

        Section("Disclaimer")
        Paragraph(
            "This is an independent project. It is not affiliated with or endorsed by OpenRailwayMap, " +
                "OpenStreetMap or any railway company.",
        )
        Paragraph(
            "The map shows OpenStreetMap data mapped by volunteers. It can be incomplete, out of date or " +
                "wrong. Each country pack is a snapshot from the date shown in the pack list.",
        )
        Paragraph(
            "Do not rely on this map for safety, navigation or railway operations. Never enter railway " +
                "tracks or other areas without permission.",
        )
        Paragraph("The app is provided as is, without any warranty.")

        Section("Privacy")
        Paragraph(
            "The app only connects to $dataHost, to load the list of country packs and to download them. " +
                "Your location is used on this device only and is never sent anywhere.",
        )

        Section("Credits")
        credits.forEach { credit ->
            Text(
                buildAnnotatedString {
                    append("${credit.what}: ")
                    withLink(LinkAnnotation.Url(credit.url, linkStyle)) { append(credit.who) }
                    if (credit.note.isNotEmpty()) {
                        append(" ${credit.note}")
                    }
                    append(" (${credit.license})")
                },
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(vertical = 4.dp),
            )
        }

        Section("License")
        Text(
            buildAnnotatedString {
                append("This app is free software, released under the GNU General Public License version 3 or later. ")
                withLink(LinkAnnotation.Url(SOURCE_URL, linkStyle)) { append("The source code is on GitHub.") }
            },
            style = MaterialTheme.typography.bodyMedium,
        )
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun Section(title: String) {
    Spacer(Modifier.height(16.dp))
    HorizontalDivider()
    Spacer(Modifier.height(12.dp))
    Text(title, style = MaterialTheme.typography.titleSmall)
    Spacer(Modifier.height(4.dp))
}

@Composable
private fun Paragraph(text: String) {
    Text(text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(vertical = 4.dp))
}
