// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import RailwayMapCore
import SwiftUI

/// The single sheet behind the menu button: key, country packs, map options and about.
struct MainSheet: View {
    @Bindable var model: AppModel
    @State private var tab: SheetTab
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, initialTab: SheetTab) {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .key:
                    KeyContent(model: model)
                case .packs:
                    PacksContent(packs: model.packs, onShow: model.showPack)
                case .options:
                    OptionsContent(options: $model.options)
                case .about:
                    AboutContent(manifestURL: model.packs.manifestURL)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(SheetTab.allCases) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(.bar)
            }
            .navigationTitle(tab == .packs ? "Country packs" : tab == .options ? "Map options" : tab.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct PacksContent: View {
    let packs: PackStore
    let onShow: @MainActor (InstalledPack) -> Void

    var body: some View {
        // Installed packs that are no longer in the manifest still need to be listed.
        let installedById = Dictionary(packs.installed.map { ($0.info.id, $0) }, uniquingKeysWith: { first, _ in first })
        let availableIds = Set(packs.available.map(\.id))
        let rows = (packs.available + packs.installed.map(\.info).filter { !availableIds.contains($0.id) })
            .sorted { ($0.regionLabel, $0.name) < ($1.regionLabel, $1.name) }

        List {
            if let error = packs.manifestError {
                Text("Could not load the pack list: \(error). Pull down to try again.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if rows.isEmpty && packs.manifestLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            ForEach(rows) { pack in
                PackRow(pack: pack, installed: installedById[pack.id], state: packs.downloads[pack.id], packs: packs, onShow: onShow)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await packs.refreshManifestNow()
        }
        .task {
            if packs.available.isEmpty && !packs.manifestLoading {
                await packs.refreshManifestNow()
            }
        }
    }
}

private struct PackRow: View {
    let pack: PackInfo
    let installed: InstalledPack?
    let state: DownloadState?
    let packs: PackStore
    let onShow: @MainActor (InstalledPack) -> Void
    @State private var confirmDelete = false

    var body: some View {
        let updateAvailable = installed.map { $0.info.version < pack.version } ?? false
        // Describe what is on the device; the update line below describes the newer version.
        let shown = installed?.info ?? pack

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pack.name)
                        .font(.headline)
                    Text(details(shown))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state?.isRunning == true {
                    Button("Cancel") {
                        packs.cancel(id: pack.id)
                    }
                } else if let installed {
                    Button("Delete", role: .destructive) {
                        confirmDelete = true
                    }
                    Button("Show") {
                        onShow(installed)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Download") {
                        packs.download(pack)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            switch state {
            case .running(let done, let total, let stage):
                ProgressView(value: state?.fraction ?? 0)
                Text("\(installed != nil ? "Updating " : "")\(stage): \(formatBytes(done)) of \(formatBytes(total))")
                    .font(.caption2)
            case .failed(let message):
                HStack {
                    Text("\(installed != nil ? "Update failed" : "Failed"): \(message)")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") {
                        packs.dismissError(id: pack.id)
                    }
                }
            case nil:
                EmptyView()
            }
            if updateAvailable && state?.isRunning != true {
                HStack {
                    Text(updateLine)
                        .font(.footnote)
                        .foregroundStyle(Theme.orange)
                    Spacer()
                    Button("Update") {
                        packs.download(pack)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
        .confirmationDialog("Delete \(pack.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(formatBytes(shown.totalBytes))", role: .destructive) {
                packs.delete(id: pack.id)
            }
        } message: {
            Text("You can download it again later.")
        }
    }

    private func details(_ info: PackInfo) -> String {
        var text = "\(info.regionLabel) · \(formatBytes(info.totalBytes))"
        if !info.dataDate.isEmpty {
            text += " · data \(info.dataDate.prefix(10))"
        }
        return text
    }

    private var updateLine: String {
        var text = "Update available"
        if !pack.dataDate.isEmpty {
            text += ": data \(pack.dataDate.prefix(10))"
        }
        return text + " · \(formatBytes(pack.totalBytes))"
    }
}

struct OptionsContent: View {
    @Binding var options: MapOptions

    var body: some View {
        Form {
            Section("Infrastructure") {
                Toggle("Under construction", isOn: $options.showConstruction)
                Toggle("Proposed", isOn: $options.showProposed)
                Toggle("Abandoned", isOn: $options.showAbandoned)
                Toggle("Razed", isOn: $options.showRazed)
            }
            Section("Station labels at low zoom") {
                Picker("Station labels at low zoom", selection: $options.stationLowZoomLabel) {
                    Text("Short label").tag("label")
                    Text("Full name").tag("name")
                    Text("None").tag("none")
                }
                .labelsHidden()
            }
            Section("Electrification colours") {
                Picker("Electrification colours", selection: $options.electrificationLine) {
                    Text("Voltage and frequency").tag("voltageFrequency")
                    Text("Maximum current").tag("maximumCurrent")
                    Text("Power supply").tag("power")
                }
                .labelsHidden()
            }
            Section("Gauge view shows") {
                Picker("Gauge view shows", selection: $options.trackLine) {
                    Text("Track gauge").tag("gauge")
                    Text("Loading gauge").tag("loadingGauge")
                    Text("Track class").tag("trackClass")
                }
                .labelsHidden()
            }
        }
        .pickerStyle(.inline)
    }
}
