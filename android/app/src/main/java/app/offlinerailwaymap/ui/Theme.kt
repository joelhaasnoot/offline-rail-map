// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap.ui

import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color

/** OpenRailwayMap orange as the accent colour. */
val RailOrange = Color(0xFFE8640A)
val RailOrangeDark = Color(0xFF9A3E00)
val RailOrangeContainer = Color(0xFFFFDCC4)
val LocationBlue = Color(0xFF1A73E8)

val RailColorScheme = lightColorScheme(
    primary = RailOrange,
    onPrimary = Color.White,
    primaryContainer = RailOrangeContainer,
    onPrimaryContainer = Color(0xFF3A1600),
    secondary = RailOrangeDark,
    onSecondary = Color.White,
    secondaryContainer = RailOrangeContainer,
    onSecondaryContainer = Color(0xFF3A1600),
    tertiary = Color(0xFF5B4D70),
    surfaceTint = RailOrange,
    background = Color(0xFFFDFBF8),
    surface = Color(0xFFFDFBF8),
)
