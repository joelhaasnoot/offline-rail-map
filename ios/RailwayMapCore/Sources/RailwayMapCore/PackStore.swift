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

 Files are fetched by a background `URLSession`, so a download carries on while the app is in the
 background or the screen is off, and even after iOS has ended the app. A failed or interrupted
 download keeps its staging folder, so downloading again continues where it stopped.
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
    @ObservationIgnored private let downloader: FileDownloader
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
        downloader = FileDownloader(root: packsDir)
        // Keep the newest unfinished download of each pack; it is picked up again below.
        let partial = folders().filter { PackDirs.isStaging($0.lastPathComponent) }
        for (_, dirs) in Dictionary(grouping: partial, by: { PackDirs.idOf($0.lastPathComponent) }) {
            let keep = dirs.filter { Self.stagedPack($0) != nil }.max { PackDirs.timestamp($0.lastPathComponent) < PackDirs.timestamp($1.lastPathComponent) }
            for dir in dirs where dir != keep {
                try? fm.removeItem(at: dir)
            }
        }
        scanInstalled(deleteSuperseded: true)
        Task {
            await resumeUnfinished()
        }
    }

    /**
     Hooks up downloads that carried on in the background session while the app was not running and
     finishes those that completed meanwhile. Others are offered for resuming.
     */
    private func resumeUnfinished() async {
        let live = await downloader.liveTaskFolders()
        for dir in folders() where PackDirs.isStaging(dir.lastPathComponent) {
            guard let pack = Self.stagedPack(dir), jobs[pack.id] == nil else {
                continue
            }
            if live.contains(dir.lastPathComponent) || Self.isComplete(dir, pack) {
                download(pack)
            } else if Self.partialBytes(dir) > 0 {
                downloads[pack.id] = .failed(message: "the app was closed", bytesDone: Self.partialBytes(dir))
            } else {
                try? FileManager.default.removeItem(at: dir)
            }
        }
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

    /// Downloads `pack`, or updates it when an older copy is installed. Continues an earlier,
    /// unfinished download of the same version.
    public func download(_ pack: PackInfo) {
        let previous = jobs[pack.id]?.task
        if let previous, !previous.isCancelled {
            return
        }
        downloads[pack.id] = nil
        let token = UUID()
        let task = Task { [weak self] in
            await previous?.value // a cancelled run may still be removing its folder
            await self?.runDownload(pack)
            if self?.jobs[pack.id]?.token == token {
                self?.jobs[pack.id] = nil
            }
        }
        jobs[pack.id] = (token, task)
    }

    private func runDownload(_ pack: PackInfo) async {
        let fm = FileManager.default
        var staging: URL?
        do {
            let dir = try stagingFor(pack)
            staging = dir
            let needed = pack.totalBytes - Self.partialBytes(dir) + Self.spaceMarginBytes
            let values = try? packsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let free = values?.volumeAvailableCapacityForImportantUsage, free < needed {
                let style = ByteCountFormatter.CountStyle.file
                throw PackError(
                    "not enough free space: needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: style)), " +
                    "\(ByteCountFormatter.string(fromByteCount: free, countStyle: style)) available"
                )
            }
            guard let railwayUrl = URL(string: pack.railwayUrl) else {
                throw PackError("invalid URL \(pack.railwayUrl)")
            }
            let basemapUrl = try pack.basemapUrl.map { basemap in
                guard let url = URL(string: basemap) else {
                    throw PackError("invalid URL \(basemap)")
                }
                return url
            }
            // Both files download at once, so the background session can fetch them both while the
            // app is suspended instead of waiting for the app to start the second one.
            let progress = DownloadProgress(total: pack.totalBytes, hasBasemap: basemapUrl != nil) { [weak self] state in
                self?.downloads[pack.id] = state
            }
            progress.report()
            async let railway = fetch(railwayUrl, to: dir.appendingPathComponent("railway.pmtiles")) { bytes, done in
                progress.update(railway: bytes, done: done)
            }
            async let basemap = fetch(basemapUrl, to: dir.appendingPathComponent("basemap.pmtiles")) { bytes, done in
                progress.update(basemap: bytes, done: done)
            }
            _ = try await (railway, basemap)
            try Task.checkCancellation()
            try Data(pack.toJSON().serialized().utf8).write(to: dir.appendingPathComponent("pack.json"))
            let target = packsDir.appendingPathComponent(PackDirs.installedName(stagingName: dir.lastPathComponent))
            try fm.moveItem(at: dir, to: target)
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
            if error is CancellationError || Task.isCancelled {
                if let staging {
                    try? fm.removeItem(at: staging)
                }
                return
            }
            Self.log.warning("download of \(pack.id) failed: \(error.localizedDescription)")
            // Keep what arrived so the download can be resumed instead of starting over.
            downloads[pack.id] = .failed(message: error.localizedDescription, bytesDone: staging.map(Self.partialBytes) ?? 0)
        }
    }

    /// Downloads `url`, if there is one, into `target`; `onBytes` tells how far it got and when it is done.
    private func fetch(_ url: URL?, to target: URL, onBytes: @escaping @MainActor (Int64, Bool) -> Void) async throws -> Int64 {
        guard let url else {
            return 0
        }
        let size = try await downloader.download(from: url, to: target) { bytes in
            onBytes(bytes, false)
        }
        onBytes(size, true)
        return size
    }

    /// The staging folder of an unfinished download of this version of `pack`, or a new one.
    private func stagingFor(_ pack: PackInfo) throws -> URL {
        let fm = FileManager.default
        let partial = folders().filter {
            PackDirs.isStaging($0.lastPathComponent) && PackDirs.belongsTo($0.lastPathComponent, id: pack.id)
        }
        let reusable = partial
            .filter { Self.stagedPack($0)?.version == pack.version }
            .max { PackDirs.timestamp($0.lastPathComponent) < PackDirs.timestamp($1.lastPathComponent) }
        for dir in partial where dir != reusable {
            downloader.cancelTasks(inFolder: dir.lastPathComponent)
            try? fm.removeItem(at: dir)
        }
        if let reusable {
            return reusable
        }
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let dir = packsDir.appendingPathComponent(PackDirs.stagingName(id: pack.id, timestamp: timestamp))
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        // Says which pack and version the folder holds, so the download can be picked up again later.
        try Data(pack.toJSON().serialized().utf8).write(to: dir.appendingPathComponent("pack.json"))
        return dir
    }

    private static func stagedPack(_ dir: URL) -> PackInfo? {
        try? PackInfo.fromJSON(JSON(contentsOf: dir.appendingPathComponent("pack.json")))
    }

    private static func isComplete(_ dir: URL, _ pack: PackInfo) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("railway.pmtiles").path) &&
            (pack.basemapUrl == nil || fm.fileExists(atPath: dir.appendingPathComponent("basemap.pmtiles").path))
    }

    /// Bytes already downloaded into a staging folder, finished files and interrupted ones.
    private static func partialBytes(_ dir: URL) -> Int64 {
        ["railway.pmtiles", "basemap.pmtiles"].reduce(0) { sum, name in
            let file = dir.appendingPathComponent(name)
            return sum + (FileDownloader.fileSize(file) ?? FileDownloader.resumableBytes(for: file))
        }
    }

    /// Stops a running download or update. An installed copy is left untouched.
    public func cancel(id: String) {
        // The job stays in `jobs` until it has finished, so a new download of `id` waits for it.
        if let job = jobs[id] {
            job.task.cancel()
        } else {
            // A transfer the background session carried on with before this run of the app picked it up.
            for folder in folders() where PackDirs.isStaging(folder.lastPathComponent) && PackDirs.belongsTo(folder.lastPathComponent, id: id) {
                downloader.cancelTasks(inFolder: folder.lastPathComponent)
                try? FileManager.default.removeItem(at: folder)
            }
        }
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

    /// Clears a failed download, including what it had downloaded so far.
    public func dismissError(id: String) {
        downloads[id] = nil
        if jobs[id] == nil {
            for folder in folders() where PackDirs.isStaging(folder.lastPathComponent) && PackDirs.belongsTo(folder.lastPathComponent, id: id) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// Identifier of the background session that downloads packs.
    public static var backgroundSessionIdentifier: String {
        FileDownloader.sessionIdentifier
    }

    /**
     For `application(_:handleEventsForBackgroundURLSession:completionHandler:)`: iOS woke the app
     because transfers finished; `completion` is called once their events have been handled.
     */
    public static func handleBackgroundEvents(completion: @escaping () -> Void) {
        FileDownloader.backgroundEventsDone = completion
    }
}

/// Adds up the progress of a pack's files for `DownloadState`.
@MainActor
private final class DownloadProgress {
    private let total: Int64
    private let hasBasemap: Bool
    private let onChange: (DownloadState) -> Void
    private var railway: Int64 = 0
    private var basemap: Int64 = 0
    private var railwayDone = false
    private var basemapDone = false

    init(total: Int64, hasBasemap: Bool, onChange: @escaping (DownloadState) -> Void) {
        self.total = total
        self.hasBasemap = hasBasemap
        self.onChange = onChange
    }

    func update(railway bytes: Int64, done: Bool) {
        railway = bytes
        railwayDone = railwayDone || done
        report()
    }

    func update(basemap bytes: Int64, done: Bool) {
        basemap = bytes
        basemapDone = basemapDone || done
        report()
    }

    func report() {
        let stage: String
        switch (railwayDone, basemapDone || !hasBasemap) {
        case (false, false):
            stage = "railway and basemap"
        case (false, true):
            stage = "railway"
        default:
            stage = "basemap"
        }
        onChange(.running(bytesDone: railway + basemap, bytesTotal: total, stage: stage))
    }
}

/**
 Downloads URLs to files in a background `URLSession`, which iOS carries on with while the app is
 suspended or not running at all; all callbacks arrive on the main queue.

 Each transfer is labelled with its target as `<staging folder>/<file>` relative to `root`, so a
 transfer that finishes while nobody waits for it (the app was ended and woken again) still lands
 in the right place, and a new run of the app can wait for transfers an earlier run started. When a
 transfer fails or is cancelled, its resume data is kept next to the target as `<file>.resume`, and
 the next attempt continues from there.
 */
@MainActor
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    static let sessionIdentifier = "com.offlinerailmap.ios.packs"

    /// Set when iOS woke the app for finished transfers; called once their events are handled.
    static var backgroundEventsDone: (() -> Void)?

    /// Pause before each retry of a failed transfer that can be resumed; after the last one it fails.
    private static let retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)]

    private struct Pending {
        let progress: (Int64) -> Void
        let continuation: CheckedContinuation<Int64, Error>
        var finishError: Error?
        var bytes: Int64 = 0
    }

    private let root: URL
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    init(root: URL) {
        self.root = root
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Started by the user, so it should run now rather than when iOS finds it convenient.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    static func fileSize(_ file: URL) -> Int64? {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return nil
        }
        return Int64(size)
    }

    static func resumeFile(for target: URL) -> URL {
        target.appendingPathExtension("resume")
    }

    /// Bytes an interrupted transfer to `target` had received, according to its resume data.
    static func resumableBytes(for target: URL) -> Int64 {
        guard let data = try? Data(contentsOf: resumeFile(for: target)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bytes = plist["NSURLSessionResumeBytesReceived"] as? NSNumber else {
            return 0
        }
        return bytes.int64Value
    }

    /**
     Downloads `url` into `target` and returns the size of `target`. Returns at once when `target`
     exists, waits for a transfer to it that is already running, and otherwise continues from resume
     data when there is some. `progress` gets the bytes received so far.
     */
    func download(from url: URL, to target: URL, progress: @escaping (Int64) -> Void) async throws -> Int64 {
        var failures = 0
        var lastReached = Self.resumableBytes(for: target)
        while true {
            do {
                return try await transfer(from: url, to: target, progress: progress)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                let reached = Self.resumableBytes(for: target)
                if reached > lastReached {
                    failures = 0 // data arrived, so the connection works; keep going
                }
                lastReached = reached
                guard reached > 0, !(error is PackError), failures < Self.retryDelays.count else {
                    throw error
                }
                Self.log.warning("download of \(url) interrupted at \(reached) bytes, retrying: \(error.localizedDescription)")
                try await Task.sleep(for: Self.retryDelays[failures])
                failures += 1
            }
        }
    }

    private static let log = Logger(subsystem: "com.offlinerailmap.ios", category: "FileDownloader")

    private func transfer(from url: URL, to target: URL, progress: @escaping (Int64) -> Void) async throws -> Int64 {
        let label = Self.label(for: target)
        let running = await session.allTasks.first {
            $0.taskDescription == label && ($0.state == .running || $0.state == .suspended)
        }
        // A transfer may have finished while the tasks were listed.
        if let size = Self.fileSize(target) {
            progress(size)
            return size
        }
        let task: URLSessionTask
        if let running, running.state == .running || running.state == .suspended {
            task = running
        } else {
            task = newTask(from: url, to: target, label: label)
        }
        let resumeFile = Self.resumeFile(for: target)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[task.taskIdentifier] = Pending(progress: progress, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            if let task = task as? URLSessionDownloadTask {
                task.cancel { data in
                    // The staging folder may be gone already when the user cancelled; then this fails.
                    try? data?.write(to: resumeFile)
                }
            } else {
                task.cancel()
            }
        }
    }

    private func newTask(from url: URL, to target: URL, label: String) -> URLSessionDownloadTask {
        let resumeFile = Self.resumeFile(for: target)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeFile) {
            try? FileManager.default.removeItem(at: resumeFile)
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: url)
        }
        task.taskDescription = label
        return task
    }

    /// Folder names of the staging folders that transfers are running into.
    func liveTaskFolders() async -> Set<String> {
        let tasks = await session.allTasks.filter { $0.state == .running || $0.state == .suspended }
        return Set(tasks.compactMap { $0.taskDescription?.split(separator: "/").first.map(String.init) })
    }

    func cancelTasks(inFolder folder: String) {
        Task {
            for task in await session.allTasks where task.taskDescription?.hasPrefix("\(folder)/") == true {
                task.cancel()
            }
        }
    }

    private static func label(for target: URL) -> String {
        "\(target.deletingLastPathComponent().lastPathComponent)/\(target.lastPathComponent)"
    }

    private func target(of task: URLSessionTask) -> URL? {
        guard let label = task.taskDescription, !label.isEmpty else {
            return nil
        }
        return root.appendingPathComponent(label)
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
            var entry = pending[downloadTask.taskIdentifier]
            do {
                if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw PackError("HTTP \(http.statusCode) for \(downloadTask.originalRequest?.url?.absoluteString ?? "")")
                }
                guard let target = target(of: downloadTask) else {
                    throw PackError("download without a target")
                }
                // The staging folder is gone when the download was cancelled or the pack deleted meanwhile.
                guard FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) else {
                    throw CancellationError()
                }
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: location, to: target)
                try? FileManager.default.removeItem(at: Self.resumeFile(for: target))
                entry?.bytes = Self.fileSize(target) ?? downloadTask.countOfBytesReceived
            } catch {
                entry?.finishError = error
            }
            if let entry {
                pending[downloadTask.taskIdentifier] = entry
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            if let error, let target = target(of: task),
               let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: Self.resumeFile(for: target))
            }
            guard let entry = pending.removeValue(forKey: task.taskIdentifier) else {
                return
            }
            if let error = error as? URLError, error.code == .cancelled {
                entry.continuation.resume(throwing: CancellationError())
            } else if let error = error ?? entry.finishError {
                entry.continuation.resume(throwing: error)
            } else {
                entry.progress(entry.bytes)
                entry.continuation.resume(returning: entry.bytes)
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            Self.backgroundEventsDone?()
            Self.backgroundEventsDone = nil
        }
    }
}
