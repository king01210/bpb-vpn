package com.bpb

import java.util.Locale

/**
 * Per-second traffic, split into proxied and direct, sampled from Xray's outbound stats.
 * Xray resets its counters on every query, so this is the only reader: the VPN service
 * samples it each second and the app reads [rate] / [total] from here.
 */
object TrafficMeter {
    data class Sample(
        val proxyUp: Long = 0,
        val proxyDown: Long = 0,
        val directUp: Long = 0,
        val directDown: Long = 0,
    ) {
        operator fun plus(o: Sample) =
            Sample(proxyUp + o.proxyUp, proxyDown + o.proxyDown, directUp + o.directUp, directDown + o.directDown)
    }

    /**
     * Outbounds that are neither proxy nor direct traffic, and exits whose traffic is already
     * counted on the outbound carrying it: chain-N dials through proxy-N, Psiphon's "exit"
     * reaches its servers through the proxies too, and Domain Fronting's redirect-out-*
     * hands connections to its decrypting inbounds, whose tls-repack-* outbounds carry them.
     */
    private val IGNORED = setOf("block", "dns-out", "exit")

    /** Bytes in the last second. */
    @Volatile
    var rate = Sample()
        private set

    /** Bytes since the connection started. */
    @Volatile
    var total = Sample()
        private set

    fun reset() {
        rate = Sample()
        total = Sample()
    }

    /** Reads (and thereby resets) Xray's counters; call once per second while connected. */
    fun sample() {
        val raw = try {
            CoreManager.controller.outboundTraffic()
        } catch (e: Exception) {
            return
        }
        var proxyUp = 0L
        var proxyDown = 0L
        var directUp = 0L
        var directDown = 0L
        // "tag,uplink|downlink,bytes;..."
        for (entry in raw.split(';')) {
            val parts = entry.split(',')
            if (parts.size != 3 || parts[0] in IGNORED || parts[0].startsWith("chain-") || parts[0].startsWith("redirect-out-")) continue
            val bytes = parts[2].toLongOrNull() ?: continue
            val up = when (parts[1]) {
                "uplink" -> true
                "downlink" -> false
                else -> continue
            }
            if (parts[0] == "direct") {
                if (up) directUp += bytes else directDown += bytes
            } else {
                if (up) proxyUp += bytes else proxyDown += bytes
            }
        }
        val sample = Sample(proxyUp, proxyDown, directUp, directDown)
        rate = sample
        total += sample
    }

    /** 1536 → "1.5 KB", like the app's formatBytes. */
    fun format(bytes: Long): String = when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> String.format(Locale.US, "%.1f KB", bytes / 1024.0)
        bytes < 1024L * 1024 * 1024 -> String.format(Locale.US, "%.1f MB", bytes / 1024.0 / 1024)
        else -> String.format(Locale.US, "%.2f GB", bytes / 1024.0 / 1024 / 1024)
    }
}
