// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap.data

import android.content.Context
import android.util.Log
import app.offlinerailwaymap.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
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
 * manifest, and downloads / deletes packs. A pack lives in `filesDir/packs/<id>/` and is
 * considered installed once `pack.json` exists there (written last, after all files).
 */
object PackStore {
    private const val TAG = "PackStore"

    private lateinit var packsDir: File
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
        packsDir = File(context.filesDir, "packs").also { it.mkdirs() }
        scanInstalled()
    }

    private fun scanInstalled() {
        val packs = packsDir.listFiles()?.filter { it.isDirectory }?.mapNotNull { dir ->
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
        }.orEmpty().sortedBy { it.info.name }
        _installed.value = packs
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
            scanInstalled()
        }
    }

    fun isInstalled(id: String): InstalledPack? = _installed.value.firstOrNull { it.info.id == id }

    fun download(pack: PackInfo) {
        if (jobs[pack.id]?.isActive == true) {
            return
        }
        jobs[pack.id] = scope.launch {
            val dir = File(packsDir, pack.id).also { it.mkdirs() }
            File(dir, "pack.json").delete()
            try {
                var done = 0L
                val total = pack.totalBytes
                setProgress(pack.id, DownloadState.Running(0, total, "railway"))
                done += downloadFile(pack.railwayUrl, File(dir, "railway.pmtiles")) { d ->
                    setProgress(pack.id, DownloadState.Running(done + d, total, "railway"))
                }
                if (pack.basemapUrl != null) {
                    done += downloadFile(pack.basemapUrl, File(dir, "basemap.pmtiles")) { d ->
                        setProgress(pack.id, DownloadState.Running(done + d, total, "basemap"))
                    }
                }
                File(dir, "pack.json").writeText(pack.toJson().toString())
                _downloads.update { it - pack.id }
                scanInstalled()
            } catch (e: Exception) {
                Log.w(TAG, "download of ${pack.id} failed", e)
                setProgress(pack.id, DownloadState.Failed(e.message ?: e.toString()))
            }
        }
    }

    fun cancel(id: String) {
        jobs.remove(id)?.cancel()
        _downloads.update { it - id }
        File(packsDir, id).deleteRecursively()
        scanInstalled()
    }

    fun delete(id: String) {
        cancel(id)
    }

    fun dismissError(id: String) {
        _downloads.update { it - id }
    }

    private fun setProgress(id: String, state: DownloadState) {
        _downloads.update { it + (id to state) }
    }

    /** Streams [url] into [target] via a temporary file; returns the number of bytes written. */
    private fun downloadFile(url: String, target: File, onProgress: (Long) -> Unit): Long {
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
