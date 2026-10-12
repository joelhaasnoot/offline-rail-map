// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.data

import android.content.Context
import android.text.format.Formatter
import android.util.Log
import com.offlinerailmap.android.BuildConfig
import com.offlinerailmap.android.DownloadService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Keeps track of which country packs are installed on the device, fetches the remote
 * manifest, and downloads, updates and deletes packs. Folder layout: see [PackDirs]. A download
 * or update is written to a staging folder and only swapped in when complete, so the installed
 * copy keeps working during an update and survives a failed or cancelled one. A failed or
 * interrupted download keeps its staging folder, so downloading again continues where it stopped.
 */
object PackStore {
    private const val TAG = "PackStore"

    private lateinit var packsDir: File
    private lateinit var appContext: Context

    /** Extra free space required beyond the pack itself. */
    private const val SPACE_MARGIN_BYTES = 64L * 1024 * 1024

    /** How long a replaced copy is kept so the map can finish switching to the new files. */
    private const val REPLACED_COPY_GRACE_MS = 60_000L
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val http = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .build()
    private val jobs = ConcurrentHashMap<String, Job>()

    /** Pause before each retry of a dropped connection; after the last one the download fails. */
    private val RETRY_DELAYS_MS = longArrayOf(2_000, 5_000, 15_000, 30_000, 60_000)
    private const val PART_SUFFIX = ".part"
    private const val VALIDATOR_SUFFIX = ".validator"

    /** Pack version a staging folder downloads, so a newer version never continues an older one. */
    private const val VERSION_FILE = "version"

    private val _active = MutableStateFlow<Set<String>>(emptySet())

    /** Ids of packs being downloaded right now, including runs that have not reported progress yet. */
    val active: StateFlow<Set<String>> = _active

    private val _installed = MutableStateFlow<List<InstalledPack>>(emptyList())
    val installed: StateFlow<List<InstalledPack>> = _installed

    private val _available = MutableStateFlow<List<PackInfo>>(emptyList())
    val available: StateFlow<List<PackInfo>> = _available

    private val _manifestError = MutableStateFlow<String?>(null)
    val manifestError: StateFlow<String?> = _manifestError

    private val _manifestLoading = MutableStateFlow(false)
    val manifestLoading: StateFlow<Boolean> = _manifestLoading

    private val _downloads = MutableStateFlow<Map<String, DownloadState>>(emptyMap())
    val downloads: StateFlow<Map<String, DownloadState>> = _downloads

    var manifestUrl: String = BuildConfig.MANIFEST_URL
        private set

    fun init(context: Context) {
        appContext = context.applicationContext
        packsDir = File(context.filesDir, "packs").also { it.mkdirs() }
        // Keep the newest download of each pack that the app stopped part way, so it can be resumed.
        val partial = packsDir.listFiles()?.filter { it.isDirectory && PackDirs.isStaging(it.name) }.orEmpty()
        for ((id, dirs) in partial.groupBy { PackDirs.idOf(it.name) }) {
            val keep = dirs.filter { stagedVersion(it) != null && partialBytes(it) > 0 }.maxByOrNull { PackDirs.timestamp(it.name) }
            dirs.filter { it != keep }.forEach { it.deleteRecursively() }
            if (keep != null) {
                setProgress(id, DownloadState.Failed("the app was closed", partialBytes(keep)))
            }
        }
        scanInstalled(deleteSuperseded = true)
    }

    private fun scanInstalled(deleteSuperseded: Boolean) {
        val copies = packsDir.listFiles()?.filter { it.isDirectory && !PackDirs.isStaging(it.name) }?.mapNotNull { dir ->
            val meta = File(dir, "pack.json")
            if (!meta.isFile) {
                return@mapNotNull null
            }
            try {
                val info = PackInfo.fromJson(JSONObject(meta.readText()))
                val pack = InstalledPack(info, dir)
                if (pack.railwayFile.isFile) pack else null
            } catch (e: Exception) {
                Log.w(TAG, "ignoring broken pack in $dir", e)
                null
            }
        }.orEmpty()
        val (chosen, superseded) = PackDirs.choose(copies, { it.info.id }, { it.info.version }, { it.dir.name })
        _installed.value = chosen.sortedBy { it.info.name }
        if (deleteSuperseded) {
            superseded.forEach { it.dir.deleteRecursively() }
        }
    }

    fun refreshManifest(url: String = manifestUrl) {
        manifestUrl = url
        // Flip the flag before launching so a pull-to-refresh indicator does not flicker.
        _manifestLoading.value = true
        scope.launch {
            _manifestError.value = null
            try {
                val body = http.newCall(Request.Builder().url(url).build()).execute().use { resp ->
                    if (!resp.isSuccessful) {
                        throw IOException("HTTP ${resp.code}")
                    }
                    resp.body.string()
                }
                val packs = PackInfo.listFromManifest(JSONObject(body))
                _available.value = packs.sortedWith(compareBy({ it.region }, { it.name }))
                upgradeInstalledMetadata(packs)
            } catch (e: Exception) {
                Log.w(TAG, "manifest fetch failed", e)
                _manifestError.value = e.message ?: e.toString()
            } finally {
                _manifestLoading.value = false
            }
        }
    }

    /** Installed packs written by older manifests may lack the coverage polygon; copy it over. */
    private fun upgradeInstalledMetadata(remote: List<PackInfo>) {
        var changed = false
        for (pack in _installed.value) {
            val newer = remote.firstOrNull { it.id == pack.info.id } ?: continue
            if (pack.info.coverage.isEmpty() && newer.coverage.isNotEmpty()) {
                File(pack.dir, "pack.json").writeText(pack.info.copy(coverage = newer.coverage).toJson().toString())
                changed = true
            }
        }
        if (changed) {
            scanInstalled(deleteSuperseded = false)
        }
    }

    fun isInstalled(id: String): InstalledPack? = _installed.value.firstOrNull { it.info.id == id }

    /**
     * Downloads [pack], or updates it when an older copy is installed. Continues an earlier,
     * unfinished download of the same version. [DownloadService] keeps the app running meanwhile.
     */
    fun download(pack: PackInfo) {
        val previous = jobs[pack.id]
        if (previous?.isActive == true) {
            return
        }
        _downloads.update { it - pack.id }
        val job = scope.launch(start = CoroutineStart.LAZY) {
            previous?.join() // a cancelled run may still be removing its folder
            var staging: File? = null
            try {
                val dir = stagingFor(pack).also { staging = it }
                val needed = pack.totalBytes - partialBytes(dir) + SPACE_MARGIN_BYTES
                val free = packsDir.usableSpace
                if (free < needed) {
                    throw IOException(
                        "not enough free space: needs ${Formatter.formatShortFileSize(appContext, needed)}, " +
                            "${Formatter.formatShortFileSize(appContext, free)} available",
                    )
                }
                val total = pack.totalBytes
                setProgress(pack.id, DownloadState.Running(0, total, "railway"))
                val railway = downloadFile(pack.railwayUrl, File(dir, "railway.pmtiles")) { d ->
                    setProgress(pack.id, DownloadState.Running(d, total, "railway"))
                }
                if (pack.basemapUrl != null) {
                    downloadFile(pack.basemapUrl, File(dir, "basemap.pmtiles")) { d ->
                        setProgress(pack.id, DownloadState.Running(railway + d, total, "basemap"))
                    }
                }
                File(dir, VERSION_FILE).delete()
                File(dir, "pack.json").writeText(pack.toJson().toString())
                val installed = File(packsDir, PackDirs.installedName(dir.name))
                if (!dir.renameTo(installed)) {
                    throw IOException("could not move ${dir.name} into place")
                }
                val replaced = _installed.value.filter { it.info.id == pack.id }
                _downloads.update { it - pack.id }
                scanInstalled(deleteSuperseded = false)
                if (replaced.isNotEmpty()) {
                    // The map keeps reading the previous files until it has switched to the new copy.
                    scope.launch {
                        delay(REPLACED_COPY_GRACE_MS)
                        replaced.forEach { it.dir.deleteRecursively() }
                    }
                }
            } catch (e: CancellationException) {
                staging?.deleteRecursively()
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "download of ${pack.id} failed", e)
                // Keep what arrived so the download can be resumed instead of starting over.
                setProgress(pack.id, DownloadState.Failed(e.message ?: e.toString(), staging?.let(::partialBytes) ?: 0))
            }
        }
        jobs[pack.id] = job
        job.invokeOnCompletion {
            if (jobs.remove(pack.id, job)) {
                _active.update { it - pack.id }
            }
        }
        _active.update { it + pack.id }
        DownloadService.start(appContext)
        job.start()
    }

    /** The staging folder of an unfinished download of this version of [pack], or a new one. */
    private fun stagingFor(pack: PackInfo): File {
        val partial = packsDir.listFiles()
            ?.filter { it.isDirectory && PackDirs.isStaging(it.name) && PackDirs.belongsTo(it.name, pack.id) }
            .orEmpty()
        val reusable = partial.filter { stagedVersion(it) == pack.version }.maxByOrNull { PackDirs.timestamp(it.name) }
        partial.filter { it != reusable }.forEach { it.deleteRecursively() }
        if (reusable != null) {
            return reusable
        }
        val dir = File(packsDir, PackDirs.stagingName(pack.id, System.currentTimeMillis()))
        if (!dir.mkdirs()) {
            throw IOException("could not create ${dir.name}")
        }
        File(dir, VERSION_FILE).writeText(pack.version.toString())
        return dir
    }

    private fun stagedVersion(dir: File): Int? = File(dir, VERSION_FILE).takeIf { it.isFile }?.readText()?.trim()?.toIntOrNull()

    /** Bytes already downloaded into a staging folder, finished files and partial ones. */
    private fun partialBytes(dir: File): Long =
        dir.listFiles()?.filter { it.name.endsWith(".pmtiles") || it.name.endsWith(PART_SUFFIX) }?.sumOf { it.length() } ?: 0

    /** Stops a running download or update. An installed copy is left untouched. */
    fun cancel(id: String) {
        // The job stays in [jobs] until it has finished, so a new download of [id] waits for it.
        jobs[id]?.cancel()
        _active.update { it - id }
        _downloads.update { it - id }
    }

    fun cancelAll() {
        _active.value.forEach(::cancel)
    }

    /** Removes a pack from the device, including any download of it that is in progress. */
    fun delete(id: String) {
        cancel(id)
        packsDir.listFiles()?.filter { PackDirs.belongsTo(it.name, id) }?.forEach { it.deleteRecursively() }
        scanInstalled(deleteSuperseded = false)
    }

    /** Clears a failed download, including what it had downloaded so far. */
    fun dismissError(id: String) {
        _downloads.update { it - id }
        if (jobs[id]?.isActive != true) {
            packsDir.listFiles()?.filter { PackDirs.isStaging(it.name) && PackDirs.belongsTo(it.name, id) }?.forEach { it.deleteRecursively() }
        }
    }

    private fun setProgress(id: String, state: DownloadState) {
        _downloads.update { it + (id to state) }
    }

    /**
     * Streams [url] into [target] via a `.part` file; returns the size of [target]. Continues a
     * `.part` file left by an earlier attempt, and retries a few times when the connection drops.
     * [onProgress] gets the number of bytes of the file downloaded so far.
     */
    private suspend fun downloadFile(url: String, target: File, onProgress: (Long) -> Unit): Long {
        if (!target.isFile) {
            val part = File(target.path + PART_SUFFIX)
            val validator = File(target.path + VALIDATOR_SUFFIX)
            var failures = 0
            while (true) {
                val before = part.length()
                try {
                    transfer(url, part, validator, onProgress)
                    break
                } catch (e: IOException) {
                    currentCoroutineContext().ensureActive()
                    if (part.length() > before) {
                        failures = 0 // data arrived, so the connection works; keep going
                    }
                    if ((e is HttpStatusException && !Resume.isRetryable(e.code)) || failures >= RETRY_DELAYS_MS.size) {
                        throw e
                    }
                    Log.w(TAG, "download of $url interrupted at ${part.length()} bytes, retrying: $e")
                    delay(RETRY_DELAYS_MS[failures++])
                }
            }
            if (!part.renameTo(target)) {
                throw IOException("could not move ${part.name} into place")
            }
            validator.delete()
        }
        onProgress(target.length())
        return target.length()
    }

    /** One request for the rest of [url], appended to [part]. */
    private suspend fun transfer(url: String, part: File, validatorFile: File, onProgress: (Long) -> Unit) {
        val have = part.length()
        val validator = validatorFile.takeIf { it.isFile }?.readText()
        val request = Request.Builder().url(url)
            // Byte offsets must count bytes of the file itself, not of a compressed transfer of it.
            .header("Accept-Encoding", "identity")
        if (have > 0 && validator != null) {
            request.header("Range", "bytes=$have-").header("If-Range", validator)
        }
        val call = http.newCall(request.build())
        // A blocking read does not notice cancellation; closing the connection ends it.
        val onCancel = currentCoroutineContext()[Job]?.invokeOnCompletion { call.cancel() }
        try {
            call.execute().use { resp ->
                if (resp.code == 416) {
                    part.delete()
                    throw IOException("server refused to resume $url")
                }
                if (!resp.isSuccessful) {
                    throw HttpStatusException(resp.code, url)
                }
                val offset = Resume.writeOffset(resp.code, resp.header("Content-Range"), have)
                if (offset == null) {
                    part.delete()
                    throw IOException("unexpected range in response for $url")
                }
                if (offset == 0L) {
                    val v = Resume.validator(resp.header("ETag"), resp.header("Last-Modified"))
                    if (v != null) {
                        validatorFile.writeText(v)
                    } else {
                        validatorFile.delete()
                    }
                }
                var written: Long = offset
                var lastReport = written
                onProgress(written)
                resp.body.byteStream().use { input ->
                    FileOutputStream(part, offset > 0).buffered(1 shl 16).use { out ->
                        val buf = ByteArray(1 shl 16)
                        while (true) {
                            currentCoroutineContext().ensureActive() // stop promptly when cancelled
                            val n = input.read(buf)
                            if (n < 0) {
                                break
                            }
                            out.write(buf, 0, n)
                            written += n
                            if (written - lastReport > 512 * 1024) {
                                lastReport = written
                                onProgress(written)
                            }
                        }
                    }
                }
            }
        } finally {
            onCancel?.dispose()
        }
    }

    private class HttpStatusException(val code: Int, url: String) : IOException("HTTP $code for $url")
}
