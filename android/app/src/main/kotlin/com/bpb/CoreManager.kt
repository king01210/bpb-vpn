package com.bpb

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import go.Seq
import xray.Controller
import xray.Xray
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Process-wide owner of the Xray core instance and the VPN connection state.
 * The VPN service, the quick settings tile and the Flutter bridge all live in
 * the same process and talk to each other through this object.
 */
object CoreManager {
    private const val TAG = "BpbCore"

    enum class State { DISCONNECTED, CONNECTING, CONNECTED, DISCONNECTING }

    fun interface Listener {
        fun onStateChanged(state: State, error: String?)
    }

    @Volatile
    var state: State = State.DISCONNECTED
        private set

    @Volatile
    var lastError: String? = null
        private set

    @Volatile
    var connectedAt: Long = 0L
        private set

    /**
     * What the exit (Psiphon / Tor) is doing, for the home page: "Tor 45% · Loading relay
     * descriptors" while connecting, "Tor reconnecting…" when it drops; null otherwise.
     */
    @Volatile
    var detail: String? = null
        private set

    private val listeners = CopyOnWriteArraySet<Listener>()
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var envReady = false

    val controller: Controller by lazy { Xray.newController() }

    fun addListener(listener: Listener) = listeners.add(listener)

    fun removeListener(listener: Listener) = listeners.remove(listener)

    fun setState(newState: State, error: String? = null) {
        state = newState
        lastError = error
        detail = null
        if (newState == State.CONNECTED) connectedAt = System.currentTimeMillis()
        if (newState == State.DISCONNECTED) connectedAt = 0L
        mainHandler.post { listeners.forEach { it.onStateChanged(newState, error) } }
    }

    /** Xray's geo files, and Tor's GeoIP files (for ExitNodes by country). */
    /** Updates [detail] and tells the listeners (the app), keeping the state. */
    fun setDetail(text: String?) {
        if (detail == text) return
        detail = text
        val (s, e) = state to lastError
        mainHandler.post { listeners.forEach { it.onStateChanged(s, e) } }
    }

    private val GEO_FILES = listOf("geoip.dat", "geosite.dat", "tor_geoip", "tor_geoip6")

    /**
     * Points Xray at filesDir for geoip.dat / geosite.dat. Xray reads them from
     * disk, so they are copied out of the APK assets on first run and after
     * every app update.
     */
    @Synchronized
    fun initEnv(context: Context) {
        if (envReady) return
        copyGeoAssets(context)
        Seq.setContext(context.applicationContext)
        Xray.initEnv(context.filesDir.absolutePath)
        envReady = true
        Log.i(TAG, "Xray ${Xray.version()}")
    }

    private fun copyGeoAssets(context: Context) {
        val prefs = context.getSharedPreferences("bpb_native", Context.MODE_PRIVATE)
        @Suppress("DEPRECATION")
        val installedAt = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
        val upToDate = prefs.getLong("geoCopiedFor", 0L) == installedAt &&
            GEO_FILES.all { File(context.filesDir, it).length() > 0 }
        if (upToDate) return

        for (name in GEO_FILES) {
            val target = File(context.filesDir, name)
            val tmp = File(context.filesDir, "$name.tmp")
            context.assets.open(name).use { input -> tmp.outputStream().use { input.copyTo(it) } }
            if (!tmp.renameTo(target)) {
                target.delete()
                tmp.renameTo(target)
            }
        }
        prefs.edit().putLong("geoCopiedFor", installedAt).apply()
        Log.i(TAG, "Copied geo assets to ${context.filesDir}")
    }

    /** Xray's geo files, the ones Settings → Routing → Update geo assets replaces. */
    private val XRAY_GEO_FILES = setOf("geoip.dat", "geosite.dat")

    /**
     * Replaces Xray's geo files with [files] (name → content and its SHA-256, hex). None is
     * replaced unless every one matches its hash. Xray reads them when it starts: a running
     * connection keeps the old ones until it reconnects. The bundled ones come back with the
     * next app update (copyGeoAssets).
     */
    fun saveGeoAssets(context: Context, files: Map<String, Pair<ByteArray, String>>) {
        require(files.isNotEmpty() && files.keys.all { it in XRAY_GEO_FILES }) { "Unknown geo files" }
        val digest = MessageDigest.getInstance("SHA-256")
        for ((name, file) in files) {
            val hash = digest.digest(file.first).joinToString("") { "%02x".format(it) }
            require(hash == file.second.lowercase()) { "$name doesn't match its checksum" }
        }
        for ((name, file) in files) {
            val target = File(context.filesDir, name)
            val tmp = File(context.filesDir, "$name.tmp")
            tmp.writeBytes(file.first)
            if (!tmp.renameTo(target)) {
                target.delete()
                tmp.renameTo(target)
            }
        }
        Log.i(TAG, "Updated geo assets: ${files.keys.joinToString()}")
    }

    /**
     * The cores' versions as they report them: Xray's (e.g. 26.10.21), and the
     * Psiphon and Tor binaries' output for -version / --version; empty when one can't tell.
     */
    fun versions(context: Context): Map<String, String> {
        initEnv(context)
        val libDir = context.applicationInfo.nativeLibraryDir
        return mapOf(
            "xray" to Xray.version(),
            "psiphon" to output(File(libDir, "libpsiphon.so"), "-version"),
            "tor" to output(File(libDir, "libtor.so"), "--version"),
        )
    }

    private fun output(binary: File, vararg args: String): String = try {
        val process = ProcessBuilder(binary.absolutePath, *args).redirectErrorStream(true).start()
        process.outputStream.close()
        val text = process.inputStream.bufferedReader().use { it.readText() }
        process.waitFor()
        text.trim()
    } catch (e: Exception) {
        Log.w(TAG, "${binary.name} ${args.joinToString(" ")}: $e")
        ""
    }
}

/** Persists the last config so the service can restart without the Flutter UI (tile, always-on VPN). */
object ConfigStore {
    private const val PREFS = "bpb_native"
    private const val CONFIG_FILE = "config.json"
    private const val LEGACY_CONFIG_FILE = "active_config.json"

    data class Options(
        val remark: String,
        val perAppMode: String, // off | include | exclude
        val apps: Set<String>,
        val mtu: Int,
        val appendHttpProxy: Boolean = false,
        /** Proxy mode: only the local SOCKS/HTTP proxy, no VPN (TUN) device. */
        val proxyOnly: Boolean = false,
        /** "psiphon" or "tor" to start that exit process; null for none. */
        val exit: String? = null,
        /** Psiphon / Tor type: the exit connects by itself rather than through Xray's inbound. */
        val exitDirect: Boolean = false,
        /** The exit's region (ISO code), or "" for the fastest. */
        val exitRegion: String = "",
        /** Tor type: direct, a built-in bridge transport (snowflake / obfs4 / meek) or custom. */
        val torBridge: String? = null,
        /** Tor type's custom bridge lines. */
        val torCustomBridges: List<String> = emptyList(),
        /** Psiphon config fields (JSON) for the mode, added to psiphon_config.json; or null. */
        val psiphonConfig: String? = null,
        /** Worker's Browser Dialer: Xray's WebSockets are opened by a WebView (see BrowserDialer). */
        val browserDialer: Boolean = false,
    )

    fun save(context: Context, config: String, options: Options) {
        File(context.filesDir, CONFIG_FILE).writeText(config)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("remark", options.remark)
            .putString("perAppMode", options.perAppMode)
            .putStringSet("apps", options.apps)
            .putInt("mtu", options.mtu)
            .putBoolean("appendHttpProxy", options.appendHttpProxy)
            .putBoolean("proxyOnly", options.proxyOnly)
            .putString("exit", options.exit)
            .putBoolean("exitDirect", options.exitDirect)
            .putString("exitRegion", options.exitRegion)
            .putString("torBridge", options.torBridge)
            .putString("torCustomBridges", options.torCustomBridges.joinToString("\n"))
            .putString("psiphonConfig", options.psiphonConfig)
            .putBoolean("browserDialer", options.browserDialer)
            .apply()
    }

    fun hasConfig(context: Context): Boolean =
        File(context.filesDir, CONFIG_FILE).exists() ||
            File(context.filesDir, LEGACY_CONFIG_FILE).exists()

    fun loadConfig(context: Context): String? {
        val file = File(context.filesDir, CONFIG_FILE)
        if (file.exists()) return file.readText()
        val legacy = File(context.filesDir, LEGACY_CONFIG_FILE)
        if (!legacy.exists()) return null
        return legacy.readText().also { file.writeText(it) }
    }

    fun loadOptions(context: Context): Options {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return Options(
            remark = prefs.getString("remark", null) ?: "BPB",
            perAppMode = prefs.getString("perAppMode", null) ?: "off",
            apps = prefs.getStringSet("apps", null) ?: emptySet(),
            mtu = prefs.getInt("mtu", 1500),
            appendHttpProxy = prefs.getBoolean("appendHttpProxy", false),
            proxyOnly = prefs.getBoolean("proxyOnly", false),
            exit = prefs.getString("exit", null),
            exitDirect = prefs.getBoolean("exitDirect", false),
            exitRegion = prefs.getString("exitRegion", null) ?: "",
            torBridge = prefs.getString("torBridge", null),
            torCustomBridges = prefs.getString("torCustomBridges", null)
                ?.split('\n')?.filter { it.isNotBlank() } ?: emptyList(),
            psiphonConfig = prefs.getString("psiphonConfig", null),
            browserDialer = prefs.getBoolean("browserDialer", false),
        )
    }
}
