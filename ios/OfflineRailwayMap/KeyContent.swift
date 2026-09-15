// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import RailwayMapCore
import SwiftUI

private struct KeyModel {
    let entries: [Legend.Entry]
    let styleJSON: String
    let styleKey: String
    /// Composed icon ids used by the samples, which the renderer must add to the style itself.
    let composites: [String]
}

struct KeyContent: View {
    let model: AppModel
    @State private var showAll = false
    @State private var keyModel: KeyModel?
    @State private var renderer: LegendRenderer

    init(model: AppModel) {
        self.model = model
        _renderer = State(initialValue: LegendRenderer(composer: model.composer))
    }

    private struct Inputs: Hashable {
        let mode: MapMode
        let options: MapOptions
        let context: LegendContext?
        let showAll: Bool
    }

    var body: some View {
        List {
            if let context = model.legendContext {
                Section {
                    Text("What the colours and symbols mean in the \(model.mode.label) view at zoom \(context.zoom).")
                        .font(.subheadline)
                    Picker("Show", selection: $showAll) {
                        Text("On screen").tag(false)
                        Text("Everything").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowSeparator(.hidden)

                if let keyModel {
                    if keyModel.entries.isEmpty {
                        Text(showAll
                            ? "This view has nothing to explain at this zoom level."
                            : "Nothing on screen needs explaining. Move the map to railway lines, or choose Everything.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(Array(keyModel.entries.enumerated()), id: \.offset) { index, entry in
                            KeyRow(renderer: renderer, keyModel: keyModel, index: index, entry: entry)
                        }
                    }
                } else {
                    loading
                }
            } else {
                loading
            }
        }
        .listStyle(.plain)
        .task(id: Inputs(mode: model.mode, options: model.options, context: model.legendContext, showAll: showAll)) {
            keyModel = nil
            guard let context = model.legendContext else {
                return
            }
            let styles = model.styles
            let mode = model.mode
            let options = model.options
            let showAll = showAll
            keyModel = try? await Task.detached(priority: .userInitiated) {
                let orm = try styles.ormLayers(mode: mode, options: options)
                let view = try styles.legendView(modeId: mode.id)
                let inView = showAll ? nil : context.inView
                let entries = Legend.entries(legendView: view, layers: orm.layers, state: orm.state, zoom: context.zoom, inView: inView)
                let style = Legend.style(layers: orm.layers, zoom: context.zoom, entries: entries, sprite: orm.sprite, glyphs: orm.glyphs)
                let json = style.serialized()
                return KeyModel(
                    entries: entries,
                    styleJSON: json,
                    styleKey: "\(mode.id)|\(json.hashValue)",
                    composites: ComposedImage.composites(.array(entries.flatMap(\.features)))
                )
            }.value
        }
        .onDisappear {
            renderer.close()
        }
    }

    private var loading: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(height: 160)
        .listRowSeparator(.hidden)
    }
}

private struct KeyRow: View {
    let renderer: LegendRenderer
    let keyModel: KeyModel
    let index: Int
    let entry: Legend.Entry
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                }
            }
            .frame(width: LegendRenderer.size.width, height: LegendRenderer.size.height)
            Text(entry.label)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .task(id: "\(keyModel.styleKey)#\(index)") {
            image = renderer.cached(styleKey: keyModel.styleKey, row: index)
            if image == nil {
                image = await renderer.render(
                    styleKey: keyModel.styleKey,
                    styleJSON: keyModel.styleJSON,
                    composites: keyModel.composites,
                    row: index
                )
            }
        }
    }
}
