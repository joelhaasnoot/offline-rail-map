// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import app.offlinerailwaymap.data.InstalledPack
import app.offlinerailwaymap.data.PackStore
import app.offlinerailwaymap.data.Prefs
import app.offlinerailwaymap.map.MapMode
import app.offlinerailwaymap.map.MapOptions
import app.offlinerailwaymap.map.StyleBuilder
import app.offlinerailwaymap.ui.Coverage
import app.offlinerailwaymap.ui.CoverageBanner
import app.offlinerailwaymap.ui.coverageFor
import app.offlinerailwaymap.ui.LocationButton
import app.offlinerailwaymap.ui.LocationBlue
import app.offlinerailwaymap.ui.MainSheet
import app.offlinerailwaymap.ui.RailColorScheme
import app.offlinerailwaymap.ui.SheetTab
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.location.LocationComponentActivationOptions
import org.maplibre.android.location.LocationComponentOptions
import org.maplibre.android.location.OnCameraTrackingChangedListener
import org.maplibre.android.location.modes.CameraMode
import org.maplibre.android.location.modes.RenderMode
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style

private const val TAG = "MainActivity"

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handleGeoIntent(intent)
        setContent {
            MaterialTheme(colorScheme = RailColorScheme) {
                MapScreen()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleGeoIntent(intent)
    }

    /** Supports `geo:lat,lon?z=zoom` and `geo:0,0?q=lat,lon` links from other apps. */
    private fun handleGeoIntent(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "geo") {
            return
        }
        val raw = data.schemeSpecificPart ?: return
        val coords = Regex("(-?\\d+(?:\\.\\d+)?),(-?\\d+(?:\\.\\d+)?)")
        val query = raw.substringAfter("?", "")
        val fromQuery = Regex("q=([^&]*)").find(query)?.groupValues?.get(1)?.let { coords.find(it) }
        val match = fromQuery ?: coords.find(raw.substringBefore("?")) ?: return
        val lat = match.groupValues[1].toDoubleOrNull() ?: return
        val lon = match.groupValues[2].toDoubleOrNull() ?: return
        if (fromQuery == null && lat == 0.0 && lon == 0.0) {
            return
        }
        val zoom = Regex("z=(\\d+(?:\\.\\d+)?)").find(query)?.groupValues?.get(1)?.toDoubleOrNull() ?: 14.0
        pendingCamera.value = Triple(lat, lon, zoom)
    }

    companion object {
        /** Camera target requested via a geo: intent, consumed by the map screen. */
        val pendingCamera = MutableStateFlow<Triple<Double, Double, Double>?>(null)
    }
}

@Composable
fun MapScreen() {
    val context = LocalContext.current
    val installed by PackStore.installed.collectAsState()
    var mode by remember { mutableStateOf(MapMode.fromId(Prefs.modeId)) }
    var options by remember { mutableStateOf(MapOptions.fromPrefs()) }
    var sheetTab by remember { mutableStateOf<SheetTab?>(null) }
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var locationWanted by remember { mutableStateOf(false) }
    var locationTracking by remember { mutableStateOf(false) }
    var viewport by remember { mutableStateOf<LatLngBounds?>(null) }
    var viewportZoom by remember { mutableStateOf(0.0) }
    val available by PackStore.available.collectAsState()
    val downloads by PackStore.downloads.collectAsState()
    var styleReady by remember { mutableStateOf(false) }

    val mapView = remember {
        MapView(context).also { view ->
            view.onCreate(null)
            view.getMapAsync { m ->
                m.uiSettings.isRotateGesturesEnabled = true
                m.uiSettings.isTiltGesturesEnabled = false
                // Attribution is shown by the app itself (see the text at the bottom left).
                m.uiSettings.isLogoEnabled = false
                m.uiSettings.isAttributionEnabled = false
                Prefs.camera?.let { (lat, lon, zoom) ->
                    m.moveCamera(CameraUpdateFactory.newLatLngZoom(LatLng(lat, lon), zoom))
                }
                m.addOnCameraIdleListener {
                    val pos = m.cameraPosition
                    val target = pos.target ?: return@addOnCameraIdleListener
                    Prefs.camera = Triple(target.latitude, target.longitude, pos.zoom)
                    viewport = m.projection.visibleRegion.latLngBounds
                    viewportZoom = pos.zoom
                }
                map = m
            }
        }
    }
    MapViewLifecycle(mapView)

    // Know which packs exist so the empty state can offer the right download.
    LaunchedEffect(Unit) {
        if (PackStore.available.value.isEmpty()) {
            PackStore.refreshManifest()
        }
    }
    val coverage = remember(viewport, viewportZoom, installed, available) {
        coverageFor(viewport, viewportZoom, installed, available)
    }

    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            locationWanted = true
        } else {
            Toast.makeText(context, "Location permission denied", Toast.LENGTH_SHORT).show()
        }
    }

    // Rebuild and apply the style whenever mode, options or the installed packs change.
    LaunchedEffect(map, mode, options, installed) {
        val m = map ?: return@LaunchedEffect
        styleReady = false
        val json = try {
            withContext(Dispatchers.Default) { StyleBuilder.build(context, mode, options, installed) }
        } catch (e: Exception) {
            Log.e(TAG, "style build failed", e)
            Toast.makeText(context, "Could not build map style: ${e.message}", Toast.LENGTH_LONG).show()
            return@LaunchedEffect
        }
        m.setStyle(Style.Builder().fromJson(json)) { style ->
            styleReady = true
            if (locationWanted) {
                enableLocation(context, m, style) { locationTracking = it }
            }
        }
    }

    // First time a pack is installed and the user never moved the map: fit to the data.
    LaunchedEffect(map, installed.size) {
        val m = map ?: return@LaunchedEffect
        if (installed.isNotEmpty() && Prefs.camera == null) {
            fitToPacks(m, installed)
        }
    }

    val pendingCamera by MainActivity.pendingCamera.collectAsState()
    LaunchedEffect(map, pendingCamera) {
        val m = map ?: return@LaunchedEffect
        val (lat, lon, zoom) = pendingCamera ?: return@LaunchedEffect
        MainActivity.pendingCamera.value = null
        m.easeCamera(CameraUpdateFactory.newLatLngZoom(LatLng(lat, lon), zoom), 800)
    }

    LaunchedEffect(locationWanted, styleReady) {
        val m = map ?: return@LaunchedEffect
        val style = m.style ?: return@LaunchedEffect
        if (locationWanted && styleReady) {
            enableLocation(context, m, style) { locationTracking = it }
        }
    }

    Box(Modifier.fillMaxSize()) {
        AndroidView(factory = { mapView }, modifier = Modifier.fillMaxSize())

        Row(
            Modifier
                .align(Alignment.TopCenter)
                .statusBarsPadding()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 8.dp, vertical = 4.dp),
        ) {
            MapMode.entries.forEach { m ->
                FilterChip(
                    selected = m == mode,
                    onClick = {
                        mode = m
                        Prefs.modeId = m.id
                    },
                    label = { Text(m.label) },
                    modifier = Modifier.padding(horizontal = 4.dp),
                )
            }
        }

        if (coverage is Coverage.Missing) {
            CoverageBanner(
                coverage = coverage,
                downloadState = coverage.suggested?.let { downloads[it.id] },
                onOpenPacks = { sheetTab = SheetTab.PACKS },
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding()
                    .padding(top = 64.dp, start = 16.dp, end = 16.dp),
            )
        }

        Column(
            Modifier
                .align(Alignment.BottomEnd)
                .navigationBarsPadding()
                .padding(16.dp),
            horizontalAlignment = Alignment.End,
        ) {
            LocationButton(active = locationTracking, onClick = {
                val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
                    PackageManager.PERMISSION_GRANTED
                if (granted) {
                    locationWanted = true
                    map?.let { m -> m.style?.let { enableLocation(context, m, it) { t -> locationTracking = t } } }
                } else {
                    permissionLauncher.launch(Manifest.permission.ACCESS_FINE_LOCATION)
                }
            })
            Spacer(Modifier.height(12.dp))
            FloatingActionButton(onClick = { sheetTab = SheetTab.PACKS }) {
                Icon(Icons.Default.Menu, contentDescription = "Country packs and map options")
            }
        }

        Text(
            "© OpenStreetMap contributors · OpenRailwayMap",
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier
                .align(Alignment.BottomStart)
                .navigationBarsPadding()
                .padding(8.dp)
                .background(Color.White.copy(alpha = 0.75f), RoundedCornerShape(4.dp))
                .padding(horizontal = 6.dp, vertical = 2.dp),
        )

        if (installed.isEmpty()) {
            Card(Modifier.align(Alignment.Center).padding(32.dp)) {
                Column(Modifier.padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No map data yet", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Download a country pack to browse railway infrastructure, speeds, " +
                            "signalling and electrification fully offline.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Spacer(Modifier.height(16.dp))
                    Button(onClick = { sheetTab = SheetTab.PACKS }) { Text("Download a country") }
                }
            }
        }
    }

    sheetTab?.let { tab ->
        MainSheet(
            initialTab = tab,
            options = options,
            mode = mode,
            onChange = {
                options = it
                it.save()
            },
            onDismiss = { sheetTab = null },
            onShowPack = { pack ->
                sheetTab = null
                map?.let { fitToPacks(it, listOf(pack)) }
            },
        )
    }
}

private fun fitToPacks(map: MapLibreMap, packs: List<InstalledPack>) {
    if (packs.isEmpty()) {
        return
    }
    val west = packs.minOf { it.info.bbox[0] }
    val south = packs.minOf { it.info.bbox[1] }
    val east = packs.maxOf { it.info.bbox[2] }
    val north = packs.maxOf { it.info.bbox[3] }
    val bounds = LatLngBounds.from(north, east, south, west)
    map.easeCamera(CameraUpdateFactory.newLatLngBounds(bounds, 48), 600)
}

@SuppressLint("MissingPermission")
private fun enableLocation(
    context: android.content.Context,
    map: MapLibreMap,
    style: Style,
    onTrackingChanged: (Boolean) -> Unit,
) {
    if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
        return
    }
    try {
        val component = map.locationComponent
        if (!component.isLocationComponentActivated) {
            val blue = LocationBlue.toArgb()
            val options = LocationComponentOptions.builder(context)
                .foregroundTintColor(blue)
                .backgroundTintColor(android.graphics.Color.WHITE)
                .bearingTintColor(blue)
                .accuracyColor(blue)
                .accuracyAlpha(0.15f)
                .pulseEnabled(false)
                .enableStaleState(false)
                .build()
            component.activateLocationComponent(
                LocationComponentActivationOptions.builder(context, style)
                    .locationComponentOptions(options)
                    .build(),
            )
            component.addOnCameraTrackingChangedListener(object : OnCameraTrackingChangedListener {
                override fun onCameraTrackingDismissed() {
                    onTrackingChanged(false)
                }

                override fun onCameraTrackingChanged(currentMode: Int) {
                    onTrackingChanged(currentMode != CameraMode.NONE)
                }
            })
        }
        component.isLocationComponentEnabled = true
        component.renderMode = RenderMode.NORMAL
        component.cameraMode = CameraMode.TRACKING
        onTrackingChanged(true)
    } catch (e: Exception) {
        Log.w(TAG, "location component failed", e)
    }
}

@Composable
private fun MapViewLifecycle(mapView: MapView) {
    val lifecycle = (LocalContext.current as LifecycleOwner).lifecycle
    DisposableEffect(lifecycle, mapView) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> mapView.onStart()
                Lifecycle.Event.ON_RESUME -> mapView.onResume()
                Lifecycle.Event.ON_PAUSE -> mapView.onPause()
                Lifecycle.Event.ON_STOP -> mapView.onStop()
                Lifecycle.Event.ON_DESTROY -> mapView.onDestroy()
                else -> {}
            }
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
        }
    }
}
