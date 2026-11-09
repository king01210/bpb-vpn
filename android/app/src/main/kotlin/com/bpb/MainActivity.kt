package com.bpb

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    companion object {
        private const val METHOD_CHANNEL = "bpb/core"
        private const val EVENT_CHANNEL = "bpb/state"
        private const val REQUEST_VPN = 0x0B9B
        private const val REQUEST_NOTIFICATIONS = 0x0B9C
        private const val REQUEST_PICK_FILE = 0x0B9D
        private const val REQUEST_SAVE_FILE = 0x0B9E

        /** Larger "settings files" are rejected rather than read into memory. */
        private const val MAX_PICKED_BYTES = 1 shl 20
        private const val DEFAULT_TEST_URL = "https://www.gstatic.com/generate_204"
    }

    private val background = Executors.newFixedThreadPool(4)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingPrepare: MethodChannel.Result? = null
    private var pendingPick: MethodChannel.Result? = null

    /** Android 7-9: waiting for the Save-as screen, with the content to write. */
    private var pendingSave: Pair<MethodChannel.Result, String>? = null
    private var stateListener: CoreManager.Listener? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(::onMethodCall)

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                val listener = CoreManager.Listener { state, error -> events.success(stateEvent(state, error)) }
                stateListener = listener
                CoreManager.addListener(listener)
                events.success(stateEvent(CoreManager.state, CoreManager.lastError))
            }

            override fun onCancel(arguments: Any?) {
                stateListener?.let { CoreManager.removeListener(it) }
                stateListener = null
            }
        })
    }

    override fun onDestroy() {
        stateListener?.let { CoreManager.removeListener(it) }
        background.shutdown()
        super.onDestroy()
    }

    private fun stateEvent(state: CoreManager.State, error: String?): Map<String, Any?> = mapOf(
        "state" to state.name.lowercase(),
        "error" to error,
        "connectedAt" to CoreManager.connectedAt,
        "detail" to CoreManager.detail,
    )

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> prepare(result, vpn = call.argument<Boolean>("vpn") ?: true)
            "supportsAppendHttpProxy" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
            "start" -> {
                val config = call.argument<String>("config")
                if (config.isNullOrEmpty()) {
                    result.error("ARG", "config is required", null)
                    return
                }
                ConfigStore.save(
                    this, config,
                    ConfigStore.Options(
                        remark = call.argument<String>("remark") ?: "BPB",
                        perAppMode = call.argument<String>("perAppMode") ?: "off",
                        apps = call.argument<List<String>>("apps")?.toSet() ?: emptySet(),
                        mtu = call.argument<Int>("mtu") ?: 1500,
                        appendHttpProxy = call.argument<Boolean>("appendHttpProxy") ?: false,
                        proxyOnly = call.argument<Boolean>("proxyOnly") ?: false,
                        exit = call.argument<String>("exit"),
                        exitDirect = call.argument<Boolean>("exitDirect") ?: false,
                        exitRegion = call.argument<String>("exitRegion") ?: "",
                        torBridge = call.argument<String>("torBridge"),
                        torCustomBridges = call.argument<List<String>>("torCustomBridges") ?: emptyList(),
                        psiphonConfig = call.argument<String>("psiphonConfig"),
                        browserDialer = call.argument<Boolean>("browserDialer") ?: false,
                    )
                )
                BpbVpnService.start(this)
                result.success(null)
            }
            "stop" -> {
                BpbVpnService.stop(this)
                result.success(null)
            }
            "state" -> result.success(stateEvent(CoreManager.state, CoreManager.lastError))
            "shareFile" -> shareFile(
                result,
                name = call.argument<String>("name") ?: "file.json",
                content = call.argument<String>("content") ?: "",
                title = call.argument<String>("title") ?: "Share",
            )
            "pickFile" -> pickFile(result)
            "saveFile" -> saveFile(
                result,
                name = call.argument<String>("name") ?: "file.json",
                content = call.argument<String>("content") ?: "",
            )
            "readLog" -> runInBackground(result) { CoreLog.tail(this, call.argument<String>("log") ?: CoreLog.XRAY) }
            "logSizes" -> runInBackground(result) { CoreLog.sizes(this) }
            "clearLog" -> runInBackground(result) {
                CoreLog.clear(this)
                null
            }
            "versions" -> runInBackground(result) { CoreManager.versions(this) }
            "saveGeoAssets" -> {
                val files = call.argument<Map<String, Map<String, Any>>>("files").orEmpty().mapValues { (_, f) ->
                    (f["data"] as ByteArray) to (f["sha256"] as String)
                }
                runInBackground(result) {
                    CoreManager.saveGeoAssets(this, files)
                    null
                }
            }
            // The installed version (pubspec.yaml's) and this phone's ABIs, preferred first.
            "appInfo" -> result.success(
                mapOf(
                    "version" to packageManager.getPackageInfo(packageName, 0).versionName,
                    "abis" to Build.SUPPORTED_ABIS.toList(),
                ),
            )
            "measureDelay" -> {
                val url = call.argument<String>("url") ?: DEFAULT_TEST_URL
                runInBackground(result) {
                    // Delay through the running tunnel.
                    if (!CoreManager.controller.isRunning) throw IllegalStateException("Not connected")
                    CoreManager.controller.measureDelay(url)
                }
            }
            "trafficStats" -> {
                // Sampled by the VPN service (Xray's counters reset on each read, so it's the only reader).
                val rate = TrafficMeter.rate
                val total = TrafficMeter.total
                result.success(
                    if (CoreManager.state != CoreManager.State.CONNECTED) null
                    else mapOf(
                        "proxyUp" to rate.proxyUp,
                        "proxyDown" to rate.proxyDown,
                        "directUp" to rate.directUp,
                        "directDown" to rate.directDown,
                        "proxyUpTotal" to total.proxyUp,
                        "proxyDownTotal" to total.proxyDown,
                    ),
                )
            }
            "installedApps" -> runInBackground(result) { installedApps() }
            "mitmCaExists" -> runInBackground(result) { MitmCa.exists(this) }
            "startSetupTor" -> runInBackground(result) {
                SetupTor.start(this, call.argument<List<String>>("bridges") ?: emptyList())
                SetupTor.HTTP_PORT
            }
            "setupTorStatus" -> result.success(
                mapOf("progress" to SetupTor.progress, "running" to SetupTor.running, "error" to SetupTor.error),
            )
            "stopSetupTor" -> runInBackground(result) {
                SetupTor.stop()
                null
            }
            "saveMitmCa" -> runInBackground(result) {
                MitmCa.save(this, call.argument<String>("cert")!!, call.argument<String>("key")!!)
                null
            }
            "installMitmCa" -> runInBackground(result) { MitmCa.install(this) }
            "openUrl" -> {
                val opened = try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url"))))
                    true
                } catch (e: ActivityNotFoundException) {
                    false
                }
                result.success(opened)
            }
            else -> result.notImplemented()
        }
    }

    private fun <T> runInBackground(result: MethodChannel.Result, block: () -> T) {
        background.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                mainHandler.post { result.error("CORE", e.message ?: e.toString(), null) }
            }
        }
    }

    // region permissions

    /** Asks for the notification permission and, in VPN mode, the VPN permission. */
    private fun prepare(result: MethodChannel.Result, vpn: Boolean) {
        requestNotificationPermission()
        if (!vpn) {
            result.success(true)
            return
        }
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }
        pendingPrepare?.success(false)
        pendingPrepare = result
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_VPN)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_SAVE_FILE) {
            val (pending, content) = pendingSave ?: return
            pendingSave = null
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null) {
                pending.success(null)
                return
            }
            runInBackground(pending) {
                contentResolver.openOutputStream(uri)?.use { it.write(content.toByteArray()) }
                    ?: throw IllegalStateException("Can't write the file")
                "the chosen folder"
            }
            return
        }
        if (requestCode == REQUEST_PICK_FILE) {
            val pending = pendingPick ?: return
            pendingPick = null
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null) {
                pending.success(null)
                return
            }
            runInBackground(pending) { readPickedFile(uri) }
            return
        }
        if (requestCode == REQUEST_VPN) {
            pendingPrepare?.success(resultCode == RESULT_OK)
            pendingPrepare = null
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // The VPN usually starts while this dialog is open, so its notification was blocked.
        if (requestCode == REQUEST_NOTIFICATIONS && grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            BpbVpnService.refreshNotification(this)
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    // endregion

    // region files

    /** Writes [content] to a cache file and opens the share sheet for it. */
    private fun shareFile(result: MethodChannel.Result, name: String, content: String, title: String) {
        try {
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            // Only the latest export is kept around.
            dir.listFiles()?.forEach { it.delete() }
            val file = File(dir, name.replace(Regex("[^A-Za-z0-9._-]"), "_"))
            file.writeText(content)
            val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
            val send = Intent(Intent.ACTION_SEND)
                .setType("application/json")
                .putExtra(Intent.EXTRA_STREAM, uri)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(Intent.createChooser(send, title))
            result.success(true)
        } catch (e: Exception) {
            result.error("SHARE", e.message ?: e.toString(), null)
        }
    }

    /**
     * Saves [content] as [name] in Downloads and returns where it went, or null if the user
     * cancelled. Android 10+ writes straight to Downloads (no permission needed); older
     * versions open the system Save-as screen.
     */
    private fun saveFile(result: MethodChannel.Result, name: String, content: String) {
        val fileName = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runInBackground(result) {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(MediaStore.MediaColumns.MIME_TYPE, "application/json")
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: throw IllegalStateException("Can't create the file in Downloads")
                try {
                    contentResolver.openOutputStream(uri)?.use { it.write(content.toByteArray()) }
                        ?: throw IllegalStateException("Can't write the file")
                    contentResolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
                } catch (e: Exception) {
                    contentResolver.delete(uri, null, null)
                    throw e
                }
                // Android renames duplicates ("name (1).json"); report the real name.
                val saved = contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)
                    ?.use { if (it.moveToFirst()) it.getString(0) else null } ?: fileName
                "Downloads/$saved"
            }
            return
        }
        pendingSave?.first?.success(null)
        pendingSave = result to content
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("application/json")
            .putExtra(Intent.EXTRA_TITLE, fileName)
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_SAVE_FILE)
    }

    /** Opens the system file picker; the result is the file's name and text, or null if cancelled. */
    private fun pickFile(result: MethodChannel.Result) {
        pendingPick?.success(null)
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            // Many file managers label .json as plain text or octet-stream.
            .setType("*/*")
            .putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/plain", "application/octet-stream"))
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_PICK_FILE)
    }

    private fun readPickedFile(uri: Uri): Map<String, String> {
        val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: ""
        val input = contentResolver.openInputStream(uri) ?: throw IllegalStateException("Can't open the file")
        input.use {
            val bytes = it.readBytes()
            if (bytes.size > MAX_PICKED_BYTES) throw IllegalStateException("The file is too large")
            return mapOf("name" to name, "content" to String(bytes, Charsets.UTF_8))
        }
    }

    // endregion

    private fun installedApps(): List<Map<String, Any?>> {
        val pm = packageManager
        val size = (40 * resources.displayMetrics.density).toInt()
        return pm.getInstalledApplications(PackageManager.GET_META_DATA)
            .filter { it.packageName != packageName }
            .map { app ->
                mapOf(
                    "package" to app.packageName,
                    "label" to app.loadLabel(pm).toString(),
                    "system" to ((app.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                    "icon" to iconBytes(app, size),
                )
            }
            .sortedBy { (it["label"] as String).lowercase() }
    }

    private fun iconBytes(app: ApplicationInfo, size: Int): ByteArray? = try {
        val drawable = app.loadIcon(packageManager)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            bitmap.recycle()
            out.toByteArray()
        }
    } catch (e: Exception) {
        null
    }
}
