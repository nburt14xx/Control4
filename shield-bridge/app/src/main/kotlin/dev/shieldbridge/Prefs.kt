package dev.shieldbridge

import android.content.Context
import android.content.SharedPreferences
import java.security.SecureRandom

/** Tiny settings store: listening port and the optional API key. */
object Prefs {
    const val DEFAULT_PORT = 8765

    private fun sp(ctx: Context): SharedPreferences =
        ctx.getSharedPreferences("bridge", Context.MODE_PRIVATE)

    fun port(ctx: Context): Int = sp(ctx).getInt("port", DEFAULT_PORT)

    fun setPort(ctx: Context, port: Int) {
        sp(ctx).edit().putInt("port", port).apply()
    }

    /** Empty string means "no key required". */
    fun apiKey(ctx: Context): String = sp(ctx).getString("apiKey", "") ?: ""

    fun setApiKey(ctx: Context, key: String) {
        sp(ctx).edit().putString("apiKey", key).apply()
    }

    fun newApiKey(): String {
        val alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        val rnd = SecureRandom()
        return (1..8).map { alphabet[rnd.nextInt(alphabet.length)] }.joinToString("")
    }
}
