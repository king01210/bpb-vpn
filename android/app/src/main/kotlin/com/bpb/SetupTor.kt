package com.bpb

import android.content.Context
import android.os.Process
import android.util.Log
import java.io.File
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.TimeUnit

/**
 * Tor for the setup wizard's "Retry with Tor": started from the app (no VPN, no Xray) with the
 * bridges the build embedded, it serves an HTTP CONNECT proxy ([HTTP_PORT]) the app's API calls
 * go through. Its own data directory and ports, so it never meets [TorExit].
 */
object SetupTor {
    private const val TAG = "BpbSetupTor"
    const val HTTP_PORT = 10840
    private const val CONTROL_PORT = 10841
    private const val COOKIE = "control_auth_cookie"

    @Volatile
    private var process: java.lang.Process? = null

    /** Bootstrap progress, 0-100. */
    @Volatile
    var progress = 0
        private set

    /** Why Tor stopped by itself, if it did. */
    @Volatile
    var error: String? = null
        private set

    val running: Boolean
        get() = process != null

    /** Starts Tor with [bridges] (all in one torrc: Tor uses whichever connects). */
    fun start(context: Context, bridges: List<String>) {
        stop()
        require(bridges.isNotEmpty()) { "No bridges" }
        val libDir = context.applicationInfo.nativeLibraryDir
        val dir = File(context.filesDir, "tor-setup").apply { mkdirs() }
        val dataDir = File(dir, "data")
        val torrc = File(dir, "torrc")
        val lyrebird = File(libDir, "liblyrebird.so").absolutePath
        torrc.writeText(
            (listOf(
                "DataDirectory ${dataDir.absolutePath}",
                "SocksPort 0",
                // Plain HTTP CONNECT, which Dart's HttpClient speaks (it has no SOCKS).
                "HTTPTunnelPort 127.0.0.1:$HTTP_PORT",
                "ControlPort 127.0.0.1:$CONTROL_PORT",
                "CookieAuthentication 1",
                "Log notice file ${File(dir, "tor.log").absolutePath}",
                "ClientOnly 1",
                "AvoidDiskWrites 1",
                // Tor exits by itself if the app dies.
                "__OwningControllerProcess ${Process.myPid()}",
                "UseBridges 1",
                "ClientTransportPlugin meek_lite,obfs4,webtunnel exec $lyrebird",
                "ClientTransportPlugin snowflake exec $lyrebird",
            ) + bridges.map { "Bridge $it" }).joinToString("\n", postfix = "\n"),
        )
        // A cookie from the last run would be stale; Tor writes a new one when it starts.
        val cookie = File(dataDir, COOKIE).apply { delete() }
        progress = 0
        error = null

        val p = ProcessBuilder(File(libDir, "libtor.so").absolutePath, "-f", torrc.absolutePath)
            .directory(dir)
            .redirectErrorStream(true)
            .start()
        process = p
        // Its output: only what Tor prints before its log opens, e.g. a bad torrc ("[err]").
        Thread({
            try {
                p.inputStream.bufferedReader().forEachLine { line ->
                    Log.i(TAG, line)
                    if ("[err]" in line) error = line.substringAfter("] ", line)
                }
            } catch (e: IOException) {
                // Closed by stop().
            }
            if (process === p) {
                process = null
                if (error == null) error = "Tor stopped"
            }
        }, "setup-tor-out").start()
        Thread({ follow(p, cookie) }, "setup-tor-control").start()
    }

    /** Reads bootstrap progress from Tor's control port until it reaches 100 or Tor stops. */
    private fun follow(p: java.lang.Process, cookie: File) {
        val socket = open(p, cookie) ?: return
        try {
            socket.use { s ->
                val reader = s.getInputStream().bufferedReader()
                val writer = s.getOutputStream().bufferedWriter()
                fun send(command: String) {
                    writer.write("$command\r\n")
                    writer.flush()
                }
                send("AUTHENTICATE ${cookie.readBytes().joinToString("") { "%02x".format(it) }}")
                if (reader.readLine()?.startsWith("250") != true) return
                send("SETEVENTS STATUS_CLIENT")
                if (reader.readLine()?.startsWith("250") != true) return
                // The phase reached before we subscribed; events follow from here.
                send("GETINFO status/bootstrap-phase")
                while (process === p) {
                    val line = reader.readLine() ?: return
                    if (" BOOTSTRAP " in line) {
                        val value = Regex("""PROGRESS=(\d+)""").find(line)?.groupValues?.get(1)?.toInt() ?: continue
                        progress = maxOf(progress, value)
                        if (progress >= 100) return
                    }
                }
            }
        } catch (e: IOException) {
            // Tor exited or was stopped.
        }
    }

    /** Connects once Tor has written its cookie and opened the port; null if Tor stops first. */
    private fun open(p: java.lang.Process, cookie: File): Socket? {
        while (process === p) {
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

    fun stop() {
        val p = process ?: return
        process = null
        p.destroy()
        if (!p.waitFor(2, TimeUnit.SECONDS)) p.destroyForcibly()
    }
}
