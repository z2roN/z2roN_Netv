package com.z2ron.z2ron_net

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface

// z2roN Net: 플러그인 없이 안드로이드 기본 기능으로 네트워크 정보를 읽어 Flutter 로 넘깁니다.
class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "z2ron/net").setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(info())
                "requestLocation" -> askLocation(result)
                "openUrl" -> {
                    try {
                        val i = Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url")))
                        startActivity(i)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("open", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasLoc(): Boolean =
        Build.VERSION.SDK_INT < 23 || checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun askLocation(result: MethodChannel.Result) {
        if (hasLoc()) { result.success(true); return }
        pending?.success(false)
        pending = result
        requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION), 77)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 77) {
            pending?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pending = null
        }
    }

    private fun ipToStr(i: Int): String = "${i and 0xff}.${(i shr 8) and 0xff}.${(i shr 16) and 0xff}.${(i shr 24) and 0xff}"

    @Suppress("DEPRECATION")
    private fun info(): Map<String, Any?> {
        val m = HashMap<String, Any?>()
        m["manufacturer"] = Build.MANUFACTURER
        m["model"] = Build.MODEL
        m["androidVersion"] = Build.VERSION.RELEASE
        m["sdk"] = Build.VERSION.SDK_INT
        m["kernel"] = System.getProperty("os.version")
        val dn = try { Settings.Global.getString(contentResolver, "device_name") } catch (e: Exception) { null }
        m["deviceName"] = if (dn.isNullOrEmpty()) Build.MODEL else dn
        m["hasLocation"] = hasLoc()
        m["locationOn"] = try {
            val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            if (Build.VERSION.SDK_INT >= 28) lm.isLocationEnabled else true
        } catch (e: Exception) { true }

        var transport = "none"
        var localIp: String? = null
        var prefix = 24
        var gateway: String? = null
        var iface: String? = null
        val dns = ArrayList<String>()
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val net = if (Build.VERSION.SDK_INT >= 23) cm.activeNetwork else null
            if (net != null) {
                val caps = cm.getNetworkCapabilities(net)
                if (caps != null) {
                    transport = when {
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
                        else -> "other"
                    }
                }
                val lp = cm.getLinkProperties(net)
                if (lp != null) {
                    iface = lp.interfaceName
                    for (la in lp.linkAddresses) {
                        val a = la.address
                        if (a is Inet4Address && !a.isLoopbackAddress) { localIp = a.hostAddress; prefix = la.prefixLength }
                    }
                    for (r in lp.routes) {
                        if (r.isDefaultRoute) {
                            val g = r.gateway
                            if (g is Inet4Address) gateway = g.hostAddress
                        }
                    }
                    for (d in lp.dnsServers) { val h = d.hostAddress; if (h != null) dns.add(h) }
                }
            }
        } catch (e: Exception) { }

        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val wi = wm.connectionInfo
            if (transport == "wifi" && wi != null) {
                val s = (wi.ssid ?: "").trim('"')
                m["ssid"] = if (s.isEmpty() || s == "<unknown ssid>") null else s
                val b = wi.bssid
                m["bssid"] = if (b == null || b == "02:00:00:00:00:00") null else b
                m["linkSpeed"] = wi.linkSpeed
                m["rssi"] = wi.rssi
                m["freq"] = wi.frequency
                if (Build.VERSION.SDK_INT >= 29) { m["txSpeed"] = wi.txLinkSpeedMbps; m["rxSpeed"] = wi.rxLinkSpeedMbps }
            }
            val dh = wm.dhcpInfo
            if (dh != null) {
                if (gateway == null && dh.gateway != 0) gateway = ipToStr(dh.gateway)
                if (localIp == null && dh.ipAddress != 0 && transport == "wifi") localIp = ipToStr(dh.ipAddress)
                if (dns.isEmpty() && dh.dns1 != 0) dns.add(ipToStr(dh.dns1))
            }
        } catch (e: Exception) { }

        val ifs = ArrayList<String>()
        try {
            for (ni in NetworkInterface.getNetworkInterfaces()) {
                for (a in ni.inetAddresses) {
                    if (a is Inet4Address && !a.isLoopbackAddress) ifs.add(ni.name + ": " + a.hostAddress)
                }
            }
        } catch (e: Exception) { }

        m["transport"] = transport
        m["localIp"] = localIp
        m["prefix"] = prefix
        m["gateway"] = gateway
        m["iface"] = iface
        m["dns"] = dns
        m["ifaces"] = ifs
        return m
    }
}
