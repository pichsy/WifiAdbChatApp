package dev.local.adbtype.mobile.core

import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.ConnectException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NoRouteToHostException
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.Locale
import java.util.concurrent.Executors

/**
 * 局域网传输引擎（纯 JVM，不依赖 Android Xxx 类）：
 *  - UDP 52730 广播 + 监听，维护附近设备；
 *  - TCP 随机端口监听，处理握手 / 文字 / 文件；
 *  - 发送端每次发送动作新建一条 TCP，完成后 bye 并关闭；
 *  - 已配对 ID、好友、聊天记录都由 [LanStores] / [ChatStore] 持久化。
 *
 * 线程模型：发现/监听/接客各一个后台线程，发送串行在单独线程池里执行，
 * 状态变化通过 [LanEngineListener.onLanChanged] 通知 UI（实现方自己切主线程）。
 */
class LanEngine(
    private val stores: LanStores,
    private val receivedFilePublisher: ReceivedFilePublisher,
    private val deviceNameProvider: () -> String,
    private val listener: LanEngineListener,
    private val discoveryPort: Int = LanProtocol.DISCOVERY_PORT,
) {

    private val lock = Any()
    private val peers = LinkedHashMap<String, LanPeer>()
    private val friends = LinkedHashMap<String, LanFriend>()
    private val paired = LinkedHashSet<String>()
    private val chats = ChatStore(stores.baseDir)

    private var deviceId = ""
    private var deviceName = ""
    private var pairingCode = PairingCode.generate()
    private var selectedPeerId: String? = null
    private var statusText = "正在搜索局域网内的电脑…"
    private var statusKind = StatusKind.IDLE
    private var busy = false
    private var sendLabel = ""
    private var sendProgress = 0f
    private var pairingRequest: PairingRequest? = null
    private var discoveryError: String? = null

    @Volatile
    private var running = false

    @Volatile
    private var lastSendReportMs = 0L

    private var tcpServer: ServerSocket? = null
    private var tcpPort = 0
    private var udpReceiver: DatagramSocket? = null
    private var udpSender: DatagramSocket? = null
    private var acceptThread: Thread? = null
    private var discoveryThread: Thread? = null
    private var announceThread: Thread? = null
    private var pruneThread: Thread? = null
    private var discoveryGeneration = 0

    private val sendExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "lan-send").apply { isDaemon = true }
    }

    // ---------------------------------------------------------------- 生命周期

    fun start() {
        synchronized(lock) {
            if (running) return
            running = true
        }
        loadState()
        startTcpServer()
        startDiscovery()
        startPruneLoop()
        notifyChanged()
    }

    fun stop() {
        val wasRunning = synchronized(lock) {
            val previous = running
            running = false
            previous
        }
        if (!wasRunning) return
        synchronized(lock) { discoveryGeneration++ }
        closeQuietly(tcpServer)
        tcpServer = null
        closeQuietly(udpReceiver)
        udpReceiver = null
        closeQuietly(udpSender)
        udpSender = null
        acceptThread?.interrupt()
        discoveryThread?.interrupt()
        announceThread?.interrupt()
        pruneThread?.interrupt()
        acceptThread = null
        discoveryThread = null
        announceThread = null
        pruneThread = null
        sendExecutor.shutdownNow()
        persistFriends()
    }

    private fun loadState() {
        stores.ensureBaseDir()
        val loadedId = stores.deviceId()
        val loadedName = deviceNameProvider().ifBlank { "Android 设备" }
        val loadedPaired = stores.loadPaired()
        val loadedFriends = stores.loadFriends()
        val preload = LinkedHashSet<String>()
        synchronized(lock) {
            deviceId = loadedId
            deviceName = loadedName
            pairingCode = PairingCode.generate()
            paired.clear()
            paired.addAll(loadedPaired)
            friends.clear()
            for (friend in loadedFriends) friends[friend.id] = friend
            for (id in paired) {
                if (friends[id] == null) {
                    friends[id] = LanFriend(id, "已配对设备", "", 0, 0L)
                }
            }
            selectedPeerId = null
            statusText = "正在搜索局域网内的电脑…"
            statusKind = StatusKind.IDLE
            preload.addAll(paired)
            preload.addAll(friends.keys)
        }
        chats.preload(preload)
    }

    // ---------------------------------------------------------------- 状态快照

    fun snapshot(): LanSnapshot {
        val receiveLocationLabel = try {
            receivedFilePublisher.locationLabel
        } catch (e: Exception) {
            ""
        }
        return synchronized(lock) {
            val ids = LinkedHashSet<String>()
            ids.addAll(paired)
            ids.addAll(friends.keys)
            ids.addAll(peers.keys)
            LanSnapshot(
                deviceName = deviceName,
                deviceId = deviceId,
                pairingCode = pairingCode,
                nearby = peers.values
                    .filter { !paired.contains(it.id) }
                    .sortedBy { it.displayName.lowercase(Locale.ROOT) }
                    .map { it.copy() },
                friends = friends.values
                    .map { friendView(it) }
                    .sortedWith(compareByDescending<LanPeer> { it.online }.thenBy { it.displayName.lowercase(Locale.ROOT) }),
                pairedIds = LinkedHashSet(paired),
                conversations = ids.associateWith { peerId -> chats.messagesFor(peerId) },
                selectedPeerId = selectedPeerId,
                statusText = statusText,
                statusKind = statusKind,
                busy = busy,
                sendLabel = sendLabel,
                sendProgress = sendProgress,
                pairingRequest = pairingRequest,
                discoveryError = discoveryError,
                receiveLocationLabel = receiveLocationLabel,
            )
        }
    }

    // ---------------------------------------------------------------- UI 操作

    fun selectPeer(peerId: String?) {
        synchronized(lock) { selectedPeerId = peerId }
        notifyChanged()
    }

    fun currentPairingCode(): String = synchronized(lock) { pairingCode }

    /** 本机 TCP 监听端口（随机分配，通过 UDP 广播通告给对端）。0 表示监听启动失败。 */
    fun listeningPort(): Int = tcpPort

    /** 本机使用的 UDP 发现端口（生产环境固定 52730；单元测试可注入其它端口避免占用）。 */
    fun discoveryPortValue(): Int = discoveryPort

    fun deviceIdValue(): String = currentDeviceId()

    fun deviceNameValue(): String = currentDeviceName()

    fun regeneratePairingCode(): String {
        val code = PairingCode.generate()
        synchronized(lock) { pairingCode = code }
        setStatus("已换新配对码：" + code, StatusKind.SUCCESS)
        return code
    }

    fun setStatusMessage(text: String, kind: StatusKind) = setStatus(text, kind)

    fun dismissPairingRequest() {
        synchronized(lock) { pairingRequest = null }
        notifyChanged()
    }

    fun isBusy(): Boolean = synchronized(lock) { busy }

    fun clearConversation(peerId: String) {
        chats.clear(peerId)
        setStatus("已清空当前会话的聊天记录", StatusKind.SUCCESS)
    }

    fun unpair(peerId: String) {
        var removedName = ""
        synchronized(lock) {
            val friend = friends.remove(peerId)
            removedName = friend?.alias?.takeIf { it.isNotBlank() } ?: friend?.name.orEmpty()
            paired.remove(peerId)
        }
        stores.savePaired(pairedSnapshot())
        persistFriends()
        setStatus(if (removedName.isNotBlank()) "已取消与「" + removedName + "」的配对" else "已取消配对", StatusKind.SUCCESS)
    }

    fun restartDiscovery() {
        setStatus("正在重新搜索局域网内的设备…", StatusKind.IDLE)
        stopDiscoveryLoops()
        synchronized(lock) { peers.clear() }
        notifyChanged()
        startDiscovery()
    }

    // ---------------------------------------------------------------- 发送

    fun sendText(peerId: String, text: String, code: String?, callback: (SendResult) -> Unit) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) {
            callback(SendResult.Failure("先输入要发送的文字"))
            return
        }
        val peer = resolvePeer(peerId)
        if (peer == null) {
            callback(SendResult.Failure("找不到该设备，请重新搜索局域网"))
            return
        }
        if (!beginSend("文字")) {
            callback(SendResult.Failure("正在发送上一项，请稍候"))
            return
        }
        sendExecutor.execute {
            val result = try {
                performText(peer, text, code)
            } catch (e: Exception) {
                SendResult.Failure(describeIoError(e, peer))
            } finally {
                endSend()
            }
            deliver(callback, result)
        }
    }

    fun sendFiles(peerId: String, files: List<OutgoingFile>, code: String?, callback: (SendResult) -> Unit) {
        if (files.isEmpty()) {
            callback(SendResult.Failure("先选择文件"))
            return
        }
        val peer = resolvePeer(peerId)
        if (peer == null) {
            callback(SendResult.Failure("找不到该设备，请重新搜索局域网"))
            return
        }
        val label = if (files.size == 1) files[0].displayName else files.size.toString() + " 个文件"
        if (!beginSend(label)) {
            callback(SendResult.Failure("正在发送上一项，请稍候"))
            return
        }
        sendExecutor.execute {
            var result: SendResult = SendResult.Success
            try {
                var currentCode = code
                for (index in files.indices) {
                    val file = files[index]
                    reportSendProgress(index, files.size, 0L, maxOf(file.size, 1L), file.displayName)
                    result = performFile(peer, file, currentCode, index, files.size)
                    if (result !is SendResult.Success) break
                    currentCode = null
                }
            } catch (e: Exception) {
                result = SendResult.Failure(describeIoError(e, peer))
            } finally {
                endSend()
            }
            if (result is SendResult.Success) {
                val message = if (files.size > 1) {
                    "已把 " + files.size + " 个文件发送给 " + peer.displayName
                } else {
                    "已把「" + files[0].displayName + "」发送给 " + peer.displayName
                }
                setStatus(message, StatusKind.SUCCESS)
            }
            deliver(callback, result)
        }
    }

    /** 主动配对：只做握手，不发送内容。 */
    fun pairWith(peerId: String, code: String, callback: (SendResult) -> Unit) {
        val normalized = PairingCode.normalize(code)
        if (normalized == null) {
            callback(SendResult.Failure("配对码是 6 位数字"))
            return
        }
        val peer = resolvePeer(peerId)
        if (peer == null) {
            callback(SendResult.Failure("找不到该设备，请重新搜索局域网"))
            return
        }
        if (!beginSend("配对")) {
            callback(SendResult.Failure("正在发送上一项，请稍候"))
            return
        }
        sendExecutor.execute {
            val result = try {
                performPair(peer, normalized)
            } catch (e: Exception) {
                SendResult.Failure(describeIoError(e, peer))
            } finally {
                endSend()
            }
            deliver(callback, result)
        }
    }

    private fun performText(peer: LanPeer, text: String, code: String?): SendResult {
        val socket = try {
            openConnection(peer)
        } catch (e: Exception) {
            return SendResult.Failure(describeIoError(e, peer))
        }
        try {
            socket.soTimeout = LanProtocol.IO_TIMEOUT_MS
            val input = socket.getInputStream()
            val output = socket.getOutputStream()
            when (val outcome = handshake(peer, input, output, code)) {
                is HandshakeOutcome.Failure -> return SendResult.Failure(outcome.message)
                is HandshakeOutcome.NeedsPairing -> return SendResult.NeedsPairing(outcome.peerName)
                is HandshakeOutcome.Ok -> Unit
            }
            if (!LanFrame.writeFrame(output, LanProtocol.text(text))) {
                return SendResult.Failure("发送文字失败，对方没有确认")
            }
            val response = LanFrame.readFrame(input)
            if (response?.stringValue("type") != "ok") {
                return SendResult.Failure("发送文字失败，对方没有确认")
            }
            LanFrame.writeFrame(output, LanProtocol.bye())
            appendOutgoingText(peer, text)
            setStatus("已把文字发送给 " + peer.displayName, StatusKind.SUCCESS)
            return SendResult.Success
        } catch (e: Exception) {
            return SendResult.Failure(describeIoError(e, peer))
        } finally {
            closeQuietly(socket)
        }
    }

    private fun performFile(peer: LanPeer, file: OutgoingFile, code: String?, index: Int, count: Int): SendResult {
        if (file.size <= 0L) return SendResult.Failure("读不到文件：" + file.displayName)
        val socket = try {
            openConnection(peer)
        } catch (e: Exception) {
            return SendResult.Failure(describeIoError(e, peer))
        }
        try {
            socket.soTimeout = LanProtocol.IO_TIMEOUT_MS
            val input = socket.getInputStream()
            val output = socket.getOutputStream()
            when (val outcome = handshake(peer, input, output, code)) {
                is HandshakeOutcome.Failure -> return SendResult.Failure(outcome.message)
                is HandshakeOutcome.NeedsPairing -> return SendResult.NeedsPairing(outcome.peerName)
                is HandshakeOutcome.Ok -> Unit
            }
            if (!LanFrame.writeFrame(output, LanProtocol.file(file.displayName, file.size))) {
                return SendResult.Failure("发送文件信息失败")
            }
            val stream = try {
                FileInputStream(file.file)
            } catch (e: Exception) {
                return SendResult.Failure("读不到文件：" + file.displayName)
            }
            val watchdog = WriteWatchdog(socket)
            watchdog.start()
            try {
                stream.use {
                    var sent = 0L
                    val buffer = ByteArray(LanProtocol.FILE_CHUNK_BYTES)
                    while (sent < file.size) {
                        val want = minOf(buffer.size.toLong(), file.size - sent).toInt()
                        val read = it.read(buffer, 0, want)
                        if (read <= 0) return SendResult.Failure("读不到文件：" + file.displayName)
                        output.write(buffer, 0, read)
                        sent += read
                        watchdog.touch()
                        reportSendProgress(index, count, sent, file.size, file.displayName)
                    }
                }
            } finally {
                watchdog.stop()
            }
            val response = LanFrame.readFrame(input)
            if (response?.stringValue("type") != "ok") {
                return SendResult.Failure("对方没有确认收到文件")
            }
            LanFrame.writeFrame(output, LanProtocol.bye())
            appendOutgoingFile(peer, file)
            return SendResult.Success
        } catch (e: Exception) {
            return SendResult.Failure(describeIoError(e, peer))
        } finally {
            closeQuietly(socket)
        }
    }

    private fun performPair(peer: LanPeer, code: String): SendResult {
        val socket = try {
            openConnection(peer)
        } catch (e: Exception) {
            return SendResult.Failure(describeIoError(e, peer))
        }
        try {
            socket.soTimeout = LanProtocol.IO_TIMEOUT_MS
            val input = socket.getInputStream()
            val output = socket.getOutputStream()
            return when (val outcome = handshake(peer, input, output, code)) {
                is HandshakeOutcome.Ok -> {
                    LanFrame.writeFrame(output, LanProtocol.bye())
                    SendResult.Success
                }
                is HandshakeOutcome.NeedsPairing -> SendResult.Failure(LanProtocol.MSG_WRONG_CODE)
                is HandshakeOutcome.Failure -> SendResult.Failure(outcome.message)
            }
        } catch (e: Exception) {
            return SendResult.Failure(describeIoError(e, peer))
        } finally {
            closeQuietly(socket)
        }
    }

    private fun handshake(peer: LanPeer, input: InputStream, output: OutputStream, code: String?): HandshakeOutcome {
        val hello = LanProtocol.hello(currentDeviceId(), currentDeviceName(), code)
        if (!LanFrame.writeFrame(output, hello)) {
            return HandshakeOutcome.Failure(LanProtocol.MSG_NO_RESPONSE)
        }
        val response = LanFrame.readFrame(input)
            ?: return HandshakeOutcome.Failure(LanProtocol.MSG_NO_RESPONSE)
        val outcome = HandshakeInterpreter.interpret(response, peer.id, peer.displayName)
        if (outcome is HandshakeOutcome.Ok) {
            rememberPaired(outcome.peerId)
            updateFriend(outcome.peerId, outcome.peerName, peer.host, peer.port)
            synchronized(lock) { pairingRequest = null }
            notifyChanged()
        }
        return outcome
    }

    private fun openConnection(peer: LanPeer): Socket {
        if (peer.host.isBlank() || peer.port !in 1..65535) {
            throw IOException("设备当前不在线")
        }
        val socket = Socket()
        try {
            socket.tcpNoDelay = true
            socket.connect(InetSocketAddress(peer.host, peer.port), LanProtocol.CONNECT_TIMEOUT_MS)
            socket.soTimeout = LanProtocol.IO_TIMEOUT_MS
            return socket
        } catch (e: Exception) {
            closeQuietly(socket)
            throw e
        }
    }

    // ---------------------------------------------------------------- 接收

    private fun startTcpServer() {
        try {
            val server = ServerSocket(0)
            server.soTimeout = 1000
            tcpServer = server
            tcpPort = server.localPort
            val thread = Thread({ acceptLoop(server) }, "lan-tcp-accept")
            thread.isDaemon = true
            thread.start()
            acceptThread = thread
        } catch (e: Exception) {
            setStatus("无法启动本机 TCP 监听：" + (e.message ?: "未知错误"), StatusKind.ERROR)
            synchronized(lock) { discoveryError = "无法启动本机 TCP 监听，局域网传输不可用" }
            notifyChanged()
        }
    }

    private fun acceptLoop(server: ServerSocket) {
        while (running) {
            val socket = try {
                server.accept()
            } catch (e: SocketTimeoutException) {
                continue
            } catch (e: Exception) {
                if (!running) return
                continue
            }
            if (!running) {
                closeQuietly(socket)
                return
            }
            val thread = Thread({ handleIncoming(socket) }, "lan-tcp-in")
            thread.isDaemon = true
            thread.start()
        }
    }

    private fun handleIncoming(socket: Socket) {
        try {
            socket.soTimeout = LanProtocol.IO_TIMEOUT_MS
            val input = socket.getInputStream()
            val output = socket.getOutputStream()
            val hello = LanFrame.readFrame(input)
            val decision = PairingPolicy.evaluateHello(
                hello = hello,
                selfId = currentDeviceId(),
                currentCode = currentPairingCode(),
                pairedPeerIds = pairedSnapshot(),
            )
            val host = remoteHost(socket)
            when (decision) {
                is HelloDecision.Reject -> {
                    LanFrame.writeFrame(output, LanProtocol.error(decision.message))
                    return
                }
                is HelloDecision.NeedsPairing -> {
                    synchronized(lock) {
                        pairingRequest = PairingRequest(decision.peerId, decision.peerName)
                        statusText = "「" + decision.peerName + "」正在请求配对，把配对码 " + pairingCode + " 告诉对方"
                        statusKind = StatusKind.WARNING
                    }
                    notifyChanged()
                    LanFrame.writeFrame(output, LanProtocol.pairRequired(currentDeviceName()))
                    return
                }
                is HelloDecision.Accept -> {
                    if (!decision.alreadyPaired) rememberPaired(decision.peerId)
                    updateFriend(decision.peerId, decision.peerName, host, 0)
                    synchronized(lock) {
                        pairingRequest = null
                        if (selectedPeerId == null) selectedPeerId = decision.peerId
                    }
                    if (!LanFrame.writeFrame(output, LanProtocol.helloOk(currentDeviceId(), currentDeviceName()))) {
                        return
                    }
                    notifyChanged()
                    receiveLoop(input, output, decision.peerId, decision.peerName)
                }
            }
        } catch (e: Exception) {
            // 单条连接异常只影响本次连接，服务继续保持监听
        } finally {
            closeQuietly(socket)
        }
    }

    private fun receiveLoop(input: InputStream, output: OutputStream, peerId: String, peerName: String) {
        while (running) {
            val frame = LanFrame.readFrame(input) ?: return
            when (frame.stringValue("type")) {
                "text" -> {
                    val text = frame.stringValue("text") ?: return
                    synchronized(lock) {
                        chats.append(
                            peerId,
                            ChatMessage(
                                direction = ChatDirection.INCOMING,
                                peerName = peerName,
                                kind = ChatKind.TEXT,
                                text = text,
                            ),
                        )
                    }
                    setStatus("收到 " + peerName + " 发来的文字", StatusKind.SUCCESS)
                    if (!LanFrame.writeFrame(output, LanProtocol.ok())) return
                }
                "file" -> {
                    val name = frame.stringValue("name") ?: return
                    val size = frame.longValue("size") ?: return
                    if (size < 0L) return
                    setStatus("正在接收 " + peerName + " 发来的「" + name + "」…", StatusKind.IDLE)
                    val saved = receiveFile(input, name, size)
                    if (saved == null) {
                        LanFrame.writeFrame(output, LanProtocol.error(LanProtocol.MSG_SAVE_FAILED))
                        return
                    }
                    synchronized(lock) {
                        chats.append(
                            peerId,
                            ChatMessage(
                                direction = ChatDirection.INCOMING,
                                peerName = peerName,
                                kind = ChatKind.FILE,
                                fileName = saved.fileName,
                                filePath = saved.filePath,
                                fileUri = saved.fileUri,
                                fileSize = size,
                            ),
                        )
                    }
                    setStatus("已保存到 " + saved.locationLabel + "/" + saved.fileName, StatusKind.SUCCESS)
                    if (!LanFrame.writeFrame(output, LanProtocol.ok())) return
                }
                "bye" -> return
                else -> return
            }
            notifyChanged()
        }
    }

    private fun receiveFile(input: InputStream, rawName: String, size: Long): ReceivedFile? {
        val safeName = FileNames.sanitizeIncoming(rawName) ?: return null
        var lastReport = 0L
        return try {
            receivedFilePublisher.save(safeName, size, input) { written ->
                val now = System.currentTimeMillis()
                if (size > 0 && now - lastReport > 300) {
                    lastReport = now
                    val percent = (written * 100 / size).toInt()
                    setStatus("正在接收「" + safeName + "」" + percent + "%", StatusKind.IDLE)
                }
            }
        } catch (e: Exception) {
            null
        }
    }

    // ---------------------------------------------------------------- 发现

    private fun startDiscovery() {
        val generation = synchronized(lock) {
            discoveryGeneration++
            discoveryGeneration
        }
        try {
            val receiver = DatagramSocket(null)
            receiver.reuseAddress = true
            receiver.broadcast = true
            receiver.bind(InetSocketAddress(discoveryPort))
            receiver.soTimeout = 1000
            udpReceiver = receiver
            synchronized(lock) { discoveryError = null }
            val thread = Thread({ discoveryLoop(receiver, generation) }, "lan-udp-recv")
            thread.isDaemon = true
            thread.start()
            discoveryThread = thread
        } catch (e: Exception) {
            synchronized(lock) {
                discoveryError = "端口 " + discoveryPort + " 被占用，无法启动局域网发现"
            }
            notifyChanged()
        }
        val sender = try {
            DatagramSocket().apply { broadcast = true }
        } catch (e: Exception) {
            null
        }
        if (sender != null) {
            udpSender = sender
            val thread = Thread({ announceLoop(sender, generation) }, "lan-udp-announce")
            thread.isDaemon = true
            thread.start()
            announceThread = thread
        }
        notifyChanged()
    }

    private fun stopDiscoveryLoops() {
        synchronized(lock) { discoveryGeneration++ }
        closeQuietly(udpReceiver)
        udpReceiver = null
        closeQuietly(udpSender)
        udpSender = null
        discoveryThread?.interrupt()
        announceThread?.interrupt()
        discoveryThread = null
        announceThread = null
    }

    private fun isCurrentDiscovery(generation: Int): Boolean = synchronized(lock) {
        running && discoveryGeneration == generation
    }

    private fun discoveryLoop(socket: DatagramSocket, generation: Int) {
        val buffer = ByteArray(8192)
        while (running && isCurrentDiscovery(generation)) {
            val packet = DatagramPacket(buffer, buffer.size)
            try {
                socket.receive(packet)
            } catch (e: SocketTimeoutException) {
                continue
            } catch (e: Exception) {
                if (!running || !isCurrentDiscovery(generation)) return
                continue
            }
            val payload = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
            val announcement = AnnouncementParser.parse(payload, currentDeviceId()) ?: continue
            val host = packet.address?.hostAddress ?: continue
            handleAnnouncement(announcement, normalizeHost(host))
        }
    }

    private fun announceLoop(sender: DatagramSocket, generation: Int) {
        var tick = 0
        while (running && isCurrentDiscovery(generation)) {
            try {
                val payload = LanProtocol.announcement(currentDeviceId(), currentDeviceName(), tcpPort)
                if (payload != null) {
                    sendDatagram(sender, payload, "255.255.255.255")
                    sendDatagram(sender, payload, "127.0.0.1")
                    if (tick % 2 == 0) {
                        for (host in knownHosts()) sendDatagram(sender, payload, host)
                    }
                }
            } catch (e: Exception) {
                // 单次广播失败不影响后续心跳
            }
            tick++
            if (!sleepQuietly(LanProtocol.ANNOUNCE_INTERVAL_MS)) return
        }
    }

    private fun sendDatagram(sender: DatagramSocket, payload: ByteArray, host: String) {
        try {
            val address = InetAddress.getByName(host)
            sender.send(DatagramPacket(payload, payload.size, address, discoveryPort))
        } catch (e: Exception) {
            // 忽略单个地址的失败（例如广播被系统拦截）
        }
    }

    private fun knownHosts(): Set<String> = synchronized(lock) {
        val hosts = LinkedHashSet<String>()
        for (peer in peers.values) if (peer.host.isNotBlank()) hosts.add(peer.host)
        for (friend in friends.values) if (friend.host.isNotBlank()) hosts.add(friend.host)
        hosts
    }

    private fun handleAnnouncement(announcement: LanAnnouncement, host: String) {
        val now = System.currentTimeMillis()
        var becameOnline: String? = null
        var changedFriend = false
        synchronized(lock) {
            val existing = peers[announcement.deviceId]
            if (existing == null) {
                peers[announcement.deviceId] = LanPeer(
                    id = announcement.deviceId,
                    name = announcement.name,
                    host = host,
                    port = announcement.port,
                    lastSeenMillis = now,
                    online = true,
                )
                becameOnline = announcement.name
            } else {
                if (!existing.online) becameOnline = announcement.name
                existing.name = announcement.name
                existing.host = host
                existing.port = announcement.port
                existing.lastSeenMillis = now
                existing.online = true
            }
            val friend = friends[announcement.deviceId]
            if (friend != null) {
                if (friend.name != announcement.name) {
                    friend.name = announcement.name
                    changedFriend = true
                }
                if (friend.host != host) {
                    friend.host = host
                    changedFriend = true
                }
                if (friend.port != announcement.port) {
                    friend.port = announcement.port
                    changedFriend = true
                }
                friend.lastSeenMillis = now
            }
            if (becameOnline != null) {
                val displayName = announcement.name
                statusText = if (paired.contains(announcement.deviceId)) {
                    "「" + displayName + "」已上线，可以直接发消息"
                } else {
                    "发现「" + displayName + "」"
                }
                statusKind = if (paired.contains(announcement.deviceId)) StatusKind.SUCCESS else StatusKind.IDLE
            }
        }
        if (changedFriend) persistFriends()
        notifyChanged()
    }

    private fun startPruneLoop() {
        val thread = Thread({
            while (running) {
                if (!sleepQuietly(LanProtocol.PRUNE_INTERVAL_MS)) return@Thread
                pruneOfflinePeers()
            }
        }, "lan-prune")
        thread.isDaemon = true
        thread.start()
        pruneThread = thread
    }

    private fun pruneOfflinePeers() {
        val now = System.currentTimeMillis()
        var changed = false
        var offlineName: String? = null
        synchronized(lock) {
            val expiredIds = peers.values
                .filter { now - it.lastSeenMillis > LanProtocol.OFFLINE_AFTER_MS }
                .map { it.id }
            for (id in expiredIds) {
                val removed = peers.remove(id) ?: continue
                changed = true
                if (paired.contains(id)) offlineName = removed.displayName
            }
            val name = offlineName
            if (name != null) {
                statusText = "「" + name + "」已离线，等对方设备重新出现后可继续发送"
                statusKind = StatusKind.WARNING
            }
        }
        if (changed) notifyChanged()
    }

    // ---------------------------------------------------------------- 内部工具

    private fun resolvePeer(peerId: String): LanPeer? = synchronized(lock) {
        val live = peers[peerId]
        if (live != null) return@synchronized live.copy()
        val friend = friends[peerId]
        if (friend != null) {
            return@synchronized LanPeer(
                id = friend.id,
                name = friend.name,
                host = friend.host,
                port = friend.port,
                lastSeenMillis = friend.lastSeenMillis,
                online = false,
                alias = friend.alias,
            )
        }
        null
    }

    private fun friendView(friend: LanFriend): LanPeer {
        val live = peers[friend.id]
        return LanPeer(
            id = friend.id,
            name = friend.name,
            host = live?.host ?: friend.host,
            port = live?.port ?: friend.port,
            lastSeenMillis = maxOf(friend.lastSeenMillis, live?.lastSeenMillis ?: 0L),
            online = live != null,
            alias = friend.alias,
        )
    }

    private fun rememberPaired(peerId: String) {
        var newlyPaired = false
        synchronized(lock) {
            newlyPaired = paired.add(peerId)
            if (friends[peerId] == null) {
                val live = peers[peerId]
                friends[peerId] = LanFriend(
                    id = peerId,
                    name = live?.name ?: "已配对设备",
                    host = live?.host ?: "",
                    port = live?.port ?: 0,
                    lastSeenMillis = System.currentTimeMillis(),
                )
            }
        }
        if (newlyPaired) {
            stores.savePaired(pairedSnapshot())
            persistFriends()
            notifyChanged()
        }
    }

    private fun updateFriend(peerId: String, name: String, host: String, port: Int) {
        var changed = false
        synchronized(lock) {
            val friend = friends[peerId] ?: return
            if (name.isNotBlank() && friend.name != name) {
                friend.name = name
                changed = true
            }
            if (host.isNotBlank() && friend.host != host) {
                friend.host = host
                changed = true
            }
            if (port in 1..65535 && friend.port != port) {
                friend.port = port
                changed = true
            }
            if (changed) friend.lastSeenMillis = System.currentTimeMillis()
        }
        if (changed) persistFriends()
    }

    private fun persistFriends() {
        val snapshot: List<LanFriend>
        synchronized(lock) {
            snapshot = friends.values.toList()
        }
        stores.saveFriends(snapshot)
    }

    private fun pairedSnapshot(): Set<String> = synchronized(lock) { LinkedHashSet(paired) }

    private fun appendOutgoingText(peer: LanPeer, text: String) {
        synchronized(lock) {
            chats.append(
                peer.id,
                ChatMessage(
                    direction = ChatDirection.OUTGOING,
                    peerName = peer.displayName,
                    kind = ChatKind.TEXT,
                    text = text,
                ),
            )
        }
    }

    private fun appendOutgoingFile(peer: LanPeer, file: OutgoingFile) {
        synchronized(lock) {
            chats.append(
                peer.id,
                ChatMessage(
                    direction = ChatDirection.OUTGOING,
                    peerName = peer.displayName,
                    kind = ChatKind.FILE,
                    fileName = file.displayName,
                    filePath = file.file.absolutePath,
                    fileSize = file.size,
                ),
            )
        }
    }

    private fun beginSend(label: String): Boolean {
        synchronized(lock) {
            if (busy) return false
            busy = true
            sendLabel = label
            sendProgress = 0f
        }
        notifyChanged()
        return true
    }

    private fun endSend() {
        synchronized(lock) {
            busy = false
            sendLabel = ""
            sendProgress = 0f
        }
        notifyChanged()
    }

    private fun reportSendProgress(index: Int, count: Int, sent: Long, total: Long, fileName: String) {
        val now = System.currentTimeMillis()
        if (now - lastSendReportMs < 120 && sent < total) return
        lastSendReportMs = now
        val fileFraction = if (total > 0L) sent.toFloat() / total.toFloat() else 0f
        val overall = if (count <= 1) fileFraction else (index + fileFraction) / count.toFloat()
        synchronized(lock) {
            sendProgress = overall.coerceIn(0f, 1f)
            sendLabel = if (count > 1) {
                (index + 1).toString() + "/" + count + " " + fileName
            } else {
                fileName
            }
        }
        notifyChanged()
    }

    private fun setStatus(text: String, kind: StatusKind) {
        synchronized(lock) {
            statusText = text
            statusKind = kind
        }
        notifyChanged()
    }

    private fun notifyChanged() {
        try {
            listener.onLanChanged()
        } catch (e: Exception) {
            // UI 回调异常不能影响网络线程
        }
    }

    private fun deliver(callback: (SendResult) -> Unit, result: SendResult) {
        try {
            callback(result)
        } catch (e: Exception) {
            // 忽略 UI 回调异常
        }
    }

    private fun currentDeviceId(): String = synchronized(lock) { deviceId }

    private fun currentDeviceName(): String = synchronized(lock) { deviceName }

    private fun remoteHost(socket: Socket): String {
        val host = try {
            socket.inetAddress?.hostAddress ?: ""
        } catch (e: Exception) {
            ""
        }
        return normalizeHost(host)
    }

    private fun normalizeHost(host: String): String {
        if (host.startsWith("::ffff:")) return host.removePrefix("::ffff:")
        return host
    }

    private fun describeIoError(error: Throwable, peer: LanPeer): String {
        if (peer.host.isBlank() || peer.port !in 1..65535) {
            return "「" + peer.displayName + "」当前不在线，请等对方设备重新出现后再发送"
        }
        return when (error) {
            is SocketTimeoutException -> LanProtocol.MSG_NO_RESPONSE
            is ConnectException, is NoRouteToHostException ->
                "连不上「" + peer.displayName + "」，请确认两台设备在同一局域网、对方应用已打开"
            is IOException -> "网络连接中断，请确认两台设备还在同一局域网"
            else -> "发送失败：" + (error.message ?: "未知错误")
        }
    }

    private fun sleepQuietly(millis: Long): Boolean {
        try {
            Thread.sleep(millis)
            return true
        } catch (e: InterruptedException) {
            return false
        }
    }

    private fun closeQuietly(closeable: java.io.Closeable?) {
        try {
            closeable?.close()
        } catch (e: Exception) {
            // 忽略关闭异常
        }
    }

    private fun closeQuietly(socket: Socket?) {
        try {
            socket?.close()
        } catch (e: Exception) {
            // 忽略关闭异常
        }
    }

    private fun closeQuietly(server: ServerSocket?) {
        try {
            server?.close()
        } catch (e: Exception) {
            // 忽略关闭异常
        }
    }

    private fun closeQuietly(socket: DatagramSocket?) {
        try {
            socket?.close()
        } catch (e: Exception) {
            // 忽略关闭异常
        }
    }

    /** 写超时看门狗：文件传输时如果 30 秒没有任何进展，关闭 socket 让写操作抛异常。 */
    private class WriteWatchdog(private val socket: Socket) {
        @Volatile
        private var lastActivity = System.currentTimeMillis()

        private var thread: Thread? = null

        fun start() {
            val watchdog = Thread({
                while (!socket.isClosed) {
                    try {
                        Thread.sleep(1000)
                    } catch (e: InterruptedException) {
                        return@Thread
                    }
                    if (System.currentTimeMillis() - lastActivity > LanProtocol.IO_TIMEOUT_MS) {
                        closeQuietly(socket)
                        return@Thread
                    }
                }
            }, "lan-write-watchdog")
            watchdog.isDaemon = true
            watchdog.start()
            thread = watchdog
        }

        fun touch() {
            lastActivity = System.currentTimeMillis()
        }

        fun stop() {
            thread?.interrupt()
            thread = null
        }

        private fun closeQuietly(target: Socket?) {
            try {
                target?.close()
            } catch (e: Exception) {
                // 忽略
            }
        }
    }
}
