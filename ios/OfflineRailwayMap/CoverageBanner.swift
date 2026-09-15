// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import RailwayMapCore
import SwiftUI

/// Shown when the map is in an area none of the downloaded packs cover.
struct CoverageBanner: View {
    let suggested: PackInfo?
    let downloadState: DownloadState?
    let packs: PackStore
    let onOpenPacks: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pack = suggested {
                Text("\(pack.name) isn't downloaded yet")
                    .font(.headline)
                Text("Download the \(pack.name) pack (\(formatBytes(pack.totalBytes))) to see its railway infrastructure offline.")
                    .font(.subheadline)
                switch downloadState {
                case .running(let done, let total, let stage):
                    ProgressView(value: downloadState?.fraction ?? 0)
                    HStack {
                        Text("\(stage): \(formatBytes(done)) of \(formatBytes(total))")
                            .font(.caption)
                        Spacer()
                        Button("Cancel") {
                            packs.cancel(id: pack.id)
                        }
                    }
                case .failed(let message):
                    Text("Download failed: \(message)")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    HStack {
                        Spacer()
                        Button("Dismiss") {
                            packs.dismissError(id: pack.id)
                        }
                        Button("Retry") {
                            packs.download(pack)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case nil:
                    HStack {
                        Spacer()
                        Button("All packs", action: onOpenPacks)
                        Button("Download") {
                            packs.download(pack)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Text("No railway data here yet")
                    .font(.headline)
                Text("None of your downloaded country packs cover this area.")
                    .font(.subheadline)
                HStack {
                    Spacer()
                    Button("See available packs", action: onOpenPacks)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
