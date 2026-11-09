package com.bpb

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.security.KeyChain
import android.util.Base64
import java.io.File

/**
 * Domain Fronting's CA (made by the app, see lib/services/mitm_ca.dart): bpb-cert.crt and
 * bpb-cert.key in the app's files directory, which is Xray's certificate location
 * (Xray.initEnv), so the config names them without a path. The key never leaves it.
 */
object MitmCa {
    private const val CERT = "bpb-cert.crt"
    private const val KEY = "bpb-cert.key"

    fun exists(activity: Activity): Boolean =
        File(activity.filesDir, CERT).isFile && File(activity.filesDir, KEY).isFile

    fun save(activity: Activity, cert: String, key: String) {
        File(activity.filesDir, KEY).writeText(key)
        File(activity.filesDir, CERT).writeText(cert)
    }

    /**
     * Lets the user install bpb-cert.crt as a trusted CA. Android 10 and older take it
     * straight from the app; since Android 11 only Settings installs CAs, from a file, so it
     * goes to Downloads and Settings opens. Returns where the file went, or null.
     */
    fun install(activity: Activity): String? {
        val pem = File(activity.filesDir, CERT).readText()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            val der = Base64.decode(pem.lines().filter { !it.startsWith("-----") }.joinToString(""), Base64.DEFAULT)
            activity.startActivity(
                KeyChain.createInstallIntent()
                    .putExtra(KeyChain.EXTRA_CERTIFICATE, der)
                    .putExtra(KeyChain.EXTRA_NAME, "BPB"),
            )
            return null
        }
        val resolver = activity.contentResolver
        // The copy saved before is rewritten in place; a first one is created.
        val uri = earlierCopy(activity)?.also { existing ->
            resolver.openOutputStream(existing, "wt")?.use { it.write(pem.toByteArray()) }
                ?: throw IllegalStateException("Can't write the file")
        } ?: create(activity, pem)
        // Android renames a new file whose name is taken ("bpb-cert (1).crt"); report the real name.
        val saved = resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null } ?: CERT
        openInstallScreen(activity)
        return "Downloads/$saved"
    }

    /**
     * Settings → … → Install a certificate (CA certificate / VPN & app / Wi-Fi). There's no
     * public intent for it, but AOSP Settings (11+) exports it as this activity; elsewhere, the
     * Security page.
     */
    private fun openInstallScreen(activity: Activity) {
        try {
            activity.startActivity(
                Intent(Intent.ACTION_MAIN).setClassName(
                    "com.android.settings",
                    "com.android.settings.Settings\$InstallCertificateFromStorageActivity",
                ),
            )
        } catch (e: ActivityNotFoundException) {
            activity.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
        } catch (e: SecurityException) {
            activity.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
        }
    }

    /** A new bpb-cert.crt in Downloads holding [pem]. */
    private fun create(activity: Activity, pem: String): Uri {
        val resolver = activity.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, CERT)
            put(MediaStore.MediaColumns.MIME_TYPE, "application/x-x509-ca-cert")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Can't create the file in Downloads")
        try {
            resolver.openOutputStream(uri)?.use { it.write(pem.toByteArray()) }
                ?: throw IllegalStateException("Can't write the file")
            resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return uri
    }

    /**
     * The bpb-cert*.crt this installation saved to Downloads before, if any. Android only lists
     * files the app created itself, so a copy from an earlier install isn't found (and a new
     * one beside it becomes "bpb-cert (1).crt").
     */
    private fun earlierCopy(activity: Activity): Uri? {
        val downloads = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        return activity.contentResolver.query(
            downloads,
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ?",
            arrayOf("bpb-cert%.crt"),
            "${MediaStore.MediaColumns.DATE_ADDED} DESC",
        )?.use { if (it.moveToFirst()) ContentUris.withAppendedId(downloads, it.getLong(0)) else null }
    }
}
