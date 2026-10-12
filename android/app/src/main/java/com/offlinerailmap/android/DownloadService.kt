// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android

import android.annotation.SuppressLint
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import com.offlinerailmap.android.data.DownloadState
import com.offlinerailmap.android.data.PackStore
import com.offlinerailmap.android.ui.formatBytes
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Keeps the app running while [PackStore] downloads packs, so a download carries on when the user
 * switches apps or the screen turns off: a foreground service with a progress notification, plus a
 * wake lock so the phone does not sleep mid-transfer. Stops itself once no download is running.
 */
class DownloadService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var wakeLock: PowerManager.WakeLock? = null
    private var watchers: Job? = null
    private var lastStartId = 0

    /** Packs downloaded while this service ran, for the summary when it stops. */
    private val seen = LinkedHashSet<String>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        // Each start through startForegroundService must be answered with startForeground.
        ServiceCompat.startForeground(this, PROGRESS_ID, progressNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        if (intent?.action == ACTION_CANCEL) {
            PackStore.cancelAll()
        }
        if (wakeLock?.isHeld != true) {
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OfflineRailMap:download")
                .apply { acquire(WAKE_LOCK_TIMEOUT_MS) }
        }
        if (watchers?.isActive != true) {
            watchers = scope.launch {
                launch {
                    PackStore.active.collect { active ->
                        seen += active
                        if (active.isEmpty()) {
                            finish()
                        }
                    }
                }
                launch {
                    // The state changes every half megabyte; the notification only needs a refresh now and then.
                    PackStore.downloads.collect {
                        if (PackStore.active.value.isNotEmpty()) {
                            notify(PROGRESS_ID, progressNotification())
                        }
                        delay(PROGRESS_INTERVAL_MS)
                    }
                }
            }
        }
        return START_NOT_STICKY
    }

    /** Android 15 limits how long a data sync service may run per day. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "foreground time limit reached; downloads continue without the service")
        finish()
    }

    override fun onDestroy() {
        scope.cancel()
        wakeLock?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }

    private fun finish() {
        watchers?.cancel()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        summaryNotification()?.let { notify(SUMMARY_ID, it) }
        seen.clear()
        wakeLock?.takeIf { it.isHeld }?.release()
        // Keeps running when a new download asked for the service in the meantime.
        stopSelf(lastStartId)
    }

    private fun progressNotification(): Notification {
        val running = PackStore.downloads.value.filterValues { it is DownloadState.Running }
            .mapValues { it.value as DownloadState.Running }
        val done = running.values.sumOf { it.bytesDone }
        val total = running.values.sumOf { it.bytesTotal }
        val title = when (running.size) {
            0 -> "Preparing download"
            1 -> "Downloading ${packName(running.keys.first())}"
            else -> "Downloading ${running.size} countries"
        }
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentIntent(openApp())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(0, "Cancel", cancelIntent())
        if (total > 0) {
            builder.setContentText("${formatBytes(done)} of ${formatBytes(total)}")
            builder.setProgress(PROGRESS_MAX, (done * PROGRESS_MAX / total).toInt(), false)
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }

    /** Tells how the downloads of this run ended, for when the app is not on screen. */
    private fun summaryNotification(): Notification? {
        val failed = seen.filter { PackStore.downloads.value[it] is DownloadState.Failed }
        val finished = seen.filter { it !in failed && PackStore.isInstalled(it) != null && it !in PackStore.downloads.value }
        val (title, text) = when {
            failed.isNotEmpty() -> {
                val state = PackStore.downloads.value[failed.first()] as DownloadState.Failed
                "Download of ${failed.joinToString { packName(it) }} stopped" to
                    (if (state.resumable) "Open the app to resume. " else "") + state.message
            }
            finished.isNotEmpty() -> "${finished.joinToString { packName(it) }} ready to use offline" to null
            else -> return null
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(if (failed.isEmpty()) android.R.drawable.stat_sys_download_done else android.R.drawable.stat_notify_error)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openApp())
            .setAutoCancel(true)
            .setSilent(true)
            .build()
    }

    private fun packName(id: String): String =
        PackStore.available.value.firstOrNull { it.id == id }?.name ?: PackStore.isInstalled(id)?.info?.name ?: id

    private fun openApp(): PendingIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun cancelIntent(): PendingIntent = PendingIntent.getService(
        this,
        0,
        Intent(this, DownloadService::class.java).setAction(ACTION_CANCEL),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    @SuppressLint("MissingPermission") // checked through areNotificationsEnabled
    private fun notify(id: Int, notification: Notification) {
        val manager = NotificationManagerCompat.from(this)
        if (manager.areNotificationsEnabled()) {
            try {
                manager.notify(id, notification)
            } catch (e: SecurityException) {
                Log.w(TAG, "notification not allowed", e)
            }
        }
    }

    companion object {
        private const val TAG = "DownloadService"
        private const val CHANNEL_ID = "downloads"
        private const val PROGRESS_ID = 1
        private const val SUMMARY_ID = 2
        private const val PROGRESS_MAX = 1000
        private const val PROGRESS_INTERVAL_MS = 1_000L
        private const val ACTION_CANCEL = "com.offlinerailmap.android.CANCEL_DOWNLOADS"

        /** Upper bound in case the service is never stopped; far longer than any pack takes. */
        private const val WAKE_LOCK_TIMEOUT_MS = 3 * 60 * 60 * 1000L

        /** Called when a download starts, while the app is on screen. */
        fun start(context: Context) {
            NotificationManagerCompat.from(context).createNotificationChannel(
                NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
                    .setName("Downloads")
                    .setDescription("Progress of country pack downloads")
                    .build(),
            )
            try {
                context.startForegroundService(Intent(context, DownloadService::class.java))
            } catch (e: IllegalStateException) {
                // Not allowed from the background; the download still runs while the app stays alive.
                Log.w(TAG, "could not start download service", e)
            }
        }
    }
}
