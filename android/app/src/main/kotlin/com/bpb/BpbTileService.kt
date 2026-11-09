package com.bpb

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Quick settings tile: toggles the VPN with the last used config. */
class BpbTileService : TileService() {

    private val listener = CoreManager.Listener { _, _ -> updateTile() }

    override fun onStartListening() {
        CoreManager.addListener(listener)
        updateTile()
    }

    override fun onStopListening() {
        CoreManager.removeListener(listener)
    }

    override fun onClick() {
        when (CoreManager.state) {
            CoreManager.State.CONNECTED, CoreManager.State.CONNECTING -> BpbVpnService.stop(this)
            CoreManager.State.DISCONNECTING -> Unit
            CoreManager.State.DISCONNECTED -> {
                // Permission and first-time setup need the app UI.
                if (VpnService.prepare(this) != null || !ConfigStore.hasConfig(this)) {
                    openApp()
                } else {
                    BpbVpnService.start(this)
                }
            }
        }
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        tile.state = when (CoreManager.state) {
            CoreManager.State.CONNECTED -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        tile.label = "BPB"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = when (CoreManager.state) {
                CoreManager.State.CONNECTED -> "Connected"
                CoreManager.State.CONNECTING -> "Connecting…"
                CoreManager.State.DISCONNECTING -> "Disconnecting…"
                CoreManager.State.DISCONNECTED -> "Off"
            }
        }
        tile.updateTile()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
