package com.bpb

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileWriter
import java.io.IOException
import java.io.InputStream
import java.io.Writer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The exit process, Psiphon ([PsiphonExit]) or Tor ([TorExit]); one at a time. It serves a
 * SOCKS5 proxy on [SOCKS_PORT] for Xray's exit / proxy outbound and a DNS server on
 * [DNS_PORT] for Xray's DNS, and as an exit reaches its own servers through Xray's
 * psiphon-in / tor-in inbound on [UPSTREAM_PORT]. The ports match XrayConfigBuilder.
 */
object ExitProcess {
    private const val TAG = "BpbExit"
    const val UPSTREAM_PORT = 10828
    const val SOCKS_PORT = 10829
    const val DNS_PORT = 10830

    /** What an output line means to the app; most mean nothing ([None]). */
    sealed interface Line {
        data object Ready : Line
        data class Error(val message: String) : Line

        /** One of the app's own status lines for the exit's log ("reconnecting"). */
        data class Status(val message: String) : Line
        data object None : Line
    }

    @Volatile
    private var process: Process? = null

    /** Released when the running exit is ready (see [ready]). */
    @Volatile
    private var readyLatch: CountDownLatch? = null
    private var log = CoreLog.XRAY
    private lateinit var appContext: Context

    /** Whether an exit process is running. */
    val running: Boolean
        get() = process != null

    /** Called when the process exits on its own (not through [stop]), with its last error. */
    @Volatile
    var onExit: ((String) -> Unit)? = null

    /**
     * Runs [command] and blocks until [parse] reports ready (or [ready] is called), however long
     * that takes: the exit keeps trying, and [stop] (Disconnect) is the way to give up. Throws
     * with the last error if the process exits first.
     *
     * With [copyOutput] the process's output is copied as is to its [log] (Psiphon); otherwise
     * it writes its own log and the output only goes to logcat (Tor). [onStarted] runs once the
     * process is up, e.g. to connect to Tor's control port.
     */
    fun start(
        context: Context,
        log: String,
        command: List<String>,
        workDir: File,
        parse: (String) -> Line,
        copyOutput: Boolean,
        onStarted: (() -> Unit)? = null,
    ) {
        stop()
        val p = ProcessBuilder(command).directory(workDir).redirectErrorStream(false).start()
        val latch = CountDownLatch(1)
        this.log = log
        appContext = context.applicationContext
        readyLatch = latch
        process = p
        var error: String? = null
        val out: Writer? = if (copyOutput) FileWriter(CoreLog.file(context, log), true) else null

        fun handle(line: String) {
            if (out != null) {
                synchronized(out) {
                    out.write(line)
                    out.write("\n")
                    out.flush()
                }
            } else {
                Log.i(TAG, "$log: $line")
            }
            when (val l = parse(line)) {
                Line.Ready -> ready()
                is Line.Error -> {
                    error = l.message
                    CoreLog.append(context, log, l.message)
                }
                is Line.Status -> CoreLog.append(context, log, l.message)
                Line.None -> {}
            }
        }

        val stderr = Thread({ readLines(p.errorStream, ::handle) }, "exit-stderr").apply { start() }
        Thread({
            readLines(p.inputStream, ::handle)
            // Stdout closed: the process exited.
            stderr.join(1000)
            out?.let { synchronized(it) { runCatching { it.close() } } }
            latch.countDown()
            if (process === p) {
                process = null
                onExit?.invoke(error ?: "${displayName()} stopped")
            }
        }, "exit-stdout").start()
        onStarted?.let { Thread(it, "exit-control").start() }

        latch.await()
        if (process !== p) {
            stop()
            throw IllegalStateException(error ?: "${displayName()} could not connect")
        }
    }

    /** Reports the running exit ready (a [Line.Ready] line, or Tor's control port). */
    fun ready() {
        val latch = readyLatch ?: return
        if (latch.count == 0L) return
        CoreLog.append(appContext, log, "connected")
        latch.countDown()
    }

    /** "Psiphon" / "Tor", for messages. */
    private fun displayName() = log.replaceFirstChar { it.uppercase() }

    /** Reads [stream] line by line until it ends, or is closed by [stop] (which throws). */
    private fun readLines(stream: InputStream, onLine: (String) -> Unit) {
        try {
            stream.bufferedReader().forEachLine(onLine)
        } catch (e: IOException) {
            // Closed by stop() while reading.
        }
    }

    /** Stops the process (closing stdin first: Psiphon exits when it closes). */
    fun stop() {
        val p = process ?: return
        process = null
        try {
            p.outputStream.close()
        } catch (e: Exception) {
            // Already gone.
        }
        p.destroy()
        if (!p.waitFor(2, TimeUnit.SECONDS)) p.destroyForcibly()
    }
}
