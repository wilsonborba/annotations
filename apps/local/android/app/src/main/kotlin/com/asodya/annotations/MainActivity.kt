package com.asodya.annotations

import android.app.Activity
import android.content.Intent
import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
  private val channelName = "com.asodya.annotations/secure_storage"
  private val exportChannelName = "com.asodya.annotations/export"
  private val exportRequestCode = 0xA412
  @Volatile private var pendingExport: PendingExport? = null
  private val keyAlias = "com.asodya.annotations.session_key"
  private val prefsName = "asodya_secure_session"
  private val prefsKey = "ciphertext"

  private class PendingExport(
    val requestId: String,
    var bytes: ByteArray,
    val result: MethodChannel.Result,
  ) {
    @Volatile var cancelled = false
    @Volatile var pickerReplied = false
    @Volatile var stream: OutputStream? = null
    var destination: android.net.Uri? = null
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, exportChannelName)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "saveExport" -> beginExport(call, result)
          "commitExport" -> commitExport(call, result)
          "cancelExport" -> cancelExport(call, result)
          else -> result.notImplemented()
        }
      }
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
      .setMethodCallHandler { call, result ->
        try {
          when (call.method) {
            "write" -> {
              val sid = call.argument<String>("session_id")
              val csrf = call.argument<String>("csrf_token")
              val verifiedUserId = call.argument<String>("verified_user_id")
              if (sid.isNullOrEmpty() || csrf.isNullOrEmpty()) {
                result.error("INVALID_ARGS", "Missing session_id or csrf_token", null)
                return@setMethodCallHandler
              }
              val cipher = Cipher.getInstance("AES/GCM/NoPadding")
              cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSecretKey())
              val payload = if (verifiedUserId.isNullOrBlank()) "$sid\n$csrf" else "$sid\n$csrf\n$verifiedUserId"
              val encrypted = cipher.doFinal(payload.toByteArray(StandardCharsets.UTF_8))
              val iv = cipher.iv
              val combined = ByteArray(1 + iv.size + encrypted.size)
              combined[0] = iv.size.toByte()
              System.arraycopy(iv, 0, combined, 1, iv.size)
              System.arraycopy(encrypted, 0, combined, 1 + iv.size, encrypted.size)
              getSharedPreferences(prefsName, Context.MODE_PRIVATE)
                .edit()
                .putString(prefsKey, Base64.encodeToString(combined, Base64.NO_WRAP))
                .apply()
              result.success(null)
            }
            "read" -> {
              val encoded = getSharedPreferences(prefsName, Context.MODE_PRIVATE)
                .getString(prefsKey, null)
              if (encoded == null) {
                result.success(null)
                return@setMethodCallHandler
              }
              val combined = Base64.decode(encoded, Base64.NO_WRAP)
              if (combined.isEmpty()) {
                result.success(null)
                return@setMethodCallHandler
              }
              val ivLen = combined[0].toInt() and 0xFF
              val iv = combined.copyOfRange(1, 1 + ivLen)
              val ciphertext = combined.copyOfRange(1 + ivLen, combined.size)
              val cipher = Cipher.getInstance("AES/GCM/NoPadding")
              cipher.init(Cipher.DECRYPT_MODE, getOrCreateSecretKey(), GCMParameterSpec(128, iv))
              val plain = String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8)
              val parts = plain.split("\n", limit = 3)
              if (parts.size >= 2) {
                val session = mutableMapOf("session_id" to parts[0], "csrf_token" to parts[1])
                if (parts.size == 3 && parts[2].isNotBlank()) session["verified_user_id"] = parts[2]
                result.success(session)
              } else {
                result.success(null)
              }
            }
            "delete" -> {
              getSharedPreferences(prefsName, Context.MODE_PRIVATE)
                .edit()
                .remove(prefsKey)
                .apply()
              result.success(null)
            }
            else -> result.notImplemented()
          }
        } catch (e: Exception) {
          result.error("KEYSTORE_ERROR", e.message, null)
        }
      }
  }

  private fun beginExport(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
    val requestId = call.argument<String>("request_id")
    val requestedName = call.argument<String>("name")
    val mimeType = call.argument<String>("mime_type")
    val bytes = call.argument<ByteArray>("bytes")
    if (requestId.isNullOrBlank() || requestedName.isNullOrBlank() || bytes == null) {
      result.error("INVALID_ARGS", "Missing export request fields", null)
      return
    }
    val extension = when (mimeType) {
      "application/pdf" -> ".pdf"
      "application/zip" -> ".zip"
      else -> {
        result.error("INVALID_MIME", "Unsupported export MIME type", null)
        return
      }
    }
    if (pendingExport != null) {
      result.error("SAVE_BUSY", "Another export picker is active", null)
      return
    }

    val safeStem = requestedName
      .substringAfterLast('/')
      .substringAfterLast('\\')
      .filterNot { it.code < 0x20 || it.code == 0x7f }
      .trim()
      .trimStart('.')
      .removeSuffix(".pdf")
      .removeSuffix(".zip")
      .ifBlank { "export" }
    val pending = PendingExport(requestId, bytes, result)
    pendingExport = pending
    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
      addCategory(Intent.CATEGORY_OPENABLE)
      type = mimeType
      putExtra(Intent.EXTRA_TITLE, safeStem + extension)
      addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
    }
    try {
      startActivityForResult(intent, exportRequestCode)
    } catch (e: Exception) {
      pendingExport = null
      pending.bytes.fill(0)
      result.error("SAVE_PICKER_FAILED", e.message, null)
    }
  }

  private fun cancelExport(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
    val requestId = call.argument<String>("request_id")
    val pending = pendingExport
    if (pending == null || pending.requestId != requestId) {
      result.success(false)
      return
    }
    pending.cancelled = true
    try {
      pending.stream?.close()
    } catch (_: Exception) {
      // Cancellation must not remove or replace a user-selected destination.
    }
    if (pending.stream == null) pending.bytes.fill(0)
    if (!pending.pickerReplied) {
      pending.pickerReplied = true
      pending.result.success(mapOf("status" to "cancelled"))
    }
    if (pending.stream == null && pending.destination != null && pendingExport === pending) {
      pendingExport = null
    }
    result.success(true)
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    if (requestCode != exportRequestCode) {
      super.onActivityResult(requestCode, resultCode, data)
      return
    }
    val pending = pendingExport ?: return
    if (pending.cancelled || resultCode != Activity.RESULT_OK) {
      pendingExport = null
      pending.bytes.fill(0)
      if (!pending.pickerReplied) {
        pending.pickerReplied = true
        pending.result.success(mapOf("status" to "cancelled"))
      }
      return
    }
    val uri = data?.data
    if (uri == null) {
      pendingExport = null
      pending.bytes.fill(0)
      pending.pickerReplied = true
      pending.result.success(mapOf("status" to "cancelled"))
      return
    }
    pending.destination = uri
    pending.pickerReplied = true
    pending.result.success(mapOf("status" to "selected"))
  }

  private fun commitExport(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
    val requestId = call.argument<String>("request_id")
    val pending = pendingExport
    if (pending == null || pending.requestId != requestId || pending.cancelled) {
      result.success(false)
      return
    }
    val destination = pending.destination
    if (!pending.pickerReplied || destination == null) {
      result.error("SAVE_NOT_SELECTED", "No destination was selected", null)
      return
    }
    val stream = try {
      contentResolver.openOutputStream(destination, "w")
    } catch (_: Exception) {
      null
    }
    if (stream == null) {
      pendingExport = null
      pending.bytes.fill(0)
      result.error("SAVE_WRITE_FAILED", "Unable to open selected destination", null)
      return
    }
    pending.stream = stream
    Thread {
      var failure: Exception? = null
      try {
        stream.use { output ->
          var offset = 0
          while (offset < pending.bytes.size && !pending.cancelled) {
            val end = minOf(offset + 64 * 1024, pending.bytes.size)
            output.write(pending.bytes, offset, end - offset)
            offset = end
          }
          if (!pending.cancelled) output.flush()
        }
      } catch (e: Exception) {
        failure = e
      }
      pending.bytes.fill(0)
      runOnUiThread {
        pending.stream = null
        if (pendingExport === pending) pendingExport = null
        if (pending.cancelled) {
          result.success(false)
        } else if (failure != null) {
          result.error("SAVE_WRITE_FAILED", failure?.message, null)
        } else {
          result.success(true)
        }
      }
    }.start()
  }

  private fun getOrCreateSecretKey(): SecretKey {
    val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    val existing = ks.getKey(keyAlias, null) as? SecretKey
    if (existing != null) return existing
    val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
    gen.init(
      KeyGenParameterSpec.Builder(
        keyAlias,
        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
      )
        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
        .setKeySize(256)
        .build(),
    )
    return gen.generateKey()
  }
}
