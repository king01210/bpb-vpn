package com.bpb

import android.content.Context
import android.os.Process
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Tor (Tor Project's Android expert bundle, see scripts/fetch_tor.sh): libtor.so is the tor
 * executable and liblyrebird.so its pluggable transports. Serves SOCKS5, TCP only.
 *
 * As an exit Tor reaches relays through Xray's tor-in inbound, i.e. through the worker or WARP,
 * without bridges. [direct] (the Tor type) connects by itself, outside the VPN like the rest of
 * the app, with the chosen bridges: none ("direct"), Tor's built-in bridges of a transport, or
 * the user's own ("custom").
 */
object TorExit {
    private const val GEOIP = "tor_geoip"
    private const val GEOIP6 = "tor_geoip6"
    private const val PT_CONFIG = "tor_pt_config.json"

    /** Tor's control port: bootstrap progress and circuit status for the app. */
    private const val CONTROL_PORT = 10831
    private const val COOKIE = "control_auth_cookie"

    fun start(context: Context, region: String, direct: Boolean, bridge: String?, customBridges: List<String>) {
        val libDir = context.applicationInfo.nativeLibraryDir
        val dir = File(context.filesDir, "tor").apply { mkdirs() }
        val bridges = when {
            !direct || bridge == null || bridge == "direct" -> emptyList()
            bridge == "custom" -> customBridges.ifEmpty { throw IllegalStateException("No custom bridges") }
            else -> builtInBridges(context, bridge)
        }
        val dataDir = File(dir, "data")
        val torrc = File(dir, "torrc")
        torrc.writeText(torrc(context, dataDir, libDir, region, viaXray = !direct, bridges))
        // A cookie from the last run would be stale; Tor writes a new one when it starts.
        val cookie = File(dataDir, COOKIE).apply { delete() }

        val via = if (bridges.isNotEmpty()) " via $bridge bridges" else ""
        CoreLog.append(context, CoreLog.TOR, "starting, region ${region.ifEmpty { "fastest" }}$via")
        CoreManager.setDetail("Tor · Bootstrapped 0%")
        ExitProcess.start(
            context,
            CoreLog.TOR,
            listOf(File(libDir, "libtor.so").absolutePath, "-f", torrc.absolutePath),
            dir,
            ::parse,
            copyOutput = false, // Tor writes its own log (torrc)
            onStarted = { control(context, cookie) },
        )
    }

    /**
     * Follows Tor through its control port: bootstrap progress (the home page's detail line,
     * and ready at 100%), and circuits lost / established once connected (reconnecting).
     */
    private fun control(context: Context, cookie: File) {
        val socket = openControl(cookie) ?: return
        try {
            socket.use { s ->
                val reader = s.getInputStream().bufferedReader()
                val writer = s.getOutputStream().bufferedWriter()
                fun send(command: String) {
                    writer.write("$command\r\n")
                    writer.flush()
                }

                send("AUTHENTICATE ${cookie.readBytes().joinToString("") { "%02x".format(it) }}")
                val auth = reader.readLine()
                if (auth?.startsWith("250") != true) {
                    CoreLog.append(context, CoreLog.TOR, "control port login failed: $auth")
                    return
                }
                send("SETEVENTS STATUS_CLIENT")
                val events = reader.readLine()
                if (events?.startsWith("250") != true) {
                    CoreLog.append(context, CoreLog.TOR, "control port events failed: $events")
                    return
                }
                // The phase reached before we subscribed; events follow from here.
                send("GETINFO status/bootstrap-phase")

                var connected = false
                var lost = false
                while (true) {
                    val line = reader.readLine() ?: return
                    when {
                        // "650 STATUS_CLIENT NOTICE BOOTSTRAP PROGRESS=45 TAG=… SUMMARY="…"", or the
                        // same after "250-status/bootstrap-phase=".
                        " BOOTSTRAP " in line -> {
                            val progress = Regex("""PROGRESS=(\d+)""").find(line)?.groupValues?.get(1)?.toInt() ?: continue
                            if (progress >= 100) {
                                connected = true
                                ExitProcess.ready()
                            } else if (!connected) {
                                CoreManager.setDetail("Tor · Bootstrapped $progress%")
                            }
                        }
                        "CIRCUIT_NOT_ESTABLISHED" in line -> if (connected && !lost) {
                            lost = true
                            val reason = Regex("""REASON=(\S+)""").find(line)?.groupValues?.get(1)
                            CoreLog.append(context, CoreLog.TOR, "circuits lost${reason?.let { " ($it)" } ?: ""}")
                            CoreManager.setDetail("Tor · Reconnecting…")
                        }
                        "CIRCUIT_ESTABLISHED" in line -> if (lost) {
                            lost = false
                            CoreLog.append(context, CoreLog.TOR, "circuits established")
                            CoreManager.setDetail(null)
                        }
                    }
                }
            }
        } catch (e: IOException) {
            // Tor exited or was stopped.
        }
    }

    /** Connects once Tor has written its cookie and opened the port; null if Tor stops first. */
    private fun openControl(cookie: File): Socket? {
        while (ExitProcess.running) {
            if (cookie.length() == 32L) {
                try {
                    return Socket().apply { connect(InetSocketAddress("127.0.0.1", CONTROL_PORT), 1000) }
                } catch (e: IOException) {
                    // Not listening yet.
                }
            }
            Thread.sleep(200)
        }
        return null
    }

    /** [viaXray]: reach relays through Xray's tor-in inbound (the Tor exit). */
    private fun torrc(
        context: Context,
        dataDir: File,
        libDir: String,
        region: String,
        viaXray: Boolean,
        bridges: List<String>,
    ): String {
        val lines = mutableListOf(
            "DataDirectory ${dataDir.absolutePath}",
            "SocksPort 127.0.0.1:${ExitProcess.SOCKS_PORT}",
            // Names resolved at the exit, over an existing circuit.
            "DNSPort 127.0.0.1:${ExitProcess.DNS_PORT}",
            "GeoIPFile ${File(context.filesDir, GEOIP).absolutePath}",
            "GeoIPv6File ${File(context.filesDir, GEOIP6).absolutePath}",
            // For control(): progress and circuit status, with the cookie in DataDirectory.
            "ControlPort 127.0.0.1:$CONTROL_PORT",
            "CookieAuthentication 1",
            // Tor's own log, shown on the app's log page.
            "Log notice file ${CoreLog.file(context, CoreLog.TOR).absolutePath}",
            "ClientOnly 1",
            "AvoidDiskWrites 1",
            // Tor exits by itself if the app dies.
            "__OwningControllerProcess ${Process.myPid()}",
        )
        if (region.isNotEmpty()) lines += listOf("ExitNodes {${region.lowercase()}}", "StrictNodes 1")
        if (viaXray) lines += "Socks5Proxy 127.0.0.1:${ExitProcess.UPSTREAM_PORT}"
        if (bridges.isNotEmpty()) {
            val lyrebird = File(libDir, "liblyrebird.so").absolutePath
            lines += listOf(
                "UseBridges 1",
                "ClientTransportPlugin meek_lite,obfs4,webtunnel exec $lyrebird",
                "ClientTransportPlugin snowflake exec $lyrebird",
            )
            lines += bridges.map { "Bridge $it" }
        }
        return lines.joinToString("\n", postfix = "\n")
    }

    /** Tor's built-in bridges for [transport] ("snowflake", "obfs4" or "meek"), from pt_config.json. */
    private fun builtInBridges(context: Context, transport: String): List<String> {
        val json = context.assets.open(PT_CONFIG).bufferedReader().use { JSONObject(it.readText()) }
        val list = json.getJSONObject("bridges").optJSONArray(transport)
            ?: throw IllegalStateException("No built-in $transport bridges")
        return List(list.length()) { list.getString(it) }
    }

    /**
     * Tor's stdout: only what it prints before opening its log file, e.g. a bad torrc
     * ("… [err] …"). Progress and ready come from the control port.
     */
    private fun parse(line: String): ExitProcess.Line =
        if ("[err]" in line) ExitProcess.Line.Error(line.substringAfter("] ", line)) else ExitProcess.Line.None
}
