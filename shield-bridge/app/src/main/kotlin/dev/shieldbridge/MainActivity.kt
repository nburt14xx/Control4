package dev.shieldbridge

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/**
 * Setup screen shown on the TV. Built in code (no layout XML) so the app has
 * no resource dependencies beyond its icon and banner.
 */
class MainActivity : Activity() {

    private lateinit var status: TextView
    private lateinit var serviceButton: Button
    private lateinit var keyButton: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(48), dp(32), dp(48), dp(32))
            setBackgroundColor(Color.rgb(18, 24, 38))
        }

        root.addView(TextView(this).apply {
            text = "Shield Bridge for Control4"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 28f)
            setTextColor(Color.WHITE)
        })
        root.addView(TextView(this).apply {
            text = "Exposes this box's Continue Watching list on the LAN and launches shows on request."
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTextColor(Color.LTGRAY)
            setPadding(0, dp(4), 0, dp(16))
        })

        status = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTextColor(Color.WHITE)
            setPadding(0, 0, 0, dp(16))
            typeface = android.graphics.Typeface.MONOSPACE
        }
        root.addView(status)

        val buttons = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(buttons)

        serviceButton = addButton(buttons, "Start service") {
            if (BridgeService.running) BridgeService.stop(this) else BridgeService.start(this)
            status.postDelayed({ refresh() }, 600)
        }
        addButton(buttons, "Grant 'TV listings' permission (needed to read Continue Watching)") {
            if (WatchNextRepository.hasPermission(this)) {
                toast("Already granted")
            } else {
                requestPermissions(arrayOf(TvConstants.PERMISSION_READ_TV_LISTINGS), 1)
            }
        }
        addButton(buttons, "Allow 'Display over other apps' (needed to launch shows while in background)") {
            openOverlaySettings()
        }
        addButton(buttons, "Test: read Continue Watching") { testContinue() }
        keyButton = addButton(buttons, "Require API key") { toggleApiKey() }
        addButton(buttons, "Refresh status") { refresh() }

        root.addView(TextView(this).apply {
            text = "If a permission screen does not open on this device, grant it from a computer with adb:\n" +
                "  adb shell pm grant dev.shieldbridge android.permission.READ_TV_LISTINGS\n" +
                "  adb shell appops set dev.shieldbridge SYSTEM_ALERT_WINDOW allow"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setTextColor(Color.GRAY)
            setPadding(0, dp(16), 0, 0)
            typeface = android.graphics.Typeface.MONOSPACE
        })

        val scroll = ScrollView(this).apply { addView(root) }
        setContentView(scroll)

        // First launch starts the server; after that the boot receiver keeps it alive.
        BridgeService.start(this)
    }

    override fun onResume() {
        super.onResume()
        status.postDelayed({ refresh() }, 300)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        refresh()
    }

    private fun refresh() {
        val addrs = NetUtil.localAddresses()
        val port = Prefs.port(this)
        val key = Prefs.apiKey(this)
        val sb = StringBuilder()
        sb.append("Service:        ").append(if (BridgeService.running) "running" else "stopped")
        BridgeService.lastError?.let { sb.append("  (").append(it).append(')') }
        sb.append('\n')
        sb.append("Address:        ")
        if (addrs.isEmpty()) sb.append("no network") else sb.append(addrs.joinToString("  ") { "http://$it:$port" })
        sb.append('\n')
        sb.append("TV listings:    ").append(if (WatchNextRepository.hasPermission(this)) "granted" else "NOT granted").append('\n')
        sb.append("Overlay perm:   ").append(if (Launcher.canLaunchFromBackground(this)) "granted" else "NOT granted").append('\n')
        sb.append("API key:        ").append(if (key.isEmpty()) "not required" else key).append('\n')
        status.text = sb.toString()
        serviceButton.text = if (BridgeService.running) "Stop service" else "Start service"
        keyButton.text = if (key.isEmpty()) "Require API key" else "Remove API key"
    }

    private fun testContinue() {
        if (!WatchNextRepository.hasPermission(this)) {
            toast("Grant the TV listings permission first")
            return
        }
        val items = try {
            WatchNextRepository.query(this)
        } catch (e: Exception) {
            toast("Query failed: ${e.message}")
            return
        }
        val lines = items.take(12).joinToString("\n") { item ->
            val ep = listOfNotNull(item.season?.let { "S$it" }, item.episode?.let { "E$it" }).joinToString("")
            "${item.appLabel}: ${item.title ?: "?"} ${if (ep.isNotEmpty()) "($ep)" else ""} ${item.progressPercent}% [${TvConstants.watchNextTypeName(item.watchNextType)}]"
        }
        AlertDialog.Builder(this)
            .setTitle("${items.size} Watch Next rows")
            .setMessage(if (items.isEmpty()) "Nothing yet. Watch part of something in Netflix, Prime, etc. and try again." else lines)
            .setPositiveButton("OK", null)
            .show()
    }

    private fun toggleApiKey() {
        if (Prefs.apiKey(this).isEmpty()) {
            Prefs.setApiKey(this, Prefs.newApiKey())
            toast("Enter this key in the Control4 driver's 'API Key' property")
        } else {
            Prefs.setApiKey(this, "")
        }
        refresh()
    }

    private fun openOverlaySettings() {
        if (Launcher.canLaunchFromBackground(this)) {
            toast("Already granted")
            return
        }
        try {
            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
        } catch (e: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION))
            } catch (e2: Exception) {
                toast("This device has no overlay settings screen; use the adb command shown below")
            }
        }
    }

    private fun addButton(parent: ViewGroup, label: String, onClick: () -> Unit): Button {
        val b = Button(this).apply {
            text = label
            isAllCaps = false
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
            setOnClickListener { onClick() }
        }
        val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        lp.bottomMargin = dp(6)
        parent.addView(b, lp)
        return b
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_LONG).show()

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()
}
