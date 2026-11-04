import Foundation
import Combine
import Network
import UIKit
import Darwin

/// 配对鉴权快照：后台接收连接时读取（配对集合与当前 6 位配对码）。
struct PairingAuthSnapshot {
    let paired: Set<String>
    let code: String
}

/// 局域网传输核心：
/// - UDP 52730 广播发现（含 127.0.0.1，方便同机联调）；
/// - TCP 随机端口监听，接收文字 / 文件；
/// - 6 位配对码握手、已配对 ID 持久化；
/// - 每台电脑独立聊天记录、好友名册持久化。
///
/// 线程模型：界面状态（@Published）只在主线程更新；socket 操作在 netQueue / sendQueue；
/// 后台线程统一通过 onMain 或 DispatchQueue.main.async 更新界面。
final class LANModel: ObservableObject {
    // MARK: - 常量

    static let appTag = LinkProtocol.appTag
    static let protocolVersion = LinkProtocol.version
    static let discoveryPort = LinkProtocol.discoveryPort

    // MARK: - 界面状态

    @Published private(set) var peers: [LANPeer] = []
    /// 已配对电脑名册：从 friends.json 恢复，离线也保留。
    @Published private(set) var friends: [LANPeer] = []
    /// 每台电脑独立的聊天记录：key = 设备 ID。
    @Published private(set) var conversations: [String: [LANMessage]] = [:]
    @Published private(set) var deviceName: String
    @Published private(set) var pairingCode: String
    @Published private(set) var pairedCount: Int
    @Published private(set) var pendingPairName: String?
    @Published private(set) var pendingPairPeerID: String?
    @Published private(set) var statusText = "正在启动局域网发现…"
    @Published private(set) var statusKind: LANStatusKind = .idle
    @Published private(set) var busy = false
    @Published private(set) var sendProgress: Double = 0
    @Published private(set) var activeSendLabel = ""
    @Published private(set) var receivingLabel: String?
    @Published private(set) var serverReady = false
    @Published private(set) var localNetworkBlocked = false
    @Published private(set) var showDiscoveryHint = false

    /// 配对弹窗状态（界面绑定为 sheet）。
    @Published var pairingPrompt: PairingPrompt?

    // MARK: - 身份与存储

    let deviceID: String
    /// 收到文件的目录（Documents/Downloads，「文件」App 可见）。
    let receiveDirectory: URL
    /// 旧版本接收目录（Documents/Received），启动时迁移到 receiveDirectory。
    let legacyReceivedDirectory: URL
    let friendStore: FriendStore
    let chatStore: ChatStore
    private let defaults: UserDefaults

    // MARK: - 网络

    let netQueue = DispatchQueue(label: "dev.local.adbtype.mobile.net", qos: .utility)
    let sendQueue = DispatchQueue(label: "dev.local.adbtype.mobile.send", qos: .userInitiated)

    private var udpRecvFD: Int32 = -1
    private var udpSendFD: Int32 = -1
    private var tcpListenFD: Int32 = -1
    private var udpSource: DispatchSourceRead?
    private var tcpSource: DispatchSourceRead?
    private var announceTimer: DispatchSourceTimer?
    private var pruneTimer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var foregroundObserver: NSObjectProtocol?
    private var lastPathSignature: String?
    private var tcpPort: UInt16 = 0
    private var started = false
    private var startTime = Date()
    private var lastRestartAt = Date.distantPast
    private var hasReceivedAnnouncement = false

    // MARK: - 配对状态（后台线程也会读，用锁保护）

    let pairLock = NSLock()
    var pairedIDs: Set<String>
    var authCode: String

    // MARK: - 单播心跳地址（netQueue 读取，主线程更新）

    private let hostLock = NSLock()
    private var heartbeatHosts: Set<String> = []

    /// 配对成功后需要自动补发的内容（仅主线程访问）。
    var pendingPairBody: PendingSendBody?
    /// 弹配对框时的对方快照：附近设备刚好掉线时仍能按上次地址发起配对（仅主线程访问）。
    var pairingPeerSnapshot: LANPeer?

    // MARK: - 初始化

    init(defaults: UserDefaults = .standard,
         friendStore: FriendStore = FriendStore(),
         chatStore: ChatStore = ChatStore(),
         receivedDirectory: URL = AppDirectories.receivedDirectory,
         legacyReceivedDirectory: URL = AppDirectories.legacyReceivedDirectory,
         overrideDeviceName: String? = nil) {
        self.defaults = defaults
        self.friendStore = friendStore
        self.chatStore = chatStore
        self.receiveDirectory = receivedDirectory
        self.legacyReceivedDirectory = legacyReceivedDirectory
        self.deviceID = DeviceIdentity.loadOrCreateDeviceID(defaults: defaults)
        let rawName = (overrideDeviceName ?? UIDevice.current.name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.deviceName = rawName.isEmpty ? "iPhone" : rawName
        let initialCode = DeviceIdentity.makePairingCode()
        self.pairingCode = initialCode
        self.authCode = initialCode
        self.pairedIDs = []
        self.pairedCount = 0
        self.friends = []
        self.conversations = [:]

        AppDirectories.ensureDirectories()
        // 旧版本 Documents/Received → Documents/Downloads，并把聊天记录里的旧路径改到新位置。
        let migratedFiles = AppDirectories.migrateLegacyReceivedFiles(legacyDirectory: legacyReceivedDirectory,
                                                                      destination: receivedDirectory)
        let loadedPaired = friendStore.loadPairedIDs()
        self.pairedIDs = loadedPaired
        self.pairedCount = loadedPaired.count
        self.friends = friendStore.loadFriends(pairedIDs: loadedPaired)
        self.conversations = chatStore.loadAll()
        self.migrateLegacyChatPaths(migratedFiles)
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        pathMonitor?.cancel()
        pruneTimer?.invalidate()
        announceTimer?.cancel()
        udpSource?.cancel()
        tcpSource?.cancel()
        if udpRecvFD >= 0 { close(udpRecvFD) }
        if udpSendFD >= 0 { close(udpSendFD) }
        if tcpListenFD >= 0 { close(tcpListenFD) }
    }

    // MARK: - 生命周期

    /// 启动发现与监听（幂等，由界面在任务里调用）。
    func start() {
        onMain { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.startTime = Date()
            _ = Darwin.signal(SIGPIPE, SIG_IGN)
            self.netQueue.async { [weak self] in
                self?.openSockets()
            }

            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let signature = "\(path.status) " + path.availableInterfaces.map(\.name).joined(separator: ",")
                guard let previous = self.lastPathSignature else {
                    self.lastPathSignature = signature
                    return
                }
                guard signature != previous else { return }
                self.lastPathSignature = signature
                guard path.status == .satisfied else { return }
                self.scheduleRestart(reason: "网络已切换，正在自动重连…")
            }
            monitor.start(queue: self.netQueue)
            self.pathMonitor = monitor

            self.pruneTimer = Timer.scheduledTimer(withTimeInterval: LinkProtocol.pruneInterval,
                                                   repeats: true) { [weak self] _ in
                self?.refreshPeerPresence()
            }

            self.foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main) { [weak self] _ in
                    self?.handleAppBecameActive()
                }
        }
    }

    /// 回到前台：网络状态可能已变化，立刻广播一次心跳，必要时重建套接字。
    func handleAppBecameActive() {
        guard started else { return }
        netQueue.async { [weak self] in
            guard let self else { return }
            if self.udpRecvFD < 0 || self.udpSendFD < 0 || self.tcpListenFD < 0 {
                self.scheduleRestart(reason: "正在重新连接局域网的电脑…")
                return
            }
            self.announce()
        }
    }

    /// 手动「重新搜索」：重建 UDP / TCP 套接字并广播。
    func refreshDiscovery() {
        scheduleRestart(reason: "正在重新搜索局域网的电脑…")
    }

    private func scheduleRestart(reason: String) {
        setStatus(.idle, reason)
        netQueue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastRestartAt) >= 2 else { return }
            self.lastRestartAt = now
            self.teardownSockets()
            self.openSockets()
        }
    }

    // MARK: - 套接字

    private func teardownSockets() {
        announceTimer?.cancel()
        announceTimer = nil
        udpSource?.cancel()
        udpSource = nil
        tcpSource?.cancel()
        tcpSource = nil
        if udpRecvFD >= 0 {
            close(udpRecvFD)
            udpRecvFD = -1
        }
        if udpSendFD >= 0 {
            close(udpSendFD)
            udpSendFD = -1
        }
        if tcpListenFD >= 0 {
            close(tcpListenFD)
            tcpListenFD = -1
        }
        tcpPort = 0
        onMain { [weak self] in
            self?.serverReady = false
        }
    }

    private func openSockets() {
        // UDP 接收：SO_REUSEADDR + SO_REUSEPORT，尽量与其它实例共用 52730。
        let recvFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard recvFD >= 0 else {
            reportNetworkFailure("无法创建局域网套接字，请重启 App 再试")
            return
        }
        var reuse: Int32 = 1
        setsockopt(recvFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(recvFD, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var recvAddr = sockaddr_in()
        recvAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        recvAddr.sin_family = sa_family_t(AF_INET)
        recvAddr.sin_port = LinkProtocol.discoveryPort.bigEndian
        recvAddr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &recvAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(recvFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(recvFD)
            reportNetworkFailure("端口 \(LinkProtocol.discoveryPort) 被占用，无法启动局域网发现")
            return
        }
        udpRecvFD = recvFD
        let udpSrc = DispatchSource.makeReadSource(fileDescriptor: recvFD, queue: netQueue)
        udpSrc.setEventHandler { [weak self] in
            self?.readDiscoveryPackets()
        }
        udpSrc.resume()
        udpSource = udpSrc

        // UDP 发送（广播）
        let sendFD = socket(AF_INET, SOCK_DGRAM, 0)
        if sendFD >= 0 {
            var broadcast: Int32 = 1
            setsockopt(sendFD, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
        }
        udpSendFD = sendFD

        // TCP 监听：随机端口，随广播一起发布
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            reportNetworkFailure("无法创建 TCP 监听，请重启 App 再试")
            return
        }
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var listenAddr = sockaddr_in()
        listenAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        listenAddr.sin_family = sa_family_t(AF_INET)
        listenAddr.sin_port = 0
        listenAddr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let listenBound = withUnsafePointer(to: &listenAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard listenBound == 0, listen(listenFD, 8) == 0 else {
            close(listenFD)
            reportNetworkFailure("无法开始监听传输连接，请重启 App 再试")
            return
        }
        let listenFlags = fcntl(listenFD, F_GETFL, 0)
        _ = fcntl(listenFD, F_SETFL, listenFlags | O_NONBLOCK)

        var actualAddr = sockaddr_in()
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actualAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &actualLen)
            }
        }
        tcpPort = UInt16(bigEndian: actualAddr.sin_port)
        tcpListenFD = listenFD

        let tcpSrc = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: netQueue)
        tcpSrc.setEventHandler { [weak self] in
            self?.acceptClients()
        }
        tcpSrc.resume()
        tcpSource = tcpSrc

        let timer = DispatchSource.makeTimerSource(queue: netQueue)
        timer.schedule(deadline: .now() + 0.2, repeating: LinkProtocol.announceInterval)
        timer.setEventHandler { [weak self] in
            self?.announce()
        }
        timer.resume()
        announceTimer = timer

        onMain { [weak self] in
            guard let self else { return }
            self.serverReady = true
            self.statusKind = .idle
            self.statusText = self.friends.isEmpty
                ? "本机已上线，正在查找附近的电脑…"
                : "本机已上线，正在连接已配对的电脑…"
        }
    }

    private func reportNetworkFailure(_ message: String) {
        onMain { [weak self] in
            guard let self else { return }
            self.serverReady = false
            self.statusKind = .failure
            self.statusText = message
        }
    }

    private func acceptClients() {
        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(tcpListenFD, $0, &clientLen)
                }
            }
            if client < 0 { break }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            // accept 出来的 socket 会继承监听端的 O_NONBLOCK，后续按阻塞 + 30 秒超时读写。
            let clientFlags = fcntl(client, F_GETFL, 0)
            _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK)
            SocketIO.setIODeadline(client, seconds: Int(LinkProtocol.ioTimeout))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(client)
            }
        }
    }

    // MARK: - 广播与发现

    func announcementPayload() -> Data? {
        guard tcpPort != 0 else { return nil }
        let payload = LinkMessages.announce(id: deviceID, name: deviceName, port: tcpPort)
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private func announce() {
        guard udpSendFD >= 0, let data = announcementPayload() else { return }
        sendPacket(data, host: "255.255.255.255")
        // 本机回环：方便 iOS 模拟器 / 同一台电脑上的多个实例联调。
        sendPacket(data, host: "127.0.0.1")

        hostLock.lock()
        let hosts = heartbeatHosts
        hostLock.unlock()
        for host in hosts where !host.isEmpty {
            sendPacket(data, host: host)
        }
    }

    private func sendPacket(_ data: Data, host: String) {
        guard udpSendFD >= 0 else { return }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = LinkProtocol.discoveryPort.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                data.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return sendto(udpSendFD, base, data.count, 0, sockPtr,
                                  socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if result < 0 {
            let code = errno
            if code == EACCES || code == EPERM {
                flagLocalNetworkBlocked()
            }
        }
    }

    private func flagLocalNetworkBlocked() {
        onMain { [weak self] in
            guard let self, !self.localNetworkBlocked else { return }
            self.localNetworkBlocked = true
            self.statusKind = .failure
            self.statusText = "无法访问本地网络：请到 设置 → 隐私与安全性 → 本地网络 允许「文件互传助手」"
        }
    }

    private func readDiscoveryPackets() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var fromAddr = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let received = withUnsafeMutablePointer(to: &fromAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                recvfrom(udpRecvFD, &buffer, buffer.count, 0, sockPtr, &fromLen)
            }
        }
        guard received > 0 else { return }
        let data = Data(buffer[0..<received])
        guard let packet = DiscoveryPacket.parse(data, localDeviceID: deviceID) else { return }

        var hostChars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var address = fromAddr.sin_addr
        inet_ntop(AF_INET, &address, &hostChars, socklen_t(INET_ADDRSTRLEN))
        let host = String(cString: hostChars)
        let peer = LANPeer(id: packet.peerID,
                           name: packet.name,
                           host: host,
                           port: packet.port,
                           lastSeen: Date(),
                           online: true)
        onMain { [weak self] in
            self?.handleDiscovered(peer)
        }
    }

    private func handleDiscovered(_ peer: LANPeer) {
        hasReceivedAnnouncement = true
        if localNetworkBlocked {
            localNetworkBlocked = false
        }
        if let index = peers.firstIndex(where: { $0.id == peer.id }) {
            let wasOffline = !peers[index].online
            peers[index] = peer
            if wasOffline, isPaired(peer.id) {
                statusKind = .success
                statusText = "「\(peer.displayName)」已重新连接，可以直接发消息"
            }
        } else {
            peers.append(peer)
            peers.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            statusKind = .idle
            statusText = "发现 \(peers.filter(\.online).count) 台电脑"
        }
        updateFriend(from: peer)
        rebuildHeartbeatHosts()
    }

    /// 每 3 秒刷新在线状态；超过 8 秒无心跳标离线，超过 2 分钟从未上线则移出附近列表。
    private func refreshPeerPresence() {
        let now = Date()
        for index in peers.indices {
            peers[index].online = now.timeIntervalSince(peers[index].lastSeen) <= LinkProtocol.offlineThreshold
        }
        let before = peers.count
        peers.removeAll { now.timeIntervalSince($0.lastSeen) > LinkProtocol.offlineRetention }
        if peers.count != before {
            rebuildHeartbeatHosts()
        }
        if !hasReceivedAnnouncement, started, !showDiscoveryHint,
           now.timeIntervalSince(startTime) > 10 {
            showDiscoveryHint = true
        }
    }

    func rebuildHeartbeatHosts() {
        let hosts = Set((peers.map(\.host) + friends.map(\.host)).filter { !$0.isEmpty })
        hostLock.lock()
        heartbeatHosts = hosts
        hostLock.unlock()
    }

    func triggerHeartbeat(toHost host: String) {
        guard !host.isEmpty else { return }
        netQueue.async { [weak self] in
            guard let self, let payload = self.announcementPayload() else { return }
            self.sendPacket(payload, host: host)
        }
    }

    func ping(peer: LANPeer) {
        setStatus(.idle, "正在重新连接「\(peer.displayName)」…")
        triggerHeartbeat(toHost: peer.host)
    }

    // MARK: - 好友 / 配对持久化

    func rememberPaired(_ peerID: String) {
        pairLock.lock()
        let inserted = pairedIDs.insert(peerID).inserted
        let snapshot = pairedIDs
        let count = pairedIDs.count
        pairLock.unlock()
        if inserted {
            friendStore.savePairedIDs(snapshot)
        }
        onMain { [weak self] in
            guard let self else { return }
            self.pairedCount = count
            if self.pendingPairPeerID == peerID {
                self.pendingPairName = nil
                self.pendingPairPeerID = nil
            }
        }
    }

    func rememberFriend(peer: LANPeer) {
        rememberFriend(id: peer.id, name: peer.name, host: peer.host, port: peer.port)
    }

    func rememberFriend(id: String, name: String, host: String, port: UInt16) {
        onMain { [weak self] in
            self?.upsertFriend(id: id, name: name, host: host, port: port)
        }
    }

    func upsertFriend(id: String, name: String, host: String, port: UInt16) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.upsertFriend(id: id, name: name, host: host, port: port)
            }
            return
        }
        if let index = friends.firstIndex(where: { $0.id == id }) {
            var friend = friends[index]
            if !name.isEmpty, friend.name != name { friend.name = name }
            if !host.isEmpty, friend.host != host { friend.host = host }
            if port > 0, friend.port != port { friend.port = port }
            friend.lastSeen = Date()
            friends[index] = friend
        } else {
            friends.append(LANPeer(id: id,
                                   name: name.isEmpty ? "已配对设备" : name,
                                   host: host,
                                   port: port,
                                   lastSeen: Date(),
                                   online: false))
            friends.sort(by: FriendStore.sortByName)
        }
        friendStore.saveFriends(friends)
        rebuildHeartbeatHosts()
    }

    /// 扫到好友时更新名字 / 地址 / 端口，离线时也能记住上次位置。
    private func updateFriend(from peer: LANPeer) {
        guard let index = friends.firstIndex(where: { $0.id == peer.id }) else {
            if isPaired(peer.id) {
                upsertFriend(id: peer.id, name: peer.name, host: peer.host, port: peer.port)
            }
            return
        }
        var friend = friends[index]
        var changed = false
        if !peer.name.isEmpty, friend.name != peer.name {
            friend.name = peer.name
            changed = true
        }
        if !peer.host.isEmpty, friend.host != peer.host {
            friend.host = peer.host
            changed = true
        }
        if peer.port > 0, friend.port != peer.port {
            friend.port = peer.port
            changed = true
        }
        friend.lastSeen = Date()
        friends[index] = friend
        if changed {
            friendStore.saveFriends(friends)
        }
    }

    func setPendingPair(name: String, peerID: String) {
        onMain { [weak self] in
            self?.pendingPairName = name
            self?.pendingPairPeerID = peerID
        }
    }

    func clearPendingPair() {
        onMain { [weak self] in
            self?.pendingPairName = nil
            self?.pendingPairPeerID = nil
        }
    }

    /// 取消配对：从 paired.json 移除，并清除好友名册里的记录（聊天记录保留，与电脑端一致）。
    func unpair(_ peerID: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.unpair(peerID) }
            return
        }
        let name = displayName(for: peerID)
        pairLock.lock()
        let removed = pairedIDs.remove(peerID) != nil
        let snapshot = pairedIDs
        let count = pairedIDs.count
        pairLock.unlock()
        guard removed else { return }
        friendStore.savePairedIDs(snapshot)
        pairedCount = count
        friends.removeAll { $0.id == peerID }
        friendStore.saveFriends(friends)
        rebuildHeartbeatHosts()
        setStatus(.idle, "已取消与「\(name)」的配对，下次发送需要重新输入配对码")
    }

    // MARK: - 配对码

    func regenerateCode() {
        let code = DeviceIdentity.makePairingCode()
        pairLock.lock()
        authCode = code
        pairLock.unlock()
        pairingCode = code
        setStatus(.idle, "已换新配对码：\(code)")
    }

    func copyPairingCode() {
        UIPasteboard.general.string = pairingCode
        setStatus(.success, "已复制配对码 \(pairingCode)")
    }

    func copyText(_ text: String) {
        UIPasteboard.general.string = text
        setStatus(.success, "已复制到剪贴板")
    }

    // MARK: - 查询

    func peer(for peerID: String) -> LANPeer? {
        let friend = friends.first { $0.id == peerID }
        if var discovered = peers.first(where: { $0.id == peerID }) {
            discovered.alias = friend?.alias
            return discovered
        }
        return friend
    }

    func isOnline(_ peerID: String) -> Bool {
        peers.first { $0.id == peerID }?.online ?? false
    }

    func isPaired(_ peerID: String) -> Bool {
        pairLock.lock()
        defer { pairLock.unlock() }
        return pairedIDs.contains(peerID)
    }

    func isPairedNow(_ peerID: String) -> Bool { isPaired(peerID) }

    func displayName(for peerID: String) -> String {
        peer(for: peerID)?.displayName ?? "电脑"
    }

    var nearbyPeers: [LANPeer] {
        peers.filter { $0.online && !isPaired($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var sortedFriends: [LANPeer] {
        friends.sorted { lhs, rhs in
            let leftOnline = isOnline(lhs.id)
            let rightOnline = isOnline(rhs.id)
            if leftOnline != rightOnline { return leftOnline }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    func messages(for peerID: String) -> [LANMessage] {
        conversations[peerID] ?? []
    }

    func lastMessage(for peerID: String) -> LANMessage? {
        conversations[peerID]?.last
    }

    func messageCount(for peerID: String) -> Int {
        conversations[peerID]?.count ?? 0
    }

    /// 收到 / 发出的文件在本地的真实位置；容器路径变化时回退到接收目录里同名文件。
    func resolvedFileURL(for message: LANMessage) -> URL? {
        if let url = message.fileURL, FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        guard let fileName = message.fileName else { return nil }
        let candidate = receiveDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    var shouldShowLocalNetworkHelp: Bool {
        localNetworkBlocked || (showDiscoveryHint && !peers.contains { $0.online })
    }

    // MARK: - 聊天记录

    func appendMessage(_ message: LANMessage, peerID: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.appendMessage(message, peerID: peerID)
            }
            return
        }
        var list = conversations[peerID] ?? []
        list.append(message)
        if list.count > ChatStore.maxMessagesPerPeer {
            list = Array(list.suffix(ChatStore.maxMessagesPerPeer))
        }
        conversations[peerID] = list
        chatStore.save(list, peerID: peerID)
    }

    func clearMessages(for peerID: String) {
        conversations[peerID] = []
        chatStore.save([], peerID: peerID)
        setStatus(.idle, "已清空当前聊天记录（已经收到的文件不会被删除）")
    }

    /// 启动时把聊天记录里指向旧 Documents/Received 的 filePath 改成 Downloads 里的新位置。
    private func migrateLegacyChatPaths(_ migratedFiles: [String: String]) {
        guard !conversations.isEmpty else { return }
        let legacyPath = legacyReceivedDirectory.standardizedFileURL.path
        let fileManager = FileManager.default
        let peerIDs = Array(conversations.keys)
        for peerID in peerIDs {
            guard var messages = conversations[peerID] else { continue }
            var changed = false
            for index in messages.indices where messages[index].kind == .file {
                guard let oldPath = messages[index].filePath, !oldPath.isEmpty else { continue }
                let oldURL = URL(fileURLWithPath: oldPath).standardizedFileURL
                guard oldURL.deletingLastPathComponent().path == legacyPath else { continue }
                let originalName = oldURL.lastPathComponent
                let newName = migratedFiles[originalName] ?? originalName
                let candidate = receiveDirectory.appendingPathComponent(newName)
                guard fileManager.fileExists(atPath: candidate.path) else { continue }
                messages[index].filePath = candidate.path
                messages[index].fileName = newName
                changed = true
            }
            if changed {
                conversations[peerID] = messages
                chatStore.save(messages, peerID: peerID)
            }
        }
    }

    // MARK: - 发送状态（主线程）

    func beginSend(label: String) {
        onMain { [weak self] in
            guard let self else { return }
            self.busy = true
            self.sendProgress = 0
            self.activeSendLabel = label
            self.statusKind = .idle
            self.statusText = "正在连接…"
        }
    }

    func updateSendProgress(_ value: Double) {
        onMain { [weak self] in
            self?.sendProgress = min(1, max(0, value))
        }
    }

    func updateSendLabel(_ label: String) {
        onMain { [weak self] in
            self?.activeSendLabel = label
        }
    }

    func finishSend() {
        onMain { [weak self] in
            self?.busy = false
            self?.sendProgress = 0
            self?.activeSendLabel = ""
        }
    }

    func setReceivingLabel(_ label: String?) {
        onMain { [weak self] in
            self?.receivingLabel = label
        }
    }

    func setStatus(_ kind: LANStatusKind, _ text: String) {
        onMain { [weak self] in
            guard let self else { return }
            self.statusKind = kind
            self.statusText = text
        }
    }

    // MARK: - 线程工具

    func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    func authSnapshot() -> PairingAuthSnapshot {
        pairLock.lock()
        defer { pairLock.unlock() }
        return PairingAuthSnapshot(paired: pairedIDs, code: authCode)
    }

    /// 当前 TCP 监听端口（诊断 / 集成测试用；0 表示还没开始监听）。
    func listeningPortSnapshot() -> UInt16 {
        netQueue.sync { tcpPort }
    }
}
