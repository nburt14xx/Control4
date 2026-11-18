package dev.shieldbridge

import java.net.Inet4Address
import java.net.NetworkInterface

object NetUtil {
    /** IPv4 addresses of the box's non-loopback interfaces (ethernet and wifi). */
    fun localAddresses(): List<String> {
        val out = ArrayList<String>()
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces() ?: return out
            for (iface in ifaces) {
                if (!iface.isUp || iface.isLoopback) continue
                for (addr in iface.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        out.add(addr.hostAddress ?: continue)
                    }
                }
            }
        } catch (e: Exception) {
            // no network yet; caller shows an empty list
        }
        return out
    }
}
