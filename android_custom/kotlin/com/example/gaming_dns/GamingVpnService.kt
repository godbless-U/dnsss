package com.example.gaming_dns

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import kotlin.math.min

/**
 * DNS-only Android VPN. Only packets addressed to the two virtual DNS stub
 * addresses are routed into TUN; ordinary application traffic remains on the
 * underlying network. DNS packets are forwarded to the user's selected resolver
 * through protected sockets, then a response packet is written back to TUN.
 */
class GamingVpnService : VpnService() {
    companion object {
        const val ACTION_START = "com.example.gaming_dns.START_VPN"
        const val ACTION_STOP = "com.example.gaming_dns.STOP_VPN"
        const val ACTION_STATUS = "com.example.gaming_dns.VPN_STATUS"
        const val EXTRA_DNS_IP = "dns_ip"
        const val EXTRA_SUCCESS = "success"
        const val EXTRA_MESSAGE = "message"
        @Volatile var activeDnsIp: String? = null
            private set

        private const val TAG = "GamingVpnService"
        private const val CHANNEL_ID = "gaming_dns_vpn"
        private const val NOTIFICATION_ID = 7319

        // The OS sends DNS queries to these local stub addresses. The TUN routes
        // only these /32 and /128 destinations, not all Internet traffic.
        private const val VIRTUAL_DNS_V4 = "10.111.0.1"
        private const val VPN_ADDRESS_V4 = "10.111.0.2"
        private const val VIRTUAL_DNS_V6 = "fd12:3456:789a::1"
        private const val VPN_ADDRESS_V6 = "fd12:3456:789a::2"

        private val VIRTUAL_DNS_V4_BYTES = byteArrayOf(10, 111, 0, 1)
        private val VIRTUAL_DNS_V6_BYTES = byteArrayOf(
            0xfd.toByte(), 0x12, 0x34, 0x56, 0x78, 0x9a.toByte(),
            0, 0, 0, 0, 0, 0, 0, 0, 0, 1
        )

        private const val DNS_PORT = 53
        private const val PROTOCOL_UDP = 17
        private const val PROTOCOL_TCP = 6
        private const val TCP_FIN = 0x01
        private const val TCP_SYN = 0x02
        private const val TCP_RST = 0x04
        private const val TCP_PSH = 0x08
        private const val TCP_ACK = 0x10
        private const val MAX_UDP_DNS_RESPONSE = 1200
        private const val SESSION_TIMEOUT_MS = 60_000L
    }

    private data class PacketView(
        val ipVersion: Int,
        val sourceAddress: InetAddress,
        val destinationAddress: InetAddress,
        val protocol: Int,
        val sourcePort: Int,
        val destinationPort: Int,
        val payloadOffset: Int,
        val payloadLength: Int,
        val tcpSequence: Long = 0L,
        val tcpAcknowledgement: Long = 0L,
        val tcpFlags: Int = 0
    )

    private data class TcpKey(val sourceHex: String, val sourcePort: Int, val ipVersion: Int)

    private class TcpSession(
        val key: TcpKey,
        val clientAddress: InetAddress,
        val serverAddress: InetAddress,
        val clientPort: Int,
        val ipVersion: Int,
        var clientNextSequence: Long,
        val initialServerSequence: Long,
        var serverNextSequence: Long
    ) {
        val requestBuffer = ByteArrayOutputStream()
        @Volatile var processing = false
        @Volatile var finished = false
        @Volatile var closed = false
        @Volatile var lastActivity = System.currentTimeMillis()
        var cachedResponsePackets: List<ByteArray> = emptyList()
    }

    @Volatile private var running = false
    @Volatile private var selectedDns: InetAddress? = null
    private var vpnInterface: ParcelFileDescriptor? = null
    private var tunInput: FileInputStream? = null
    private var tunOutput: FileOutputStream? = null
    private var packetThread: Thread? = null
    private var packetExecutor: ThreadPoolExecutor? = null
    private val outputLock = Any()
    private val tcpSessions = ConcurrentHashMap<TcpKey, TcpSession>()
    private val random = SecureRandom()

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                stopForegroundCompat()
                stopSelf()
            }
            ACTION_START -> {
                val dnsIp = intent.getStringExtra(EXTRA_DNS_IP)?.trim().orEmpty()
                try {
                    startForegroundCompat("Starting DNS tunnel…")
                    startTunnel(dnsIp)
                    updateNotification("DNS active: $dnsIp")
                    sendStatus(true, dnsIp, "DNS forwarding is active and the tunnel test passed.")
                    Log.i(TAG, "DNS tunnel is active for $dnsIp")
                } catch (error: Exception) {
                    Log.e(TAG, "Could not start DNS tunnel", error)
                    stopTunnel()
                    updateNotification("DNS connection failed")
                    sendStatus(false, dnsIp, error.message ?: "Could not establish DNS tunnel")
                    stopForegroundCompat()
                    stopSelf()
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun startTunnel(dnsIp: String) {
        stopTunnel()
        if (!isNumericIp(dnsIp)) throw IllegalArgumentException("Enter a numeric IPv4 or IPv6 DNS address.")
        val resolver = InetAddress.getByName(dnsIp)
        if (resolver.isAnyLocalAddress || resolver.isLoopbackAddress || resolver.isMulticastAddress) {
            throw IllegalArgumentException("The selected DNS address cannot be a loopback, wildcard or multicast address.")
        }
        selectedDns = resolver

        val builder = Builder()
            .setSession("Gaming DNS — $dnsIp")
            .setMtu(1500)
            .addAddress(VPN_ADDRESS_V4, 32)
            .addDnsServer(VIRTUAL_DNS_V4)
            .addRoute(VIRTUAL_DNS_V4, 32)
            .addAddress(VPN_ADDRESS_V6, 128)
            .addDnsServer(VIRTUAL_DNS_V6)
            .addRoute(VIRTUAL_DNS_V6, 128)

        val established = builder.establish()
            ?: throw IOException("Android did not allow the VPN interface to be established. Check VPN permission and whether another VPN is active.")

        vpnInterface = established
        packetExecutor = ThreadPoolExecutor(
            4,
            8,
            30L,
            TimeUnit.SECONDS,
            ArrayBlockingQueue(128),
            { task -> Thread(task, "GamingDns-Forwarder").apply { isDaemon = true } },
            ThreadPoolExecutor.AbortPolicy()
        )
        tunInput = FileInputStream(established.fileDescriptor)
        tunOutput = FileOutputStream(established.fileDescriptor)
        running = true
        packetThread = Thread({ packetReadLoop() }, "GamingDns-TUN").apply {
            isDaemon = true
            start()
        }

        // End-to-end check: send a DNS query to the virtual DNS IP through TUN.
        // A successful reply proves that packet capture, forwarding and response
        // injection all work; it is not just a check of the service flag.
        if (!probeThroughTunnel()) {
            throw IOException("The selected DNS did not answer through the VPN tunnel. Try another DNS or check that UDP/53 is allowed on this network.")
        }
        activeDnsIp = dnsIp
    }

    private fun isNumericIp(value: String): Boolean {
        if (value.isBlank() || value.contains('%')) return false
        if (value.contains(':')) return value.matches(Regex("[0-9a-fA-F:.]+"))
        if (!value.matches(Regex("[0-9.]+"))) return false
        val parts = value.split('.')
        return parts.size == 4 && parts.all { part ->
            part.isNotEmpty() && part.toIntOrNull()?.let { it in 0..255 } == true
        }
    }

    private fun packetReadLoop() {
        val buffer = ByteArray(32767)
        var packetsRead = 0
        while (running) {
            val length = try {
                tunInput?.read(buffer) ?: -1
            } catch (error: IOException) {
                if (running) Log.w(TAG, "TUN read failed", error)
                -1
            } catch (error: Exception) {
                if (running) Log.w(TAG, "TUN reader stopped", error)
                -1
            }
            if (length < 0) break
            if (length == 0) {
                if (!running) break
                try { Thread.sleep(10) } catch (_: InterruptedException) { break }
                continue
            }
            val packet = buffer.copyOf(length)
            try {
                processPacket(packet)
            } catch (error: Exception) {
                Log.w(TAG, "Dropped malformed TUN packet", error)
            }
            packetsRead++
            if (packetsRead % 256 == 0) expireTcpSessions()
        }
    }

    private fun processPacket(packet: ByteArray) {
        val view = parseDnsPacket(packet) ?: return
        when (view.protocol) {
            PROTOCOL_UDP -> {
                if (view.payloadLength < 12) return
                val query = packet.copyOfRange(view.payloadOffset, view.payloadOffset + view.payloadLength)
                submitForwarding {
                    val response = forwardUdpDns(query)
                    val safeResponse = limitUdpResponse(response, MAX_UDP_DNS_RESPONSE)
                    val reply = buildUdpPacket(
                        view.ipVersion,
                        view.destinationAddress,
                        view.sourceAddress,
                        DNS_PORT,
                        view.sourcePort,
                        safeResponse
                    )
                    writeTunPacket(reply)
                }
            }
            PROTOCOL_TCP -> {
                if (view.destinationPort == DNS_PORT) handleTcpPacket(view, packet)
                else if (view.destinationPort == 853) rejectDnsOverTls(view)
            }
        }
    }

    private fun parseDnsPacket(packet: ByteArray): PacketView? {
        if (packet.isEmpty()) return null
        return when ((packet[0].toInt() ushr 4) and 0x0f) {
            4 -> parseIpv4DnsPacket(packet)
            6 -> parseIpv6DnsPacket(packet)
            else -> null
        }
    }

    private fun parseIpv4DnsPacket(packet: ByteArray): PacketView? {
        if (packet.size < 20) return null
        val headerLength = (packet[0].toInt() and 0x0f) * 4
        val totalLength = readU16(packet, 2)
        if (headerLength < 20 || totalLength < headerLength || totalLength > packet.size) return null
        val fragment = readU16(packet, 6)
        if ((fragment and 0x3fff) != 0) return null // Fragmented DNS is intentionally not reassembled.
        val destinationBytes = packet.copyOfRange(16, 20)
        if (!destinationBytes.contentEquals(VIRTUAL_DNS_V4_BYTES)) return null
        val protocol = packet[9].toInt() and 0xff
        if (protocol != PROTOCOL_UDP && protocol != PROTOCOL_TCP) return null
        return parseTransport(packet, 4, totalLength, headerLength, protocol)
    }

    private fun parseIpv6DnsPacket(packet: ByteArray): PacketView? {
        if (packet.size < 40) return null
        val payloadLength = readU16(packet, 4)
        val totalLength = 40 + payloadLength
        if (totalLength > packet.size) return null
        val destinationBytes = packet.copyOfRange(24, 40)
        if (!destinationBytes.contentEquals(VIRTUAL_DNS_V6_BYTES)) return null

        var nextHeader = packet[6].toInt() and 0xff
        var offset = 40
        var loops = 0
        while (loops++ < 8) {
            when (nextHeader) {
                0, 43, 60, 135 -> { // Hop-by-hop, routing, destination options, mobility
                    if (offset + 2 > totalLength) return null
                    val next = packet[offset].toInt() and 0xff
                    val extensionLength = ((packet[offset + 1].toInt() and 0xff) + 1) * 8
                    if (extensionLength < 8 || offset + extensionLength > totalLength) return null
                    nextHeader = next
                    offset += extensionLength
                }
                44 -> { // Fragment header: only accept atomic fragments.
                    if (offset + 8 > totalLength) return null
                    val next = packet[offset].toInt() and 0xff
                    val fragment = readU16(packet, offset + 2)
                    if ((fragment and 0xfff9) != 0) return null
                    nextHeader = next
                    offset += 8
                }
                51 -> { // Authentication header
                    if (offset + 2 > totalLength) return null
                    val next = packet[offset].toInt() and 0xff
                    val extensionLength = ((packet[offset + 1].toInt() and 0xff) + 2) * 4
                    if (extensionLength < 8 || offset + extensionLength > totalLength) return null
                    nextHeader = next
                    offset += extensionLength
                }
                else -> break
            }
        }
        if (nextHeader != PROTOCOL_UDP && nextHeader != PROTOCOL_TCP) return null
        return parseTransport(packet, 6, totalLength, offset, nextHeader)
    }

    private fun parseTransport(
        packet: ByteArray,
        ipVersion: Int,
        totalLength: Int,
        transportOffset: Int,
        protocol: Int
    ): PacketView? {
        if (protocol == PROTOCOL_UDP) {
            if (transportOffset + 8 > totalLength) return null
            val sourcePort = readU16(packet, transportOffset)
            val destinationPort = readU16(packet, transportOffset + 2)
            val udpLength = readU16(packet, transportOffset + 4)
            if (destinationPort != DNS_PORT || udpLength < 8 || transportOffset + udpLength > totalLength) return null
            return PacketView(
                ipVersion,
                addressFromPacket(packet, ipVersion, if (ipVersion == 4) 12 else 8),
                addressFromPacket(packet, ipVersion, if (ipVersion == 4) 16 else 24),
                protocol,
                sourcePort,
                destinationPort,
                transportOffset + 8,
                udpLength - 8
            )
        }

        if (transportOffset + 20 > totalLength) return null
        val sourcePort = readU16(packet, transportOffset)
        val destinationPort = readU16(packet, transportOffset + 2)
        // Private DNS opportunistic mode may first attempt TCP/853. A reset is
        // returned below so Android can quickly fall back to the VPN DNS stub.
        if (destinationPort != DNS_PORT && destinationPort != 853) return null
        val tcpHeaderLength = ((packet[transportOffset + 12].toInt() ushr 4) and 0x0f) * 4
        if (tcpHeaderLength < 20 || transportOffset + tcpHeaderLength > totalLength) return null
        return PacketView(
            ipVersion,
            addressFromPacket(packet, ipVersion, if (ipVersion == 4) 12 else 8),
            addressFromPacket(packet, ipVersion, if (ipVersion == 4) 16 else 24),
            protocol,
            sourcePort,
            destinationPort,
            transportOffset + tcpHeaderLength,
            totalLength - transportOffset - tcpHeaderLength,
            readU32(packet, transportOffset + 4),
            readU32(packet, transportOffset + 8),
            packet[transportOffset + 13].toInt() and 0xff
        )
    }

    private fun addressFromPacket(packet: ByteArray, ipVersion: Int, offset: Int): InetAddress {
        return InetAddress.getByAddress(packet.copyOfRange(offset, offset + if (ipVersion == 4) 4 else 16))
    }

    private fun submitForwarding(task: () -> Unit) {
        try {
            packetExecutor?.execute {
                if (running) {
                    try { task() } catch (error: Exception) { Log.w(TAG, "DNS forwarding failed", error) }
                }
            }
        } catch (_: RejectedExecutionException) {
            Log.w(TAG, "DNS queue is full; packet dropped")
        }
    }

    private fun forwardUdpDns(query: ByteArray): ByteArray {
        val resolver = selectedDns ?: return servFail(query)
        try {
            DatagramSocket().use { socket ->
                if (!protect(socket)) throw IOException("Could not protect DNS socket from VPN loop")
                socket.soTimeout = 2800
                socket.connect(resolver, DNS_PORT)
                socket.send(DatagramPacket(query, query.size))
                val buffer = ByteArray(65535)
                val incoming = DatagramPacket(buffer, buffer.size)
                socket.receive(incoming)
                var response = incoming.data.copyOf(incoming.length)
                if (!isDnsResponseFor(response, query)) throw IOException("Resolver returned an invalid DNS response")
                if (response.size >= 4 && (response[2].toInt() and 0x02) != 0) {
                    try { response = forwardDnsOverTcp(query, resolver) } catch (error: Exception) {
                        Log.w(TAG, "TCP fallback to resolver failed; returning truncated UDP answer", error)
                    }
                }
                return response
            }
        } catch (error: Exception) {
            Log.w(TAG, "UDP request to selected DNS failed", error)
            return servFail(query)
        }
    }

    private fun forwardDnsOverTcp(query: ByteArray, resolver: InetAddress): ByteArray {
        Socket().use { socket ->
            if (!protect(socket)) throw IOException("Could not protect DNS TCP socket from VPN loop")
            socket.soTimeout = 3500
            socket.connect(InetSocketAddress(resolver, DNS_PORT), 2500)
            val output = DataOutputStream(socket.getOutputStream())
            output.writeShort(query.size)
            output.write(query)
            output.flush()
            val input = DataInputStream(socket.getInputStream())
            val length = input.readUnsignedShort()
            if (length < 12) throw IOException("Invalid TCP DNS response length")
            val response = ByteArray(length)
            input.readFully(response)
            if (!isDnsResponseFor(response, query)) throw IOException("Resolver returned an invalid TCP DNS response")
            return response
        }
    }

    private fun isDnsResponseFor(response: ByteArray, query: ByteArray): Boolean {
        if (response.size < 12 || query.size < 2) return false
        val sameId = response[0] == query[0] && response[1] == query[1]
        val isResponse = (response[2].toInt() and 0x80) != 0
        return sameId && isResponse
    }

    private fun probeThroughTunnel(): Boolean {
        val query = makeDnsQuery("example.com", random.nextInt(65536))
        return try {
            DatagramSocket().use { socket ->
                socket.soTimeout = 4200
                val virtualDns = InetAddress.getByName(VIRTUAL_DNS_V4)
                socket.send(DatagramPacket(query, query.size, virtualDns, DNS_PORT))
                val buffer = ByteArray(4096)
                val reply = DatagramPacket(buffer, buffer.size)
                socket.receive(reply)
                val response = reply.data.copyOf(reply.length)
                if (!isDnsResponseFor(response, query) || response.size < 4) {
                    false
                } else {
                    val responseCode = response[3].toInt() and 0x0f
                    responseCode == 0 || responseCode == 3 // NOERROR or NXDOMAIN proves the resolver answered.
                }
            }
        } catch (error: Exception) {
            Log.w(TAG, "End-to-end tunnel probe failed", error)
            false
        }
    }

    private fun makeDnsQuery(host: String, id: Int): ByteArray {
        val out = ByteArrayOutputStream()
        out.write((id ushr 8) and 0xff)
        out.write(id and 0xff)
        out.write(0x01) // recursion desired
        out.write(0x00)
        out.write(0); out.write(1) // QDCOUNT
        repeat(6) { out.write(0) }
        host.split('.').forEach { label ->
            val bytes = label.toByteArray(Charsets.US_ASCII)
            out.write(bytes.size)
            out.write(bytes)
        }
        out.write(0)
        out.write(0); out.write(1) // A
        out.write(0); out.write(1) // IN
        return out.toByteArray()
    }

    private fun servFail(query: ByteArray): ByteArray {
        if (query.size < 12) return byteArrayOf(0, 0, 0x80.toByte(), 2, 0, 0, 0, 0, 0, 0, 0, 0)
        val questionEnd = findQuestionEnd(query).coerceAtLeast(12).coerceAtMost(query.size)
        val response = query.copyOf(questionEnd)
        response[2] = ((query[2].toInt() and 0x7f) or 0x80).toByte()
        response[3] = 0x82.toByte() // RA + SERVFAIL
        response[6] = 0; response[7] = 0
        response[8] = 0; response[9] = 0
        response[10] = 0; response[11] = 0
        return response
    }

    private fun limitUdpResponse(response: ByteArray, maxLength: Int): ByteArray {
        if (response.size <= maxLength) return response
        val questionEnd = findQuestionEnd(response).coerceAtLeast(12).coerceAtMost(response.size)
        val truncated = response.copyOf(min(questionEnd, maxLength))
        if (truncated.size >= 12) {
            truncated[2] = (truncated[2].toInt() or 0x02).toByte() // TC bit
            truncated[6] = 0; truncated[7] = 0
            truncated[8] = 0; truncated[9] = 0
            truncated[10] = 0; truncated[11] = 0
        }
        return truncated
    }

    private fun findQuestionEnd(message: ByteArray): Int {
        if (message.size < 12) return message.size
        var offset = 12
        var labels = 0
        while (offset < message.size && labels++ < 128) {
            val length = message[offset].toInt() and 0xff
            if (length == 0) { offset++; break }
            if ((length and 0xc0) == 0xc0) { offset += 2; break }
            if (length > 63 || offset + 1 + length > message.size) return 12
            offset += 1 + length
        }
        if (offset + 4 > message.size) return 12
        return offset + 4
    }

    private fun rejectDnsOverTls(view: PacketView) {
        val incomingFlags = view.tcpFlags
        val hasAck = (incomingFlags and TCP_ACK) != 0
        val consumesSequence = view.payloadLength +
            (if ((incomingFlags and TCP_SYN) != 0) 1 else 0) +
            (if ((incomingFlags and TCP_FIN) != 0) 1 else 0)
        val sequence = if (hasAck) view.tcpAcknowledgement else 0L
        val acknowledgement = if (hasAck) 0L else seqAdd(view.tcpSequence, consumesSequence)
        val resetFlags = if (hasAck) TCP_RST else TCP_RST or TCP_ACK
        val packet = buildTcpPacket(
            view.ipVersion,
            view.destinationAddress,
            view.sourceAddress,
            view.destinationPort,
            view.sourcePort,
            sequence,
            acknowledgement,
            resetFlags,
            byteArrayOf()
        )
        writeTunPacket(packet)
    }

    private fun handleTcpPacket(view: PacketView, packet: ByteArray) {
        val key = TcpKey(view.sourceAddress.address.toHexString(), view.sourcePort, view.ipVersion)
        val flags = view.tcpFlags
        val isSyn = (flags and TCP_SYN) != 0
        val isAck = (flags and TCP_ACK) != 0
        val isFin = (flags and TCP_FIN) != 0
        val isRst = (flags and TCP_RST) != 0

        if (isRst) {
            tcpSessions.remove(key)?.closed = true
            return
        }

        if (isSyn) {
            val existing = tcpSessions[key]
            if (existing != null) {
                synchronized(existing) { sendSynAck(existing) }
                return
            }
            val initialServerSequence = random.nextInt().toLong() and 0xffffffffL
            val session = TcpSession(
                key,
                view.sourceAddress,
                view.destinationAddress,
                view.sourcePort,
                view.ipVersion,
                seqAdd(view.tcpSequence, 1),
                initialServerSequence,
                seqAdd(initialServerSequence, 1)
            )
            tcpSessions[key] = session
            sendSynAck(session)
            return
        }

        val session = tcpSessions[key] ?: return
        synchronized(session) {
            if (session.closed) return
            session.lastActivity = System.currentTimeMillis()
            val payload = if (view.payloadLength > 0) {
                packet.copyOfRange(view.payloadOffset, view.payloadOffset + view.payloadLength)
            } else byteArrayOf()

            if (payload.isNotEmpty()) {
                if (view.tcpSequence == session.clientNextSequence) {
                    session.requestBuffer.write(payload)
                    session.clientNextSequence = seqAdd(session.clientNextSequence, payload.size)
                    sendTcpAck(session)
                    if (!session.processing && !session.finished) {
                        val buffered = session.requestBuffer.toByteArray()
                        if (buffered.size >= 2) {
                            val dnsLength = readU16(buffered, 0)
                            if (dnsLength in 12..65535 && buffered.size >= dnsLength + 2) {
                                val query = buffered.copyOfRange(2, dnsLength + 2)
                                session.processing = true
                                submitForwarding {
                                    val response = try {
                                        val resolver = selectedDns ?: throw IOException("No DNS selected")
                                        forwardDnsOverTcp(query, resolver)
                                    } catch (error: Exception) {
                                        Log.w(TAG, "TCP DNS forwarding failed", error)
                                        servFail(query)
                                    }
                                    sendTcpDnsResponse(session, response)
                                }
                            }
                        }
                    }
                } else {
                    sendTcpAck(session)
                    if (session.finished && view.tcpSequence != session.clientNextSequence && session.cachedResponsePackets.isNotEmpty()) {
                        session.cachedResponsePackets.forEach(::writeTunPacket)
                    }
                }
            } else if (isAck && session.finished && session.cachedResponsePackets.isEmpty()) {
                session.lastActivity = System.currentTimeMillis()
            }

            if (isFin) {
                val finSequence = seqAdd(view.tcpSequence, payload.size)
                if (finSequence == session.clientNextSequence) {
                    session.clientNextSequence = seqAdd(session.clientNextSequence, 1)
                }
                sendTcpAck(session)
            }
        }
    }

    private fun sendSynAck(session: TcpSession) {
        val packet = buildTcpPacket(
            session.ipVersion,
            session.serverAddress,
            session.clientAddress,
            DNS_PORT,
            session.clientPort,
            session.initialServerSequence,
            session.clientNextSequence,
            TCP_SYN or TCP_ACK,
            byteArrayOf()
        )
        writeTunPacket(packet)
    }

    private fun sendTcpAck(session: TcpSession) {
        val packet = buildTcpPacket(
            session.ipVersion,
            session.serverAddress,
            session.clientAddress,
            DNS_PORT,
            session.clientPort,
            session.serverNextSequence,
            session.clientNextSequence,
            TCP_ACK,
            byteArrayOf()
        )
        writeTunPacket(packet)
    }

    private fun sendTcpDnsResponse(session: TcpSession, dnsResponse: ByteArray) {
        synchronized(session) {
            if (!running || session.closed) return
            val response = if (dnsResponse.size > 65535) dnsResponse.copyOf(65535) else dnsResponse
            val framed = ByteArray(response.size + 2)
            writeU16(framed, 0, response.size)
            System.arraycopy(response, 0, framed, 2, response.size)
            val packets = ArrayList<ByteArray>()
            var offset = 0
            while (offset < framed.size) {
                val chunkLength = min(1200, framed.size - offset)
                val chunk = framed.copyOfRange(offset, offset + chunkLength)
                val outgoing = buildTcpPacket(
                    session.ipVersion,
                    session.serverAddress,
                    session.clientAddress,
                    DNS_PORT,
                    session.clientPort,
                    session.serverNextSequence,
                    session.clientNextSequence,
                    TCP_PSH or TCP_ACK,
                    chunk
                )
                session.serverNextSequence = seqAdd(session.serverNextSequence, chunkLength)
                packets.add(outgoing)
                writeTunPacket(outgoing)
                offset += chunkLength
            }
            val fin = buildTcpPacket(
                session.ipVersion,
                session.serverAddress,
                session.clientAddress,
                DNS_PORT,
                session.clientPort,
                session.serverNextSequence,
                session.clientNextSequence,
                TCP_FIN or TCP_ACK,
                byteArrayOf()
            )
            session.serverNextSequence = seqAdd(session.serverNextSequence, 1)
            packets.add(fin)
            writeTunPacket(fin)
            session.cachedResponsePackets = packets
            session.processing = false
            session.finished = true
            session.lastActivity = System.currentTimeMillis()
        }
    }

    private fun expireTcpSessions() {
        val cutoff = System.currentTimeMillis() - SESSION_TIMEOUT_MS
        for (entry in tcpSessions.entries.toList()) {
            val session = entry.value
            if (session.lastActivity < cutoff) {
                session.closed = true
                tcpSessions.remove(entry.key)
            }
        }
    }

    private fun buildUdpPacket(
        ipVersion: Int,
        source: InetAddress,
        destination: InetAddress,
        sourcePort: Int,
        destinationPort: Int,
        payload: ByteArray
    ): ByteArray {
        val ipHeaderLength = if (ipVersion == 4) 20 else 40
        val udpLength = 8 + payload.size
        val packet = ByteArray(ipHeaderLength + udpLength)
        if (ipVersion == 4) {
            packet[0] = 0x45
            writeU16(packet, 2, packet.size)
            writeU16(packet, 4, random.nextInt(65536))
            writeU16(packet, 6, 0x4000)
            packet[8] = 64
            packet[9] = PROTOCOL_UDP.toByte()
            System.arraycopy(source.address, 0, packet, 12, 4)
            System.arraycopy(destination.address, 0, packet, 16, 4)
            writeU16(packet, 10, internetChecksum(packet, 0, 20))
        } else {
            packet[0] = 0x60
            writeU16(packet, 4, udpLength)
            packet[6] = PROTOCOL_UDP.toByte()
            packet[7] = 64
            System.arraycopy(source.address, 0, packet, 8, 16)
            System.arraycopy(destination.address, 0, packet, 24, 16)
        }
        val udpOffset = ipHeaderLength
        writeU16(packet, udpOffset, sourcePort)
        writeU16(packet, udpOffset + 2, destinationPort)
        writeU16(packet, udpOffset + 4, udpLength)
        writeU16(packet, udpOffset + 6, 0)
        System.arraycopy(payload, 0, packet, udpOffset + 8, payload.size)
        val udpSegment = packet.copyOfRange(udpOffset, packet.size)
        var checksum = transportChecksum(source.address, destination.address, PROTOCOL_UDP, udpSegment)
        if (checksum == 0) checksum = 0xffff
        writeU16(packet, udpOffset + 6, checksum)
        return packet
    }

    private fun buildTcpPacket(
        ipVersion: Int,
        source: InetAddress,
        destination: InetAddress,
        sourcePort: Int,
        destinationPort: Int,
        sequence: Long,
        acknowledgement: Long,
        flags: Int,
        payload: ByteArray
    ): ByteArray {
        val ipHeaderLength = if (ipVersion == 4) 20 else 40
        val tcpHeaderLength = 20
        val tcpLength = tcpHeaderLength + payload.size
        val packet = ByteArray(ipHeaderLength + tcpLength)
        if (ipVersion == 4) {
            packet[0] = 0x45
            writeU16(packet, 2, packet.size)
            writeU16(packet, 4, random.nextInt(65536))
            writeU16(packet, 6, 0x4000)
            packet[8] = 64
            packet[9] = PROTOCOL_TCP.toByte()
            System.arraycopy(source.address, 0, packet, 12, 4)
            System.arraycopy(destination.address, 0, packet, 16, 4)
            writeU16(packet, 10, internetChecksum(packet, 0, 20))
        } else {
            packet[0] = 0x60
            writeU16(packet, 4, tcpLength)
            packet[6] = PROTOCOL_TCP.toByte()
            packet[7] = 64
            System.arraycopy(source.address, 0, packet, 8, 16)
            System.arraycopy(destination.address, 0, packet, 24, 16)
        }
        val tcpOffset = ipHeaderLength
        writeU16(packet, tcpOffset, sourcePort)
        writeU16(packet, tcpOffset + 2, destinationPort)
        writeU32(packet, tcpOffset + 4, sequence)
        writeU32(packet, tcpOffset + 8, acknowledgement)
        packet[tcpOffset + 12] = 0x50
        packet[tcpOffset + 13] = flags.toByte()
        writeU16(packet, tcpOffset + 14, 65535)
        writeU16(packet, tcpOffset + 16, 0)
        writeU16(packet, tcpOffset + 18, 0)
        if (payload.isNotEmpty()) System.arraycopy(payload, 0, packet, tcpOffset + tcpHeaderLength, payload.size)
        val tcpSegment = packet.copyOfRange(tcpOffset, packet.size)
        writeU16(packet, tcpOffset + 16, transportChecksum(source.address, destination.address, PROTOCOL_TCP, tcpSegment))
        return packet
    }

    private fun transportChecksum(source: ByteArray, destination: ByteArray, protocol: Int, segment: ByteArray): Int {
        val pseudoLength = if (source.size == 4) 12 else 40
        val pseudo = ByteArray(pseudoLength + segment.size)
        if (source.size == 4) {
            System.arraycopy(source, 0, pseudo, 0, 4)
            System.arraycopy(destination, 0, pseudo, 4, 4)
            pseudo[8] = 0
            pseudo[9] = protocol.toByte()
            writeU16(pseudo, 10, segment.size)
        } else {
            System.arraycopy(source, 0, pseudo, 0, 16)
            System.arraycopy(destination, 0, pseudo, 16, 16)
            writeU32(pseudo, 32, segment.size.toLong())
            pseudo[39] = protocol.toByte()
        }
        System.arraycopy(segment, 0, pseudo, pseudoLength, segment.size)
        return internetChecksum(pseudo, 0, pseudo.size)
    }

    private fun internetChecksum(bytes: ByteArray, offset: Int, length: Int): Int {
        var sum = 0L
        var index = offset
        val end = offset + length
        while (index + 1 < end) {
            sum += ((bytes[index].toInt() and 0xff) shl 8) or (bytes[index + 1].toInt() and 0xff)
            index += 2
        }
        if (index < end) sum += (bytes[index].toInt() and 0xff) shl 8
        while ((sum ushr 16) != 0L) sum = (sum and 0xffffL) + (sum ushr 16)
        return sum.inv().toInt() and 0xffff
    }

    private fun writeTunPacket(packet: ByteArray) {
        if (!running) return
        synchronized(outputLock) {
            try {
                tunOutput?.write(packet)
                tunOutput?.flush()
            } catch (error: Exception) {
                if (running) Log.w(TAG, "Could not write response to TUN", error)
                Unit
            }
        }
    }

    private fun sendStatus(success: Boolean, dnsIp: String, message: String?) {
        val status = Intent(ACTION_STATUS).setPackage(packageName)
            .putExtra(EXTRA_DNS_IP, dnsIp)
            .putExtra(EXTRA_SUCCESS, success)
            .putExtra(EXTRA_MESSAGE, message ?: "")
        sendBroadcast(status)
    }

    private fun startForegroundCompat(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Gaming DNS connection", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val notification = makeNotification(text)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, makeNotification(text))
    }

    private fun makeNotification(text: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Gaming DNS")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun stopTunnel() {
        running = false
        packetThread?.interrupt()
        packetThread = null
        try { vpnInterface?.close() } catch (error: Exception) { Log.w(TAG, "Error closing TUN", error) }
        vpnInterface = null
        tunInput = null
        tunOutput = null
        packetExecutor?.shutdownNow()
        packetExecutor = null
        tcpSessions.values.forEach { it.closed = true }
        tcpSessions.clear()
        selectedDns = null
        activeDnsIp = null
    }

    override fun onRevoke() {
        val previousDns = activeDnsIp.orEmpty()
        stopTunnel()
        sendStatus(false, previousDns, "Android revoked VPN access or another VPN replaced this connection.")
        stopForegroundCompat()
        stopSelf()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopTunnel()
        stopForegroundCompat()
        super.onDestroy()
    }

    private fun readU16(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff)

    private fun readU32(bytes: ByteArray, offset: Int): Long =
        ((bytes[offset].toLong() and 0xff) shl 24) or
            ((bytes[offset + 1].toLong() and 0xff) shl 16) or
            ((bytes[offset + 2].toLong() and 0xff) shl 8) or
            (bytes[offset + 3].toLong() and 0xff)

    private fun writeU16(bytes: ByteArray, offset: Int, value: Int) {
        bytes[offset] = ((value ushr 8) and 0xff).toByte()
        bytes[offset + 1] = (value and 0xff).toByte()
    }

    private fun writeU32(bytes: ByteArray, offset: Int, value: Long) {
        bytes[offset] = ((value ushr 24) and 0xff).toByte()
        bytes[offset + 1] = ((value ushr 16) and 0xff).toByte()
        bytes[offset + 2] = ((value ushr 8) and 0xff).toByte()
        bytes[offset + 3] = (value and 0xff).toByte()
    }

    private fun seqAdd(sequence: Long, amount: Int): Long = (sequence + amount.toLong()) and 0xffffffffL

    private fun ByteArray.toHexString(): String = joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
}
