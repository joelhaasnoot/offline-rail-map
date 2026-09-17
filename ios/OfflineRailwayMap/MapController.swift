// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import CoreLocation
import MapLibre
import Observation
import RailwayMapCore
import SwiftUI

/// Owns the MapLibre map view and exposes what the SwiftUI screens need from it.
@MainActor
@Observable
final class MapController {
    private(set) var viewport: GeoBounds?
    private(set) var zoom: Double = 0
    private(set) var tracking = false
    private(set) var isReady = false
    var locationDenied = false

    /// Camera target requested via a geo: link, applied once the map exists.
    var pendingCamera: SavedCamera? {
        didSet {
            applyPendingCamera()
        }
    }

    @ObservationIgnored var prefs: Prefs?
    @ObservationIgnored var composer: SpriteComposer?
    @ObservationIgnored private weak var mapView: MLNMapView?
    @ObservationIgnored private var styleJSON: String?
    @ObservationIgnored private var delegate: MapDelegate?

    func makeMapView() -> MLNMapView {
        if let mapView {
            return mapView
        }
        // Start from our own style: a plain MLNMapView would first load MapLibre's online demo style.
        let view = MLNMapView(frame: .zero, styleJSON: styleJSON ?? Self.blankStyle)
        let delegate = MapDelegate(controller: self, composer: composer)
        self.delegate = delegate // the map view only holds it weakly
        view.delegate = delegate
        view.isRotateEnabled = true
        view.isPitchEnabled = false
        // Attribution is shown by the app itself (see the text at the bottom left).
        view.logoView.isHidden = true
        view.attributionButton.isHidden = true
        view.compassViewMargins = CGPoint(x: 12, y: 64)
        view.tintColor = UIColor(Theme.locationBlue)
        if let camera = prefs?.camera {
            view.setCenter(CLLocationCoordinate2D(latitude: camera.lat, longitude: camera.lon), zoomLevel: camera.zoom, animated: false)
        }
        mapView = view
        // Called while SwiftUI builds the view; publish readiness after this update.
        Task { @MainActor in
            isReady = true
            applyPendingCamera()
        }
        return view
    }

    /// Shown for the moment before the real style is built: the basemap background colour only.
    private static let blankStyle =
        ##"{"version":8,"sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#f4f1ec"}}]}"##

    func setStyle(_ json: String) {
        guard json != styleJSON else {
            return
        }
        styleJSON = json
        mapView?.styleJSON = json
    }

    func fit(to packs: [InstalledPack]) {
        guard let mapView, !packs.isEmpty else {
            return
        }
        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(
                latitude: packs.map(\.info.bbox.south).min()!,
                longitude: packs.map(\.info.bbox.west).min()!
            ),
            ne: CLLocationCoordinate2D(
                latitude: packs.map(\.info.bbox.north).max()!,
                longitude: packs.map(\.info.bbox.east).max()!
            )
        )
        let inset: CGFloat = 48
        mapView.setVisibleCoordinateBounds(
            bounds,
            edgePadding: UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset),
            animated: true,
            completionHandler: nil
        )
    }

    private func applyPendingCamera() {
        guard let mapView, let camera = pendingCamera else {
            return
        }
        pendingCamera = nil
        mapView.setCenter(CLLocationCoordinate2D(latitude: camera.lat, longitude: camera.lon), zoomLevel: camera.zoom, animated: true)
    }

    /// Follows the user's location, asking for permission first when needed.
    func startTracking() {
        guard let mapView else {
            return
        }
        switch CLLocationManager().authorizationStatus {
        case .denied, .restricted:
            locationDenied = true
            return
        default:
            break
        }
        mapView.showsUserLocation = true
        mapView.setUserTrackingMode(.follow, animated: true, completionHandler: nil)
    }

    /// The zoom and the legend feature keys of everything the map currently renders on screen.
    func legendContext(legendView: JSON, layers: [JSON], packs: [InstalledPack]) -> LegendContext {
        let zoom = Int(self.zoom.rounded(.down))
        guard let mapView, let style = mapView.style, let sourceLayers = legendView["sourceLayers"] else {
            return LegendContext(zoom: zoom, inView: [:])
        }
        var inView: [String: Set<String>] = [:]
        let layersBySource = Dictionary(grouping: layers.filter { Legend.visibleAtZoom($0, zoom) }, by: Legend.sourceName)
        for (sourceName, sourceLayersInStyle) in layersBySource {
            guard let legendSource = sourceLayers[sourceName] else {
                continue
            }
            let ids = sourceLayersInStyle
                .flatMap { layer in packs.map { "\(layer["id"]?.string ?? "")__\($0.info.id)" } }
                .filter { style.layer(withIdentifier: $0) != nil }
            if ids.isEmpty {
                continue
            }
            let features = mapView.visibleFeatures(in: mapView.bounds, styleLayerIdentifiers: Set(ids))
            if !features.isEmpty {
                var keys = Set<String>()
                for feature in features {
                    keys.formUnion(Legend.featureKeys(sourceLayer: legendSource) { key in
                        JSON(foundation: feature.attribute(forKey: key))
                    })
                }
                inView[sourceName] = keys
            }
        }
        return LegendContext(zoom: zoom, inView: inView)
    }

    /// `moved` is false for the initial layout, which must not count as the user having moved the map.
    fileprivate func cameraDidSettle(_ mapView: MLNMapView, moved: Bool) {
        if let prefs, moved || prefs.camera != nil {
            let center = mapView.centerCoordinate
            prefs.camera = SavedCamera(lat: center.latitude, lon: center.longitude, zoom: mapView.zoomLevel)
        }
        let bounds = mapView.visibleCoordinateBounds
        viewport = GeoBounds(south: bounds.sw.latitude, west: bounds.sw.longitude, north: bounds.ne.latitude, east: bounds.ne.longitude)
        zoom = mapView.zoomLevel
    }

    fileprivate func trackingDidChange(_ mode: MLNUserTrackingMode) {
        tracking = mode != .none
    }

    fileprivate func locationFailed(_ error: Error) {
        tracking = false
        if (error as? CLError)?.code == .denied {
            locationDenied = true
        }
    }
}

/// MapLibre delegate callbacks arrive on the main thread; forward them to the controller.
private final class MapDelegate: NSObject, MLNMapViewDelegate {
    private weak var controller: MapController?
    private let composer: SpriteComposer?

    init(controller: MapController, composer: SpriteComposer?) {
        self.controller = controller
        self.composer = composer
    }

    /// Composes icons the sprite lacks. The image must be returned right away: MapLibre does not lay
    /// out symbols again for images added later.
    func mapView(_ mapView: MLNMapView, didFailToLoadImage imageName: String) -> UIImage? {
        composer?.image(for: imageName)
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
        MainActor.assumeIsolated {
            controller?.cameraDidSettle(mapView, moved: !reason.isEmpty)
        }
    }

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        MainActor.assumeIsolated {
            controller?.cameraDidSettle(mapView, moved: false)
        }
    }

    func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
        MainActor.assumeIsolated {
            controller?.trackingDidChange(mode)
        }
    }

    func mapView(_ mapView: MLNMapView, didFailToLocateUserWithError error: Error) {
        MainActor.assumeIsolated {
            controller?.locationFailed(error)
        }
    }
}

/// The map itself, filling the screen behind the SwiftUI controls.
struct RailMapView: UIViewRepresentable {
    let controller: MapController

    func makeUIView(context: Context) -> MLNMapView {
        controller.makeMapView()
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {}
}
