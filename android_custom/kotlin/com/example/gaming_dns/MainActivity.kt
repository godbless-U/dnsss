package com.example.gaming_dns

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.example.gaming_dns/vpn"
        private const val VPN_REQUEST_CODE = 1001
    }

    private var pendingDnsIp: String? = null
    private var pendingResult: MethodChannel.Result? = null
    private var receiverRegistered = false

    private val vpnStatusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != GamingVpnService.ACTION_STATUS) return
            val result = pendingResult ?: return
            pendingResult = null
            val success = intent.getBooleanExtra(GamingVpnService.EXTRA_SUCCESS, false)
            val message = intent.getStringExtra(GamingVpnService.EXTRA_MESSAGE).orEmpty()
            if (success) {
                result.success(true)
            } else {
                result.error("VPN_START_FAILED", message.ifBlank { "The DNS tunnel could not be started." }, null)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val filter = IntentFilter(GamingVpnService.ACTION_STATUS)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(vpnStatusReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(vpnStatusReceiver, filter)
        }
        receiverRegistered = true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startVpn" -> {
                        val dnsIp = call.argument<String>("dns_ip")?.trim()
                        if (dnsIp.isNullOrEmpty()) {
                            result.error("INVALID_DNS", "DNS address is empty", null)
                            return@setMethodCallHandler
                        }
                        if (pendingResult != null) {
                            result.error("VPN_START_IN_PROGRESS", "A DNS connection attempt is already in progress.", null)
                            return@setMethodCallHandler
                        }
                        pendingDnsIp = dnsIp
                        pendingResult = result
                        requestVpnPermission()
                    }
                    "stopVpn" -> {
                        stopVpnService()
                        result.success(null)
                    }
                    "getVpnStatus" -> result.success(GamingVpnService.activeDnsIp)
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestVpnPermission() {
        val prepareIntent = VpnService.prepare(this)
        if (prepareIntent != null) {
            @Suppress("DEPRECATION")
            startActivityForResult(prepareIntent, VPN_REQUEST_CODE)
        } else {
            launchVpnService()
        }
    }

    private fun launchVpnService() {
        val dnsIp = pendingDnsIp
        if (dnsIp.isNullOrBlank()) {
            pendingResult?.error("INVALID_DNS", "DNS address is missing", null)
            pendingResult = null
            return
        }

        val intent = Intent(this, GamingVpnService::class.java).apply {
            action = GamingVpnService.ACTION_START
            putExtra(GamingVpnService.EXTRA_DNS_IP, dnsIp)
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            // Keep the MethodChannel result pending. The VPN service sends a
            // status broadcast only after the end-to-end DNS tunnel probe.
        } catch (error: Exception) {
            pendingResult?.error("VPN_START_FAILED", error.message ?: "Could not start DNS service", null)
            pendingResult = null
        }
    }

    private fun stopVpnService() {
        val intent = Intent(this, GamingVpnService::class.java).apply {
            action = GamingVpnService.ACTION_STOP
        }
        try {
            startService(intent)
        } catch (_: Exception) {
            stopService(Intent(this, GamingVpnService::class.java))
        }
    }

    @Deprecated("Deprecated Android API retained for VPN permission compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_REQUEST_CODE) return
        if (resultCode == Activity.RESULT_OK) {
            launchVpnService()
        } else {
            pendingResult?.error("VPN_PERMISSION_DENIED", "VPN permission was denied", null)
            pendingResult = null
            pendingDnsIp = null
        }
    }

    override fun onDestroy() {
        if (receiverRegistered) {
            try { unregisterReceiver(vpnStatusReceiver) } catch (_: Exception) { }
            receiverRegistered = false
        }
        pendingResult?.error("ACTIVITY_DESTROYED", "Activity closed before DNS connection completed", null)
        pendingResult = null
        super.onDestroy()
    }
}
