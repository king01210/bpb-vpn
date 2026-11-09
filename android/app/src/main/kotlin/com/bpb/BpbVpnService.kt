package com.bpb

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

class BpbVpnService : VpnService() {

    companion object {
        private const val TAG = "BpbVpnService"
        private const val ACTION_START = "com.bpb.START"
        private const val ACTION_STOP = "com.bpb.STOP"
        private const val ACTION_REFRESH_NOTIFICATION = "com.bpb.REFRESH_NOTIFICATION"
        private const val CHANNEL_ID = "bpb"
        private const val NOTIFICATION_ID = 1

        private const val TUN_IPV4 = "10.10.14.1"
        private const val TUN_IPV6 = "fd66:b9b:10:14::1"
        private const val TUN_DNS = "1.1.1.1"
        private const val LOCAL_HTTP_PROXY_PORT = 10808

        fun start(context: Context) {
            val intent = Intent(context, BpbVpnService::class.java).setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        // Re-posts the status notification, e.g. once notification permission is granted
        // (a notification posted before the grant was dropped and isn't shown later).
        fun refreshNotification(context: Context) {
            if (CoreManager.state == CoreManager.State.DISCONNECTED) return
            context.startService(Intent(context, BpbVpnService::class.java).setAction(ACTION_REFRESH_NOTIFICATION))
        }

        fun stop(context: Context) {
            if (CoreManager.state == CoreManager.State.DISCONNECTED) return
            context.startService(Intent(context, BpbVpnService::class.java).setAction(ACTION_STOP))
        }
    }

    private var tun: ParcelFileDescriptor? = null
    private val worker = Executors.newSingleThreadExecutor()

    /** Samples traffic and refreshes the notification once a second while connected. */
    private val ticker = Executors.newSingleThreadScheduledExecutor()
    private var tick: ScheduledFuture<*>? = null
    private var remark = ""

    /** Set by Stop, so a start it interrupts (e.g. waiting for Psiphon or Tor) isn't reported as a failure. */
    @Volatile
    private var stopRequested = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopRequested = true
            // Don't wait behind a start that is waiting for the exit (Psiphon / Tor).
            ExitProcess.stop()
            worker.execute { stopVpn() }
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_REFRESH_NOTIFICATION) {
            val connected = CoreManager.state == CoreManager.State.CONNECTED
            notify(buildNotification(ConfigStore.loadOptions(this).remark, connected))
            return START_STICKY
        }
        // ACTION_START from the app/tile, or android.net.VpnService / null from always-on VPN.
        val options = ConfigStore.loadOptions(this)
        startForegroundCompat(buildNotification(options.remark, connected = false))
        stopRequested = false
        worker.execute { startVpn() }
        return START_STICKY
    }

    override fun onRevoke() {
        worker.execute { stopVpn() }
    }

    override fun onDestroy() {
        if (CoreManager.state != CoreManager.State.DISCONNECTED) {
            shutdownCore()
            CoreManager.setState(CoreManager.State.DISCONNECTED)
        }
        worker.shutdown()
        ticker.shutdownNow()
        super.onDestroy()
    }

    private fun startVpn() {
        val config = ConfigStore.loadConfig(this)?.let { CoreLog.attach(this, it) }
        if (config == null) {
            fail("No configuration found. Open the app and connect once.")
            return
        }
        val options = ConfigStore.loadOptions(this)
        CoreManager.setState(CoreManager.State.CONNECTING)

        try {
            CoreManager.initEnv(this)
            // Restarting with a new config: tear down the previous session first.
            shutdownCore()
            CoreLog.clear(this)
            // Before the exit, which may connect through it.
            if (options.browserDialer) BrowserDialer.start(this)

            if (options.proxyOnly) {
                // Proxy mode: no TUN device; fd 0 tells the library not to use one.
                CoreManager.controller.start(config, 0)
                startExit(options)
                onCoreStarted(options)
                return
            }

            val builder = Builder()
                .setSession(options.remark)
                .setMtu(options.mtu)
                .addAddress(TUN_IPV4, 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer(TUN_DNS)
            // Always capture IPv6 so it cannot leak around the tunnel; the core
            // decides whether IPv6 is actually used (see the DNS queryStrategy).
            builder.addAddress(TUN_IPV6, 126).addRoute("::", 0)
            applyPerAppRules(builder, options)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
                if (options.appendHttpProxy) {
                    builder.setHttpProxy(
                        ProxyInfo.buildDirectProxy("127.0.0.1", LOCAL_HTTP_PROXY_PORT),
                    )
                }
            }
            builder.setConfigureIntent(openAppIntent())

            val fd = builder.establish()
                ?: throw IllegalStateException("VPN permission was not granted")
            tun = fd

            CoreManager.controller.start(config, fd.fd)
            startExit(options)
            onCoreStarted(options)
        } catch (e: Exception) {
            if (stopRequested) {
                shutdownCore() // stopVpn, queued next, finishes the stop
                return
            }
            Log.e(TAG, "Failed to start VPN", e)
            fail(e.message ?: e.toString())
        }
    }

    /**
     * Psiphon / Tor: started once Xray is up, since as an exit it reaches its servers through
     * Xray's psiphon-in / tor-in inbound (the Psiphon / Tor types connect directly). Blocks
     * until it's ready (the state stays Connecting).
     */
    private fun startExit(options: ConfigStore.Options) {
        val exit = options.exit ?: return
        ExitProcess.onExit = { message ->
            Log.w(TAG, "Exit ($exit) stopped: $message")
            worker.execute { if (CoreManager.state != CoreManager.State.DISCONNECTED) fail(message) }
        }
        when (exit) {
            "psiphon" -> PsiphonExit.start(this, options.exitRegion, options.exitDirect, options.psiphonConfig)
            "tor" -> TorExit.start(this, options.exitRegion, options.exitDirect, options.torBridge, options.torCustomBridges)
            else -> throw IllegalStateException("Unknown exit: $exit")
        }
    }

    private fun onCoreStarted(options: ConfigStore.Options) {
        CoreManager.setState(CoreManager.State.CONNECTED)
        remark = options.remark
        notify(buildNotification(remark, connected = true))
        startTicker()
    }

    private fun applyPerAppRules(builder: Builder, options: ConfigStore.Options) {
        val apps = options.apps.filter { it != packageName }
        // Our own traffic (the core's outbound sockets) must never enter the tunnel.
        if (options.perAppMode == "include" && apps.isNotEmpty()) {
            apps.forEach { addApp { builder.addAllowedApplication(it) } }
        } else {
            builder.addDisallowedApplication(packageName)
            if (options.perAppMode == "exclude") {
                apps.forEach { addApp { builder.addDisallowedApplication(it) } }
            }
        }
    }

    private inline fun addApp(block: () -> Unit) {
        try {
            block()
        } catch (e: PackageManager.NameNotFoundException) {
            // App was uninstalled since it was selected; skip it.
        }
    }

    private fun stopVpn() {
        if (CoreManager.state == CoreManager.State.DISCONNECTED) {
            stopSelfCompat()
            return
        }
        CoreManager.setState(CoreManager.State.DISCONNECTING)
        shutdownCore()
        CoreManager.setState(CoreManager.State.DISCONNECTED)
        stopSelfCompat()
    }

    private fun fail(message: String) {
        shutdownCore()
        CoreManager.setState(CoreManager.State.DISCONNECTED, message)
        stopSelfCompat()
    }

    private fun startTicker() {
        TrafficMeter.reset()
        tick?.cancel(false)
        tick = ticker.scheduleWithFixedDelay({
            if (CoreManager.state != CoreManager.State.CONNECTED) return@scheduleWithFixedDelay
            TrafficMeter.sample()
            notify(buildNotification(remark, connected = true))
        }, 1, 1, TimeUnit.SECONDS)
    }

    private fun shutdownCore() {
        tick?.cancel(false)
        tick = null
        TrafficMeter.reset()
        ExitProcess.stop()
        BrowserDialer.stop()
        try {
            if (CoreManager.controller.isRunning) CoreManager.controller.stop()
        } catch (e: Exception) {
            Log.w(TAG, "stopLoop failed", e)
        }
        try {
            tun?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Closing tun failed", e)
        }
        tun = null
    }

    private fun stopSelfCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    // region notification

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun notify(notification: Notification) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
    }

    private fun buildNotification(remark: String, connected: Boolean): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "VPN status", NotificationManager.IMPORTANCE_LOW)
                )
            }
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, BpbVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        if (connected) {
            // Proxy line when collapsed; proxy and direct when expanded.
            val rate = TrafficMeter.rate
            val proxy = "Proxy  ↑ ${TrafficMeter.format(rate.proxyUp)}/s  ↓ ${TrafficMeter.format(rate.proxyDown)}/s"
            val direct = "Direct  ↑ ${TrafficMeter.format(rate.directUp)}/s  ↓ ${TrafficMeter.format(rate.directDown)}/s"
            builder
                .setContentText(proxy)
                .setStyle(Notification.BigTextStyle().bigText("$proxy\n$direct"))
                // Live connection timer in the header: "BPB · Worker · 01:23".
                .setWhen(CoreManager.connectedAt)
                .setUsesChronometer(true)
        } else {
            builder.setContentText("Connecting…")
        }

        // No title: the header (app name · mode · timer) already says it all.
        return builder
            .setSmallIcon(R.drawable.ic_stat_vpn)
            .setSubText(remark)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(connected)
            .setContentIntent(openAppIntent())
            .addAction(Notification.Action.Builder(null, "Disconnect", stopIntent).build())
            .build()
    }

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this, 0,
        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    // endregion
}
