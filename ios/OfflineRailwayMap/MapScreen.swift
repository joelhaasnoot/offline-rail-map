// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import RailwayMapCore
import SwiftUI

struct MapScreen: View {
    @Bindable var model: AppModel

    /// Everything the style depends on; the style is rebuilt when any of it changes.
    private struct StyleInputs: Hashable {
        let mode: MapMode
        let options: MapOptions
        let packs: [InstalledPack]
        let mapReady: Bool
    }

    var body: some View {
        let packs = model.packs
        ZStack {
            RailMapView(controller: model.map)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                modeChips
                if case .missing(let suggested) = model.coverage {
                    CoverageBanner(
                        suggested: suggested,
                        downloadState: suggested.flatMap { packs.downloads[$0.id] },
                        packs: packs,
                        onOpenPacks: { model.sheetTab = .packs }
                    )
                    .padding(.horizontal, 16)
                }
                Spacer()
            }

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    Text("© OpenStreetMap contributors · OpenRailwayMap")
                        .font(.caption2)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                    Spacer()
                    VStack(spacing: 12) {
                        LocationButton(active: model.map.tracking) {
                            model.map.startTracking()
                        }
                        Button {
                            model.sheetTab = packs.installed.isEmpty ? .packs : .key
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .font(.title2.weight(.medium))
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(Theme.orange, in: RoundedRectangle(cornerRadius: 16))
                                .shadow(radius: 3, y: 2)
                        }
                        .accessibilityLabel("Country packs and map options")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if packs.installed.isEmpty {
                emptyCard
            }
        }
        .task(id: StyleInputs(mode: model.mode, options: model.options, packs: packs.installed, mapReady: model.map.isReady)) {
            guard model.map.isReady else {
                return
            }
            await model.applyStyle()
        }
        .task {
            // Know which packs exist so the empty state can offer the right download.
            if packs.available.isEmpty {
                await packs.refreshManifestNow()
            }
        }
        .onChange(of: packs.installed.count) { _, count in
            // First time a pack is installed and the user never moved the map: fit to the data.
            if count > 0 && model.prefs.camera == nil {
                model.map.fit(to: packs.installed)
            }
        }
        .onChange(of: model.sheetTab != nil) { _, open in
            if open {
                Task {
                    await model.captureLegendContext()
                }
            }
        }
        .sheet(item: $model.sheetTab) { tab in
            MainSheet(model: model, initialTab: tab)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .alert("Could not build map style", isPresented: Binding(
            get: { model.styleError != nil },
            set: { if !$0 { model.styleError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.styleError ?? "")
        }
        .alert("Location permission denied", isPresented: Binding(
            get: { model.map.locationDenied },
            set: { model.map.locationDenied = $0 }
        )) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow location access in Settings to show where you are on the map.")
        }
    }

    private var modeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MapMode.allCases) { mode in
                    let selected = mode == model.mode
                    Button {
                        model.mode = mode
                    } label: {
                        Text(mode.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(selected ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background {
                                if selected {
                                    Capsule().fill(Theme.orange)
                                } else {
                                    Capsule().fill(.regularMaterial)
                                }
                            }
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 12) {
            Text("No map data yet")
                .font(.headline)
            Text("Download a country pack to browse railway infrastructure, speeds, signalling and electrification fully offline.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("Download a country") {
                model.sheetTab = .packs
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(32)
    }
}

/// Round white "my location" button; blue while the camera follows the user.
struct LocationButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: active ? "location.fill" : "location")
                .font(.title3)
                .foregroundStyle(active ? Theme.locationBlue : Color(white: 0.37))
                .frame(width: 52, height: 52)
                .background(.white, in: Circle())
                .shadow(radius: 3, y: 2)
        }
        .accessibilityLabel("My location")
    }
}
