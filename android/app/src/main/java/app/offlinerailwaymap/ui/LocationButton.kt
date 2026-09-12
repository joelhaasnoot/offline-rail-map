// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/** Round white "my location" button with a crosshair icon; blue while the camera follows the user. */
@Composable
fun LocationButton(active: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val tint = if (active) LocationBlue else Color(0xFF5F6368)
    Surface(
        onClick = onClick,
        shape = CircleShape,
        color = Color.White,
        shadowElevation = 4.dp,
        modifier = modifier.size(52.dp).semantics { contentDescription = "My location" },
    ) {
        Canvas(Modifier.padding(13.dp)) {
            val c = center
            val outer = size.minDimension / 2f
            val ring = outer * 0.62f
            val stroke = 2.dp.toPx()
            drawCircle(tint, ring, c, style = Stroke(width = stroke))
            drawCircle(tint, ring * 0.4f, c)
            listOf(Offset(0f, -1f), Offset(0f, 1f), Offset(-1f, 0f), Offset(1f, 0f)).forEach { d ->
                drawLine(
                    tint,
                    c + Offset(d.x * ring, d.y * ring),
                    c + Offset(d.x * outer, d.y * outer),
                    strokeWidth = stroke,
                    cap = StrokeCap.Round,
                )
            }
        }
    }
}
