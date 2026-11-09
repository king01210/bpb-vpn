package com.bpb

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * Psiphon (psiphon/ in the repo, shipped as libpsiphon.so): serves SOCKS5 with TCP and UDP.
 * Its output, copied as is to the Psiphon log, is Psiphon's own notices as JSON lines
 * ({"noticeType":…,"data":…}) plus the binary's {"event":"ready"} / {"event":"error"} on stdout
 * (see psiphon/main.go), and the binary's own log on stderr.
 * As an exit it reaches its servers through Xray's psiphon-in inbound; [direct] (the Psiphon
 * type) connects by itself, outside the VPN like the rest of the app.
 *
 * The binary takes everything from one standard Psiphon config file: the app's
 * psiphon_config.json asset (Psiphon's public network IDs and server list, the server entry
 * signature key from Psiphon's Android app, which Conduit (in-proxy) dials need, timeouts disabled
 * as in Psiphon's Android app with NetworkLatencyMultiplierLambda 0.1, no establish deadline,
 * Psiphon's own local proxies off), this connection's fields ([start]), and the app's extra
 * fields for the mode.
 */
object PsiphonExit {
    private const val ASSET = "psiphon_config.json"
    private const val CONFIG = "config.json"

    /**
     * Connection attempts that failed since connecting started, for the home page's detail
     * line. Attempts run many at once (Psiphon's tactics can raise its worker pool to 50) and
     * take long with timeouts disabled, so finished attempts say more than started ones.
     */
    @Volatile
    private var failed = 0

    @Volatile
    private var connected = false

    /** Tunnels dropped to 0 after connecting: Psiphon is reconnecting. */
    @Volatile
    private var lost = false

    /** [extra]: Psiphon config fields (JSON) for the mode, added last, or null. */
    fun start(context: Context, region: String, direct: Boolean, extra: String?) {
        val binary = File(context.applicationInfo.nativeLibraryDir, "libpsiphon.so")
        val dataDir = File(context.filesDir, "psiphon").apply { mkdirs() }
        val config = JSONObject(context.assets.open(ASSET).bufferedReader().use { it.readText() }).apply {
            put("DataRootDirectory", dataDir.absolutePath)
            put("EgressRegion", region)
            if (!direct) put("UpstreamProxyURL", "socks5://127.0.0.1:${ExitProcess.UPSTREAM_PORT}")
            // The binary's own servers: SOCKS5 (TCP and UDP) for Xray's exit outbound, and DNS.
            put("BpbSocksListen", "127.0.0.1:${ExitProcess.SOCKS_PORT}")
            put("BpbDnsListen", "127.0.0.1:${ExitProcess.DNS_PORT}")
            extra?.let { JSONObject(it) }?.let { fields -> fields.keys().forEach { put(it, fields.get(it)) } }
        }
        val configFile = File(dataDir, CONFIG).apply { writeText(config.toString()) }
        val command = listOf(binary.absolutePath, "-config", configFile.absolutePath)
        failed = 0
        connected = false
        lost = false
        CoreLog.append(context, CoreLog.PSIPHON, "starting, region ${region.ifEmpty { "fastest" }}${extra?.let { ", $it" } ?: ""}")
        CoreManager.setDetail("Psiphon · Finding a server…")
        ExitProcess.start(context, CoreLog.PSIPHON, command, dataDir, ::parse, copyOutput = true)
    }

    /** Only a text check per line; JSON is parsed just for the few lines the app acts on. */
    private fun parse(line: String): ExitProcess.Line = when {
        line.startsWith("{\"event\"") -> {
            val json = JSONObject(line)
            when (json.optString("event")) {
                "ready" -> {
                    connected = true
                    ExitProcess.Line.Ready
                }
                "error" -> ExitProcess.Line.Error(json.optString("message"))
                else -> ExitProcess.Line.None
            }
        }
        // Psiphon's Info notice for each failed attempt: "failed to connect to <server>: <error>".
        "\"message\":\"failed to connect to " in line -> {
            failed++
            if (!connected) CoreManager.setDetail(if (failed == 1) "Psiphon · 1 server failed" else "Psiphon · $failed servers failed")
            ExitProcess.Line.None
        }
        "\"noticeType\":\"Tunnels\"" in line -> {
            val count = JSONObject(line).optJSONObject("data")?.optInt("count") ?: 0
            when {
                count == 0 && connected && !lost -> {
                    lost = true
                    CoreManager.setDetail("Psiphon · Reconnecting…")
                    ExitProcess.Line.Status("reconnecting")
                }
                count > 0 && lost -> {
                    lost = false
                    CoreManager.setDetail(null)
                    ExitProcess.Line.Status("reconnected")
                }
                else -> ExitProcess.Line.None
            }
        }
        else -> ExitProcess.Line.None
    }
}
