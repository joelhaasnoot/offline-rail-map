// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation
import Observation
import os

/**
 Keeps track of which country packs are installed on the device, fetches the remote
 manifest, and downloads, updates and deletes packs. Folder layout: see `PackDirs`. A download
 or update is written to a staging folder and only swapped in when complete, so the installed
 copy keeps working during an update and survives a failed or cancelled one.
 */
@MainActor
@Observable
public final class PackStore {
    private static let log = Logger(subsystem: "com.offlinerailmap.ios", category: "PackStore")

    /// Extra free space required beyond the pack itself.
    private static let spaceMarginBytes: Int64 = 64 * 1024 * 1024

    /// How long a replaced copy is kept so the map can finish switching to the new files.
    private static let replacedCopyGrace: Duration = .seconds(60)

    public private(set) var installed: [InstalledPack] = []
    public private(set) var available: [PackInfo] = []
    public private(set) var manifestError: String?
    public private(set) var manifestLoading = false
    public private(set) var downloads: [String: DownloadState] = [:]
    public private(set) var manifestURL: URL

    @ObservationIgnored private let packsDir: URL
    @ObservationIgnored private var jobs: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private let downloader = FileDownloader()
    @ObservationIgnored private let http: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    public init(packsDir: URL, manifestURL: URL) {
        self.packsDir = packsDir
        self.manifestURL = manifestURL
        let fm = FileManager.default
        try? fm.createDirectory(at: packsDir, withIntermediateDirectories: true)
        // Packs can be downloaded again at any time; keep them out of device backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = packsDir
        try? dir.setResourceValues(values)
        // Downloads interrupted by the app being killed are not resumed; drop their leftovers.
        for folder in folders() where PackDirs.isStaging(folder.lastPathComponent) {
            try? fm.removeItem(at: folder)
        }
        scanInstalled(deleteSuperseded: true)
    }

    private func folders() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: packsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func scanInstalled(deleteSuperseded: Bool) {
        let fm = FileManager.default
        let copies: [InstalledPack] = folders()
            .filter { !PackDirs.isStaging($0.lastPathComponent) }
            .compactMap { dir in
                let meta = dir.appendingPathComponent("pack.json")
                guard fm.fileExists(atPath: meta.path) else {
                    return nil
                }
                do {
                    let pack = InstalledPack(info: try PackInfo.fromJSON(JSON(contentsOf: meta)), dir: dir)
                    return fm.fileExists(atPath: pack.railwayFile.path) ? pack : nil
                } catch {
                    Self.log.warning("ignoring broken pack in \(dir.lastPathComponent): \(error.localizedDescription)")
                    return nil
                }
            }
        let (chosen, superseded) = PackDirs.choose(
            copies,
            id: { $0.info.id },
            version: { $0.info.version },
            folderName: { $0.dir.lastPathComponent }
        )
        installed = chosen.sorted { $0.info.name < $1.info.name }
        if deleteSuperseded {
            for copy in superseded {
                try? fm.removeItem(at: copy.dir)
            }
        }
    }

    /// Fetches the manifest without waiting for it, e.g. when a screen opens.
    public func refreshManifest() {
        Task {
            await refreshManifestNow()
        }
    }

    /// Fetches the manifest and returns when done, for pull to refresh.
    public func refreshManifestNow() async {
        manifestLoading = true
        manifestError = nil
        defer { manifestLoading = false }
        do {
            let (data, response) = try await http.data(from: manifestURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw PackError("HTTP \(http.statusCode)")
            }
            let packs = try PackInfo.list(fromManifest: JSON(parsing: data))
            available = packs.sorted { ($0.region, $0.name) < ($1.region, $1.name) }
            upgradeInstalledMetadata(packs)
        } catch {
            Self.log.warning("manifest fetch failed: \(error.localizedDescription)")
            manifestError = error.localizedDescription
        }
    }

    /// Installed packs written by older manifests may lack the coverage polygon; copy it over.
    private func upgradeInstalledMetadata(_ remote: [PackInfo]) {
        var changed = false
        for pack in installed {
            guard let newer = remote.first(where: { $0.id == pack.info.id }) else {
                continue
            }
            if pack.info.coverage.isEmpty && !newer.coverage.isEmpty {
                var info = pack.info
                info.coverage = newer.coverage
                try? Data(info.toJSON().serialized().utf8).write(to: pack.dir.appendingPathComponent("pack.json"))
                changed = true
            }
        }
        if changed {
            scanInstalled(deleteSuperseded: false)
        }
    }

    public func installedPack(id: String) -> InstalledPack? {
        installed.first { $0.info.id == id }
    }

    /// Downloads `pack`, or updates it when an older copy is installed.
    public func download(_ pack: PackInfo) {
        if jobs[pack.id] != nil {
            return
        }
        downloads[pack.id] = nil
        let token = UUID()
        let task = Task { [weak self] in
            await self?.runDownload(pack)
            if self?.jobs[pack.id]?.token == token {
                self?.jobs[pack.id] = nil
            }
        }
        jobs[pack.id] = (token, task)
    }

    private func runDownload(_ pack: PackInfo) async {
        let fm = FileManager.default
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let staging = packsDir.appendingPathComponent(PackDirs.stagingName(id: pack.id, timestamp: timestamp))
        do {
            let needed = pack.totalBytes + Self.spaceMarginBytes
            let values = try? packsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let free = values?.volumeAvailableCapacityForImportantUsage, free < needed {
                let style = ByteCountFormatter.CountStyle.file
                throw PackError(
                    "not enough free space: needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: style)), " +
                    "\(ByteCountFormatter.string(fromByteCount: free, countStyle: style)) available"
                )
            }
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            let total = pack.totalBytes
            downloads[pack.id] = .running(bytesDone: 0, bytesTotal: total, stage: "railway")
            guard let railwayUrl = URL(string: pack.railwayUrl) else {
                throw PackError("invalid URL \(pack.railwayUrl)")
            }
            var done = try await downloader.download(from: railwayUrl, to: staging.appendingPathComponent("railway.pmtiles")) { [weak self] bytes in
                self?.downloads[pack.id] = .running(bytesDone: bytes, bytesTotal: total, stage: "railway")
            }
            if let basemap = pack.basemapUrl {
                guard let basemapUrl = URL(string: basemap) else {
                    throw PackError("invalid URL \(basemap)")
                }
                let before = done
                done += try await downloader.download(from: basemapUrl, to: staging.appendingPathComponent("basemap.pmtiles")) { [weak self] bytes in
                    self?.downloads[pack.id] = .running(bytesDone: before + bytes, bytesTotal: total, stage: "basemap")
                }
            }
            try Task.checkCancellation()
            try Data(pack.toJSON().serialized().utf8).write(to: staging.appendingPathComponent("pack.json"))
            let target = packsDir.appendingPathComponent(PackDirs.installedName(stagingName: staging.lastPathComponent))
            try fm.moveItem(at: staging, to: target)
            let replaced = installed.filter { $0.info.id == pack.id }
            downloads[pack.id] = nil
            scanInstalled(deleteSuperseded: false)
            if !replaced.isEmpty {
                // The map keeps reading the previous files until it has switched to the new copy.
                Task.detached {
                    try? await Task.sleep(for: Self.replacedCopyGrace)
                    for copy in replaced {
                        try? FileManager.default.removeItem(at: copy.dir)
                    }
                }
            }
        } catch {
            try? fm.removeItem(at: staging)
            if error is CancellationError || Task.isCancelled {
                return
            }
            Self.log.warning("download of \(pack.id) failed: \(error.localizedDescription)")
            downloads[pack.id] = .failed(message: error.localizedDescription)
        }
    }

    /// Stops a running download or update. An installed copy is left untouched.
    public func cancel(id: String) {
        jobs.removeValue(forKey: id)?.task.cancel()
        downloads[id] = nil
    }

    /// Removes a pack from the device, including any download of it that is in progress.
    public func delete(id: String) {
        cancel(id: id)
        for folder in folders() where PackDirs.belongsTo(folder.lastPathComponent, id: id) {
            try? FileManager.default.removeItem(at: folder)
        }
        scanInstalled(deleteSuperseded: false)
    }

    public func dismissError(id: String) {
        downloads[id] = nil
    }
}

/**
 Streams a URL to a file with progress reports. Uses a delegate-based session so progress can be
 reported while the file is written; all callbacks arrive on the main queue.
 */
@MainActor
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private struct Pending {
        let target: URL
        let progress: (Int64) -> Void
        let continuation: CheckedContinuation<Int64, Error>
        var moveError: Error?
        var bytes: Int64 = 0
    }

    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    /// Downloads `url` into `target`; returns the number of bytes written.
    func download(from url: URL, to target: URL, progress: @escaping (Int64) -> Void) async throws -> Int64 {
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[task.taskIdentifier] = Pending(target: target, progress: progress, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        MainActor.assumeIsolated {
            pending[downloadTask.taskIdentifier]?.progress(totalBytesWritten)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so move it right away.
        MainActor.assumeIsolated {
            guard var entry = pending[downloadTask.taskIdentifier] else {
                return
            }
            do {
                if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw PackError("HTTP \(http.statusCode) for \(downloadTask.originalRequest?.url?.absoluteString ?? "")")
                }
                try? FileManager.default.removeItem(at: entry.target)
                try FileManager.default.moveItem(at: location, to: entry.target)
                let size = (try? entry.target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                entry.bytes = size.map { Int64($0) } ?? downloadTask.countOfBytesReceived
            } catch {
                entry.moveError = error
            }
            pending[downloadTask.taskIdentifier] = entry
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let entry = pending.removeValue(forKey: task.taskIdentifier) else {
                return
            }
            if let error = error as? URLError, error.code == .cancelled {
                entry.continuation.resume(throwing: CancellationError())
            } else if let error = error ?? entry.moveError {
                entry.continuation.resume(throwing: error)
            } else {
                entry.progress(entry.bytes)
                entry.continuation.resume(returning: entry.bytes)
            }
        }
    }
}
