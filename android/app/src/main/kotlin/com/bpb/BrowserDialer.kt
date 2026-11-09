package com.bpb

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebView
import xray.Xray

/**
 * Worker's Browser Dialer (a test): Xray serves its dialer page on [ADDRESS] and opens every
 * WebSocket through it; a hidden WebView loads that page, so the TLS is Chromium's. Our app is
 * outside the TUN, so the WebView connects directly.
 */
object BrowserDialer {
    private const val TAG = "BpbBrowserDialer"
    // Not 10831: TorExit's control port.
    private const val ADDRESS = "127.0.0.1:10832"

    private val mainHandler = Handler(Looper.getMainLooper())
    private var webView: WebView? = null

    /**
     * Turns Xray's browser dialer on (it serves the page right away) and loads the page.
     * Process-wide: while on, every WebSocket outbound goes through the page.
     */
    fun start(context: Context) {
        Xray.setBrowserDialer(ADDRESS)
        mainHandler.post { load(context) }
    }

    /** Turns the browser dialer off and drops the WebView. */
    fun stop() {
        Xray.setBrowserDialer("")
        mainHandler.post { drop() }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun load(context: Context) {
        drop()
        webView = WebView(context.applicationContext).apply {
            settings.javaScriptEnabled = true
            webChromeClient = object : WebChromeClient() {
                override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                    Log.i(TAG, "${message.messageLevel()}: ${message.message()}")
                    return true
                }
            }
            onResume()
            resumeTimers()
            loadUrl("http://$ADDRESS/")
        }
        Log.i(TAG, "Loading the dialer page")
    }

    private fun drop() {
        webView?.apply {
            stopLoading()
            destroy()
        }
        webView = null
    }
}
