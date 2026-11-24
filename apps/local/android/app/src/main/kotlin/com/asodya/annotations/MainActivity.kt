package com.asodya.annotations

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
  private val channelName = "com.asodya.annotations/secure_storage"
  private val keyAlias = "com.asodya.annotations.session_key"
  private val prefsName = "asodya_secure_session"
  private val prefsKey = "ciphertext"

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
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
