package com.lo.audiomind.audiomind

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.net.wifi.WifiManager
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipFile

class MainActivity : AudioServiceActivity() {
    private val CHANNEL = "com.lo.audiomind/pdf_cover"
    private val DOWNLOAD_CHANNEL_ID = "audibuuks_offline_downloads"
    private val DOWNLOAD_NOTIFICATION_ID = 4402

    private var lofiPlayer: MediaPlayer? = null
    private var lofiVolume: Float = 0.25f
    private var currentTrackPath: String? = null
    private var isAllowedToPlay: Boolean = false

    private var cpuWakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    private fun ensureDownloadNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(DOWNLOAD_CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    DOWNLOAD_CHANNEL_ID,
                    "Audibuuks Descargas Offline",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Progreso de descarga de audiolibros en segundo plano"
                    setShowBadge(false)
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                }
                nm.createNotificationChannel(channel)
            }
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    1001
                )
            }
        }
    }

    private fun acquireBackgroundNetworkLocks() {
        try {
            if (cpuWakeLock == null) {
                val pm = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
                cpuWakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "Audibuuks::BackgroundDownloadWakeLock"
                ).apply {
                    setReferenceCounted(false)
                }
            }
            if (cpuWakeLock?.isHeld == false) {
                // Hasta 45 minutos máximo de protección continua por sesión de descarga/buffer
                cpuWakeLock?.acquire(45 * 60 * 1000L)
            }

            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val lockType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm.createWifiLock(lockType, "Audibuuks::BackgroundWifiLock").apply {
                    setReferenceCounted(false)
                }
            }
            if (wifiLock?.isHeld == false) {
                wifiLock?.acquire()
            }
        } catch (_: Exception) {}
    }

    private fun releaseBackgroundNetworkLocks() {
        try {
            if (cpuWakeLock?.isHeld == true) {
                cpuWakeLock?.release()
            }
        } catch (_: Exception) {}
        try {
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
        } catch (_: Exception) {}
    }

    private fun showDownloadProgressNotification(
        title: String,
        subtitle: String,
        progress: Int,
        maxProgress: Int,
        ongoing: Boolean
    ) {
        try {
            ensureDownloadNotificationChannel()
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            val launchIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pendingIntent = PendingIntent.getActivity(this, 0, launchIntent, pendingFlags)

            val builder = NotificationCompat.Builder(this, DOWNLOAD_CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(subtitle)
                .setOnlyAlertOnce(true)
                .setOngoing(ongoing)
                .setAutoCancel(!ongoing)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setColor(0xFFF5A623.toInt())
                .setContentIntent(pendingIntent)

            if (ongoing && maxProgress > 0) {
                builder.setProgress(maxProgress, progress.coerceIn(0, maxProgress), false)
            } else {
                builder.setProgress(0, 0, false)
            }

            nm.notify(DOWNLOAD_NOTIFICATION_ID, builder.build())
        } catch (_: Exception) {}
    }

    private fun cancelDownloadNotification() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(DOWNLOAD_NOTIFICATION_ID)
        } catch (_: Exception) {}
    }

    private fun setupAndPreparePlayer(path: String, autoStart: Boolean) {
        try {
            currentTrackPath = path
            lofiPlayer?.let {
                try {
                    if (it.isPlaying) it.stop()
                } catch (_: Exception) {}
                it.release()
            }
            lofiPlayer = null

            val mp = MediaPlayer()
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            mp.setDataSource(path)
            mp.isLooping = true
            mp.setVolume(lofiVolume, lofiVolume)
            mp.prepare()
            lofiPlayer = mp

            if (autoStart && isAllowedToPlay && lofiVolume > 0f) {
                mp.start()
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireBackgroundLock" -> {
                    acquireBackgroundNetworkLocks()
                    result.success(true)
                }
                "releaseBackgroundLock" -> {
                    releaseBackgroundNetworkLocks()
                    result.success(true)
                }
                "updateDownloadNotification" -> {
                    requestNotificationPermissionIfNeeded()
                    acquireBackgroundNetworkLocks()
                    val title = call.argument<String>("title") ?: "Descargando audiolibro..."
                    val subtitle = call.argument<String>("subtitle") ?: ""
                    val progress = call.argument<Int>("progress") ?: 0
                    val maxProgress = call.argument<Int>("maxProgress") ?: 100
                    val ongoing = call.argument<Boolean>("ongoing") ?: true
                    showDownloadProgressNotification(title, subtitle, progress, maxProgress, ongoing)
                    if (!ongoing) {
                        releaseBackgroundNetworkLocks()
                    }
                    result.success(true)
                }
                "cancelDownloadNotification" -> {
                    releaseBackgroundNetworkLocks()
                    cancelDownloadNotification()
                    result.success(true)
                }
                "renderFirstPage" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("NO_PATH", "Path is null", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val file = File(path)
                            val pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                            val renderer = PdfRenderer(pfd)
                            if (renderer.pageCount > 0) {
                                val page = renderer.openPage(0)
                                val width = 650
                                val height = (width.toFloat() / page.width * page.height).toInt().coerceAtLeast(1)
                                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                                bitmap.eraseColor(Color.WHITE)
                                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                page.close()
                                renderer.close()
                                pfd.close()

                                val stream = ByteArrayOutputStream()
                                bitmap.compress(Bitmap.CompressFormat.JPEG, 88, stream)
                                val bytes = stream.toByteArray()
                                runOnUiThread { result.success(bytes) }
                            } else {
                                renderer.close()
                                pfd.close()
                                runOnUiThread { result.error("EMPTY", "PDF has no pages", null) }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("ERR", e.message, null) }
                        }
                    }.start()
                }
                "renderPdfPage" -> {
                    val path = call.argument<String>("path")
                    val pageIndex = call.argument<Int>("pageIndex") ?: 0
                    val renderWidth = call.argument<Int>("width") ?: 1080
                    if (path == null) {
                        result.error("NO_PATH", "Path is null", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val file = File(path)
                            if (!file.exists()) {
                                runOnUiThread { result.error("NOT_FOUND", "PDF file not found", null) }
                                return@Thread
                            }
                            val pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                            val renderer = PdfRenderer(pfd)
                            val count = renderer.pageCount
                            if (count > 0) {
                                val safeIndex = pageIndex.coerceIn(0, count - 1)
                                val page = renderer.openPage(safeIndex)
                                val height = (renderWidth.toFloat() / page.width * page.height).toInt().coerceAtLeast(1)
                                val bitmap = Bitmap.createBitmap(renderWidth, height, Bitmap.Config.ARGB_8888)
                                bitmap.eraseColor(Color.WHITE)
                                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                page.close()
                                renderer.close()
                                pfd.close()

                                val stream = ByteArrayOutputStream()
                                bitmap.compress(Bitmap.CompressFormat.JPEG, 90, stream)
                                val bytes = stream.toByteArray()
                                runOnUiThread {
                                    result.success(
                                        mapOf(
                                            "bytes" to bytes,
                                            "pageCount" to count,
                                            "pageIndex" to safeIndex
                                        )
                                    )
                                }
                            } else {
                                renderer.close()
                                pfd.close()
                                runOnUiThread { result.error("EMPTY", "PDF has no pages", null) }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("ERR", e.message, null) }
                        }
                    }.start()
                }
                "extractEpub" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("NO_PATH", "Path is null", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val zip = ZipFile(File(path))
                            var coverBytes: ByteArray? = null
                            var opfContent: String? = null
                            var opfDir = ""
                            val htmlMap = mutableMapOf<String, String>()

                            val entries = zip.entries()
                            while (entries.hasMoreElements()) {
                                val entry = entries.nextElement()
                                if (entry.isDirectory) continue
                                val name = entry.name
                                val lower = name.lowercase()

                                if (lower.endsWith(".opf") && opfContent == null) {
                                    opfContent = zip.getInputStream(entry).bufferedReader().use { it.readText() }
                                    val slashIdx = name.lastIndexOf('/')
                                    opfDir = if (slashIdx != -1) name.substring(0, slashIdx + 1) else ""
                                } else if (lower.endsWith(".xhtml") || lower.endsWith(".html") || lower.endsWith(".htm")) {
                                    val text = zip.getInputStream(entry).bufferedReader().use { it.readText() }
                                    htmlMap[name] = text
                                } else if ((lower.contains("cover") || lower.contains("portada")) &&
                                    (lower.endsWith(".jpg") || lower.endsWith(".jpeg") || lower.endsWith(".png"))
                                ) {
                                    val b = zip.getInputStream(entry).use { it.readBytes() }
                                    if (b.size > 2000 && (coverBytes == null || b.size > coverBytes!!.size)) {
                                        coverBytes = b
                                    }
                                }
                            }

                            if (coverBytes == null) {
                                val imgEntries = zip.entries()
                                while (imgEntries.hasMoreElements()) {
                                    val entry = imgEntries.nextElement()
                                    if (entry.isDirectory) continue
                                    val lower = entry.name.lowercase()
                                    if (lower.endsWith(".jpg") || lower.endsWith(".jpeg") || lower.endsWith(".png")) {
                                        val b = zip.getInputStream(entry).use { it.readBytes() }
                                        if (b.size > 4000 && (coverBytes == null || b.size > coverBytes!!.size)) {
                                            coverBytes = b
                                        }
                                    }
                                }
                            }

                            zip.close()

                            val orderedHtmlList = mutableListOf<String>()
                            if (opfContent != null) {
                                val idToHref = mutableMapOf<String, String>()
                                val itemRegex = Regex("""<item\s+[^>]*id=["']([^"']+)["'][^>]*href=["']([^"']+)["'][^>]*>""", RegexOption.IGNORE_CASE)
                                val itemRegex2 = Regex("""<item\s+[^>]*href=["']([^"']+)["'][^>]*id=["']([^"']+)["'][^>]*>""", RegexOption.IGNORE_CASE)
                                for (m in itemRegex.findAll(opfContent!!)) {
                                    idToHref[m.groupValues[1]] = m.groupValues[2]
                                }
                                for (m in itemRegex2.findAll(opfContent!!)) {
                                    idToHref[m.groupValues[2]] = m.groupValues[1]
                                }
                                val itemrefRegex = Regex("""<itemref\s+[^>]*idref=["']([^"']+)["']""", RegexOption.IGNORE_CASE)
                                for (m in itemrefRegex.findAll(opfContent!!)) {
                                    val idref = m.groupValues[1]
                                    val href = idToHref[idref]
                                    if (href != null) {
                                        val cleanHref = href.substringBefore('#')
                                        val fullKey = if (htmlMap.containsKey(opfDir + cleanHref)) {
                                            opfDir + cleanHref
                                        } else {
                                            htmlMap.keys.firstOrNull { it.endsWith(cleanHref) }
                                        }
                                        if (fullKey != null && htmlMap.containsKey(fullKey)) {
                                            orderedHtmlList.add(htmlMap[fullKey]!!)
                                            htmlMap.remove(fullKey)
                                        }
                                    }
                                }
                            }
                            if (orderedHtmlList.isEmpty()) {
                                val sortedKeys = htmlMap.keys.sorted()
                                for (k in sortedKeys) {
                                    orderedHtmlList.add(htmlMap[k]!!)
                                }
                            }

                            runOnUiThread {
                                result.success(
                                    mapOf(
                                        "coverBytes" to coverBytes,
                                        "chaptersHtml" to orderedHtmlList
                                    )
                                )
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("EPUB_ERR", e.message, null) }
                        }
                    }.start()
                }
                "initLoFi" -> {
                    val path = call.argument<String>("path")
                    val autoStart = call.argument<Boolean>("autoStart") ?: false
                    isAllowedToPlay = autoStart
                    if (path != null) {
                        setupAndPreparePlayer(path, autoStart)
                        result.success(true)
                    } else {
                        result.error("NO_PATH", "Path null", null)
                    }
                }
                "playLoFi" -> {
                    try {
                        isAllowedToPlay = true
                        val path = call.argument<String>("path") ?: currentTrackPath
                        if (lofiPlayer == null && path != null) {
                            setupAndPreparePlayer(path, true)
                        } else if (lofiPlayer != null && lofiVolume > 0f) {
                            lofiPlayer?.setVolume(lofiVolume, lofiVolume)
                            if (!lofiPlayer!!.isPlaying) {
                                lofiPlayer?.start()
                            }
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "pauseLoFi" -> {
                    try {
                        isAllowedToPlay = false
                        lofiPlayer?.let {
                            it.setVolume(0f, 0f)
                            if (it.isPlaying) {
                                it.pause()
                            }
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "setLoFiVolume" -> {
                    val vol = (call.argument<Double>("volume") ?: 0.25).toFloat()
                    lofiVolume = vol
                    try {
                        if (vol <= 0f) {
                            lofiPlayer?.setVolume(0f, 0f)
                            if (lofiPlayer?.isPlaying == true) {
                                lofiPlayer?.pause()
                            }
                        } else if (isAllowedToPlay && lofiPlayer != null) {
                            lofiPlayer?.setVolume(vol, vol)
                            if (!lofiPlayer!!.isPlaying) {
                                lofiPlayer?.start()
                            }
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        isAllowedToPlay = false
        releaseBackgroundNetworkLocks()
        lofiPlayer?.release()
        lofiPlayer = null
        super.onDestroy()
    }
}
