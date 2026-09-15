// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.data

import android.content.Context
import android.text.format.Formatter
import android.util.Log
import com.offlinerailmap.android.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
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
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Keeps track of which country packs are installed on the device, fetches the remote
 * manifest, and downloads, updates and deletes packs. Folder layout: see [PackDirs]. A download
 * or update is written to a staging folder and only swapped in when complete, so the installed
 * copy keeps working during an update and survives a failed or cancelled one.
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
    private val jobs = HashMap<String, Job>()

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
        // Downloads interrupted by the app being killed are not resumed; drop their leftovers.
        packsDir.listFiles()?.filter { it.isDirectory && PackDirs.isStaging(it.name) }?.forEach { it.deleteRecursively() }
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

    /** Downloads [pack], or updates it when an older copy is installed. */
    fun download(pack: PackInfo) {
        if (jobs[pack.id]?.isActive == true) {
            return
        }
        _downloads.update { it - pack.id }
        jobs[pack.id] = scope.launch {
            val staging = File(packsDir, PackDirs.stagingName(pack.id, System.currentTimeMillis()))
            try {
                val needed = pack.totalBytes + SPACE_MARGIN_BYTES
                val free = packsDir.usableSpace
                if (free < needed) {
                    throw IOException(
                        "not enough free space: needs ${Formatter.formatShortFileSize(appContext, needed)}, " +
                            "${Formatter.formatShortFileSize(appContext, free)} available",
                    )
                }
                if (!staging.mkdirs()) {
                    throw IOException("could not create ${staging.name}")
                }
                var done = 0L
                val total = pack.totalBytes
                setProgress(pack.id, DownloadState.Running(0, total, "railway"))
                done += downloadFile(pack.railwayUrl, File(staging, "railway.pmtiles")) { d ->
                    setProgress(pack.id, DownloadState.Running(done + d, total, "railway"))
                }
                if (pack.basemapUrl != null) {
                    done += downloadFile(pack.basemapUrl, File(staging, "basemap.pmtiles")) { d ->
                        setProgress(pack.id, DownloadState.Running(done + d, total, "basemap"))
                    }
                }
                File(staging, "pack.json").writeText(pack.toJson().toString())
                val installed = File(packsDir, PackDirs.installedName(staging.name))
                if (!staging.renameTo(installed)) {
                    throw IOException("could not move ${staging.name} into place")
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
                staging.deleteRecursively()
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "download of ${pack.id} failed", e)
                staging.deleteRecursively()
                setProgress(pack.id, DownloadState.Failed(e.message ?: e.toString()))
            }
        }
    }

    /** Stops a running download or update. An installed copy is left untouched. */
    fun cancel(id: String) {
        jobs.remove(id)?.cancel()
        _downloads.update { it - id }
    }

    /** Removes a pack from the device, including any download of it that is in progress. */
    fun delete(id: String) {
        cancel(id)
        packsDir.listFiles()?.filter { PackDirs.belongsTo(it.name, id) }?.forEach { it.deleteRecursively() }
        scanInstalled(deleteSuperseded = false)
    }

    fun dismissError(id: String) {
        _downloads.update { it - id }
    }

    private fun setProgress(id: String, state: DownloadState) {
        _downloads.update { it + (id to state) }
    }

    /** Streams [url] into [target] via a temporary file; returns the number of bytes written. */
    private suspend fun downloadFile(url: String, target: File, onProgress: (Long) -> Unit): Long {
        val tmp = File(target.path + ".part")
        val resp = http.newCall(Request.Builder().url(url).build()).execute()
        resp.use {
            if (!resp.isSuccessful) {
                throw IOException("HTTP ${resp.code} for $url")
            }
            var written = 0L
            var lastReport = 0L
            resp.body.byteStream().use { input ->
                tmp.outputStream().buffered(1 shl 16).use { out ->
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
            if (!tmp.renameTo(target)) {
                throw IOException("could not move ${tmp.name} into place")
            }
            onProgress(written)
            return written
        }
    }
}
