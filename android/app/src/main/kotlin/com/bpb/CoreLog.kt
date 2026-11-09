package com.bpb

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * The logs shown on the app's log page, one file each, cleared on every connect:
 * - [XRAY]: Xray's error and access logs, which Xray writes itself (see [attach]);
 * - [TOR]: Tor's own log (torrc `Log notice file`);
 * - [PSIPHON]: Psiphon's output, copied as is.
 * Only the app's own few status lines are added to them (see [append]).
 */
object CoreLog {
    private const val TAG = "BpbCoreLog"
    const val XRAY = "xray"
    const val TOR = "tor"
    const val PSIPHON = "psiphon"
    val ALL = listOf(XRAY, TOR, PSIPHON)

    fun file(context: Context, log: String = XRAY) = File(context.filesDir, "$log.log")

    /**
     * [config] with its logs pointed at the Xray log: the error log ([Warning] etc., set by
     * loglevel) and the access log (one line per connection, not affected by loglevel).
     * Unchanged if it can't be parsed.
     */
    fun attach(context: Context, config: String): String = try {
        val json = JSONObject(config)
        val log = json.optJSONObject("log") ?: JSONObject().also { json.put("log", it) }
        log.put("error", file(context).absolutePath)
        log.put("access", file(context).absolutePath)
        json.toString()
    } catch (e: Exception) {
        Log.w(TAG, "Config is not a JSON object; logging to logcat only", e)
        config
    }

    /** Empties every log. */
    fun clear(context: Context) {
        for (log in ALL) {
            try {
                file(context, log).writeText("")
            } catch (e: Exception) {
                Log.w(TAG, "Clearing the $log log failed", e)
            }
        }
    }

    /** Adds one of the app's own status lines to [log], in Xray's line format. */
    @Synchronized
    fun append(context: Context, log: String, message: String) {
        // UTC, like Xray's own lines (Go on Android has no local time zone).
        val time = SimpleDateFormat("yyyy/MM/dd HH:mm:ss.SSSSSS", Locale.US)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }
            .format(Date())
        try {
            file(context, log).appendText("$time [App] $message\n")
        } catch (e: Exception) {
            Log.w(TAG, "Appending to the $log log failed", e)
        }
    }

    /** Sizes of the logs in bytes, by name (0 for empty or missing). */
    fun sizes(context: Context): Map<String, Long> = ALL.associateWith { file(context, it).length() }

    /** The last [maxBytes] of [log], starting at a whole line. */
    fun tail(context: Context, log: String = XRAY, maxBytes: Int = 64 * 1024): String {
        val f = file(context, log)
        if (!f.exists()) return ""
        RandomAccessFile(f, "r").use { raf ->
            val length = raf.length()
            val start = (length - maxBytes).coerceAtLeast(0)
            raf.seek(start)
            val bytes = ByteArray((length - start).toInt())
            raf.readFully(bytes)
            val text = String(bytes, Charsets.UTF_8)
            return if (start > 0) text.substringAfter('\n') else text
        }
    }
}
