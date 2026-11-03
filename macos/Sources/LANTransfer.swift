import Foundation
import AppKit
import Darwin
import Network

struct LANPeer: Identifiable, Equatable {
    let id: String
    var name: String
    var host: String
    var port: UInt16
    var lastSeen: Date
    /// 最近 8 秒内收到过对方广播/单播心跳。离线设备仍保留在列表里，方便自动重连。
    var online: Bool = true
    /// 用户给已配对设备起的别名（本地缓存，优先于设备名显示）
    var alias: String? = nil
}

/// 已配对设备的持久化记录（friends.json）：下次启动、对方离线时仍显示在左侧好友列表里。
private struct StoredFriend: Codable {
    var id: String
    var name: String
    var host: String
    var port: UInt16
    var lastSeen: Date
    /// 别名；旧版 friends.json 没有这个字段，解码时按 nil 处理
    var alias: String? = nil
}

/// 聊天式收发记录：收到的和发出去的文字/文件都留在这里
struct LANMessage: Identifiable, Codable {
    enum Direction: String, Codable {
        case incoming
        case outgoing
    }

    enum Kind: String, Codable {
        case text
        case file
    }

    let id: UUID
    let direction: Direction
    let peerName: String
    let date: Date
    let kind: Kind
    var text: String?
    var fileName: String?
    var filePath: String?
    var fileSize: Int?

    init(direction: Direction, peerName: String, date: Date = Date(),
         text: String) {
        self.id = UUID()
        self.direction = direction
        self.peerName = peerName
        self.date = date
        self.kind = .text
        self.text = text
        self.fileName = nil
        self.filePath = nil
        self.fileSize = nil
    }

    init(direction: Direction, peerName: String, date: Date = Date(),
         fileURL: URL, fileSize: Int?) {
        self.id = UUID()
        self.direction = direction
        self.peerName = peerName
        self.date = date
        self.kind = .file
        self.text = nil
        self.fileName = fileURL.lastPathComponent
        self.filePath = fileURL.path
        self.fileSize = fileSize
    }
}

enum LANOutcome {
    case ok
    case needsPairing(peerName: String)
    case failure(String)
}

/// 局域网直连传输：UDP 广播发现 + TCP 收发文本/文件 + 6 位配对码
final class LANModel: ObservableObject {
    // MARK: - 常量

    static let appTag = "ADBTypeLink"
    static let protocolVersion = 1
    static let discoveryPort: UInt16 = 52730
    private static let receiveDirKey = "lanReceiveDir"
    /// 超过这个时间没收到心跳就标记为「离线」，但先保留在列表里等自动重连。
    private static let offlineThreshold: TimeInterval = 8
    /// 离线设备在列表里保留的时长，超过才真正移除，避免界面上的设备突然消失。
    private static let offlineRetention: TimeInterval = 120

    // MARK: - 界面状态

    @Published var peers: [LANPeer] = []
    /// 已配对设备的好友列表：从 friends.json 恢复，扫到后自动更新在线状态
    @Published var friends: [LANPeer] = []
    /// 每个设备独立的聊天记录缓存：key = 设备 ID，value = 该设备的会话
    @Published var conversations: [String: [LANMessage]] = [:]
    @Published var deviceName: String = ""
    @Published var pairingCode: String = ""
    @Published var receiveDir: String {
        didSet {
            UserDefaults.standard.set(receiveDir, forKey: Self.receiveDirKey)
        }
    }
    @Published var selectedPeerID: String?
    @Published var pairedCount = 0
    @Published var pendingPairName: String?
    @Published var pendingPairPeerID: String?
    @Published var statusText = "正在搜索局域网内的设备…"
    @Published var statusKind: StatusKind = .idle
    @Published var busy = false
    @Published var sendProgress: Double = 0
    @Published var activeSendLabel = ""
    /// 正在重新建立发现 / 监听套接字（网络切换、睡眠唤醒或手动重连时）
    @Published var reconnecting = false
    /// 当前发送是否支持取消（文字 / 文件支持；配对 / 重连过程不显示取消按钮）
    @Published var canCancelSend = false

    // MARK: - 网络

    private let defaults = UserDefaults.standard
    private let netQueue = DispatchQueue(label: "dev.local.adbtype.lan", qos: .utility)
    /// 发送单独一条队列：大文件传输再久也不能阻塞发现 / 心跳，否则界面会把对端误判为离线。
    private let sendQueue = DispatchQueue(label: "dev.local.adbtype.send", qos: .userInitiated)
    private let pairLock = NSLock()

    private let deviceID: String
    private var paired: Set<String>
    private var udpRecvFD: Int32 = -1
    private var udpSendFD: Int32 = -1
    private var tcpListenFD: Int32 = -1
    private var udpSource: DispatchSourceRead?
    private var tcpSource: DispatchSourceRead?
    private var announceTimer: DispatchSourceTimer?
    private var pruneTimer: Timer?
    private var tcpPort: UInt16 = 0
    private var started = false
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?
    private var wakeObserver: NSObjectProtocol?
    private var activityToken: NSObjectProtocol?
    private var lastRestartAt = Date.distantPast
    private var reconnectStartedAt: Date?
    private let sendStateLock = NSLock()
    private var activeSendFD: Int32 = -1
    private var sendCancelled = false

    // MARK: - 初始化

    init() {
        let store = UserDefaults.standard
        if let saved = store.string(forKey: "lanDeviceID") {
            deviceID = saved
        } else {
            let value = UUID().uuidString
            store.set(value, forKey: "lanDeviceID")
            deviceID = value
        }

        let fallbackDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/ADBType 接收", isDirectory: true).path
        receiveDir = store.string(forKey: Self.receiveDirKey) ?? fallbackDir
        deviceName = Host.current().localizedName ?? "Mac"
        pairingCode = Self.makePairingCode()
        paired = Self.loadPaired()
        pairedCount = paired.count
        friends = Self.loadFriends(paired: paired)
        conversations = Self.loadConversations(friends: friends)

        // 旧版本只存了配对 ID，用最近聊天记录里的名字补全好友显示名
        if paired.count == 1,
           let recentName = conversations.values.flatMap({ $0 })
               .max(by: { $0.date < $1.date })?.peerName,
           !recentName.isEmpty,
           let index = friends.firstIndex(where: { $0.name == "已配对设备" && $0.host.isEmpty }) {
            friends[index].name = recentName
            saveFriends()
        }

        // 恢复上次选中的好友；没有就选最近见过的已配对设备
        if let saved = store.string(forKey: "lanSelectedPeerID"),
           friends.contains(where: { $0.id == saved }) {
            selectedPeerID = saved
        } else {
            selectedPeerID = friends.max(by: { $0.lastSeen < $1.lastSeen })?.id
        }

        // 对端中途断开 / 用户取消发送时，向已关闭的连接写数据会触发 SIGPIPE，
        // 默认行为是直接杀进程。忽略它，让 send() 返回 -1，走正常的错误 / 取消流程。
        _ = Darwin.signal(SIGPIPE, SIG_IGN)

        // 关掉 App Nap，避免窗口不在前台时心跳定时器被降频、设备看起来「掉线」
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "局域网设备发现与文字、文件传输")
        start()
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        pathMonitor?.cancel()
        announceTimer?.cancel()
        pruneTimer?.invalidate()
        udpSource?.cancel()
        tcpSource?.cancel()
        if udpRecvFD >= 0 { close(udpRecvFD) }
        if udpSendFD >= 0 { close(udpSendFD) }
        if tcpListenFD >= 0 { close(tcpListenFD) }
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
        }
    }

    private static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999999))
    }

    // MARK: - 配对持久化

    private static var pairedFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("ADBType", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("paired.json")
    }

    private static func loadPaired() -> Set<String> {
        guard let data = try? Data(contentsOf: pairedFileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(list)
    }

    private static var friendsFileURL: URL {
        pairedFileURL.deletingLastPathComponent().appendingPathComponent("friends.json")
    }

    /// 好友列表 = friends.json 里记录过的设备 + 旧版 paired.json 里只有 ID 的设备（名字等上线后补全）
    private static func loadFriends(paired: Set<String>) -> [LANPeer] {
        var result: [LANPeer] = []
        if let data = try? Data(contentsOf: friendsFileURL),
           let list = try? JSONDecoder().decode([StoredFriend].self, from: data) {
            result = list.map {
                LANPeer(id: $0.id, name: $0.name, host: $0.host, port: $0.port,
                        lastSeen: $0.lastSeen, online: false, alias: $0.alias)
            }
        }
        let known = Set(result.map { $0.id })
        for id in paired where !known.contains(id) {
            result.append(LANPeer(id: id, name: "已配对设备", host: "", port: 0,
                                  lastSeen: .distantPast, online: false))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func saveFriends() {
        let records = friends.map {
            StoredFriend(id: $0.id, name: $0.name, host: $0.host,
                         port: $0.port, lastSeen: $0.lastSeen, alias: $0.alias)
        }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: Self.friendsFileURL, options: .atomic)
        }
    }

    private func savePaired() {
        pairLock.lock()
        let list = Array(paired)
        pairLock.unlock()
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: Self.pairedFileURL)
        }
    }

    private func rememberPaired(_ peerID: String) {
        pairLock.lock()
        let inserted = paired.insert(peerID).inserted
        let count = paired.count
        pairLock.unlock()
        if inserted { savePaired() }
        DispatchQueue.main.async {
            self.pairedCount = count
            if self.pendingPairPeerID == peerID {
                self.pendingPairName = nil
                self.pendingPairPeerID = nil
            }
        }
    }

    // MARK: - 好友列表（已配对设备常驻左侧）

    /// 配对成功后写入好友列表，下次启动直接显示，扫到后自动恢复在线状态。
    private func rememberFriend(_ peer: LANPeer) {
        DispatchQueue.main.async {
            self.upsertFriend(id: peer.id, name: peer.name, host: peer.host, port: peer.port)
        }
    }

    private func rememberFriend(id: String, name: String, host: String, port: UInt16) {
        DispatchQueue.main.async {
            self.upsertFriend(id: id, name: name, host: host, port: port)
        }
    }

    private func upsertFriend(id: String, name: String, host: String, port: UInt16) {
        if let index = friends.firstIndex(where: { $0.id == id }) {
            var friend = friends[index]
            if !name.isEmpty { friend.name = name }
            if !host.isEmpty { friend.host = host }
            if port > 0 { friend.port = port }
            friend.lastSeen = Date()
            friends[index] = friend
        } else {
            friends.append(LANPeer(id: id, name: name.isEmpty ? "已配对设备" : name,
                                   host: host, port: port, lastSeen: Date(), online: false))
            friends.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        saveFriends()
        if selectedPeerID == nil { selectPeer(id) }
    }

    /// 扫到好友时更新记录里的名字 / 地址 / 端口，离线时也能记住上次位置。
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
        if changed { saveFriends() }
    }

    func selectPeer(_ peerID: String?) {
        selectedPeerID = peerID
        defaults.set(peerID, forKey: "lanSelectedPeerID")
    }

    /// 从「已发现设备」或「已配对好友」里找当前可发送的对象（在线设备带上好友的别名）
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

    func alias(for peerID: String) -> String? {
        guard let raw = friends.first(where: { $0.id == peerID })?.alias else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 显示名：有别名优先用别名，否则用设备名
    func displayName(_ peer: LANPeer) -> String {
        if let alias = peer.alias, !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return alias
        }
        return peer.name
    }

    func displayName(for peerID: String) -> String {
        guard let peer = peer(for: peerID) else { return "设备" }
        return displayName(peer)
    }

    /// 聊天记录里只存了当时的设备名，这里按设备名 / 别名回查，让历史消息也跟随别名显示
    func displayName(forRemoteName name: String) -> String {
        if let friend = friends.first(where: { $0.name == name || $0.alias == name }) {
            return displayName(friend)
        }
        return name
    }

    var hasAliases: Bool {
        friends.contains { !(($0.alias ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }

    /// 设置别名；传空字符串等于清除别名（回退显示设备名）
    func setAlias(_ alias: String, for peerID: String) {
        guard let index = friends.firstIndex(where: { $0.id == peerID }) else { return }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        friends[index].alias = trimmed.isEmpty ? nil : trimmed
        saveFriends()
        statusKind = .success
        statusText = trimmed.isEmpty
            ? "已清除「\(friends[index].name)」的别名"
            : "已把「\(friends[index].name)」的别名设为「\(trimmed)」"
    }

    /// 清除全部设备的别名缓存；配对关系保持不变
    func clearAliases() {
        guard hasAliases else { return }
        for index in friends.indices { friends[index].alias = nil }
        saveFriends()
        statusKind = .success
        statusText = "已清除全部别名缓存（配对关系不受影响）"
    }

    /// 左侧「附近设备」：当前发现但还没配对的设备
    var nearbyPeers: [LANPeer] {
        peers.filter { !isPaired($0.id) }
    }

    /// 左侧「已配对」：好友里在线的排前面
    var sortedFriends: [LANPeer] {
        friends.sorted {
            let leftOnline = isOnline($0.id)
            let rightOnline = isOnline($1.id)
            if leftOnline != rightOnline { return leftOnline }
            return displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending
        }
    }

    // MARK: - 聊天记录持久化（按设备独立缓存）

    private static var chatsDirectory: URL {
        let dir = pairedFileURL.deletingLastPathComponent()
            .appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func chatFileURL(for peerID: String) -> URL {
        let safe = peerID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return chatsDirectory.appendingPathComponent("\(safe).json")
    }

    private static var legacyChatFileURL: URL {
        pairedFileURL.deletingLastPathComponent().appendingPathComponent("chat.json")
    }

    /// 加载每个设备自己的会话；旧版本遗留的 chat.json / chat.json.migrated 会合并导入后归档。
    private static func loadConversations(friends: [LANPeer]) -> [String: [LANMessage]] {
        var result: [String: [LANMessage]] = [:]
        let manager = FileManager.default
        if let files = try? manager.contentsOfDirectory(at: chatsDirectory,
                                                        includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                let peerID = file.deletingPathExtension().lastPathComponent
                guard let data = try? Data(contentsOf: file),
                      let list = try? JSONDecoder().decode([LANMessage].self, from: data) else { continue }
                result[peerID] = list.sorted { $0.date < $1.date }
            }
        }

        let legacyURLs = [legacyChatFileURL,
                          legacyChatFileURL.appendingPathExtension("migrated")]
            .filter { manager.fileExists(atPath: $0.path) }
        var legacy: [LANMessage] = []
        for url in legacyURLs {
            guard let data = try? Data(contentsOf: url),
                  let list = try? JSONDecoder().decode([LANMessage].self, from: data) else { continue }
            legacy.append(contentsOf: list)
        }
        guard !legacy.isEmpty else { return result }

        // 单好友直接归给它；多好友时按老消息里的设备名匹配消息最多的那台
        var targetID: String?
        if friends.count == 1 {
            targetID = friends[0].id
        } else if !friends.isEmpty {
            var best: (id: String, count: Int)?
            for friend in friends {
                let count = legacy.filter { $0.peerName == friend.name }.count
                if count > (best?.count ?? 0) { best = (friend.id, count) }
            }
            targetID = best?.id ?? friends[0].id
        }
        guard let targetID else { return result }

        var merged = result[targetID] ?? []
        var known = Set(merged.map { $0.id })
        for message in legacy.sorted(by: { $0.date < $1.date }) where known.insert(message.id).inserted {
            merged.append(message)
        }
        merged.sort { $0.date < $1.date }
        if merged.count > 500 { merged.removeFirst(merged.count - 500) }
        result[targetID] = merged
        if let encoded = try? JSONEncoder().encode(merged) {
            try? encoded.write(to: chatFileURL(for: targetID), options: .atomic)
        }

        // 归档旧文件，避免每次启动重复导入（消息按 id 去重，重复导入也不会重复）
        let archive = chatsDirectory.deletingLastPathComponent()
            .appendingPathComponent("legacy-chat", isDirectory: true)
        try? manager.createDirectory(at: archive, withIntermediateDirectories: true)
        for url in legacyURLs {
            var destination = archive.appendingPathComponent(url.lastPathComponent)
            if manager.fileExists(atPath: destination.path) {
                destination = archive.appendingPathComponent(
                    "\(url.lastPathComponent).\(Int(Date().timeIntervalSince1970))")
            }
            try? manager.moveItem(at: url, to: destination)
        }
        return result
    }

    private func saveConversation(_ peerID: String) {
        let list = conversations[peerID] ?? []
        if list.isEmpty {
            try? FileManager.default.removeItem(at: Self.chatFileURL(for: peerID))
            return
        }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: Self.chatFileURL(for: peerID), options: .atomic)
        }
    }

    func messages(for peerID: String?) -> [LANMessage] {
        guard let peerID else { return [] }
        return conversations[peerID] ?? []
    }

    func messageCount(for peerID: String?) -> Int {
        messages(for: peerID).count
    }

    var totalMessageCount: Int {
        conversations.values.reduce(0) { $0 + $1.count }
    }

    private func appendMessage(_ message: LANMessage, peerID: String) {
        DispatchQueue.main.async {
            var list = self.conversations[peerID] ?? []
            list.append(message)
            if list.count > 500 {
                list.removeFirst(list.count - 500)
            }
            self.conversations[peerID] = list
            self.saveConversation(peerID)
        }
    }

    func clearMessages(for peerID: String?) {
        guard let peerID else { return }
        conversations[peerID] = []
        saveConversation(peerID)
        statusKind = .idle
        statusText = "已清空当前设备的聊天记录，已收到的文件不会被删除"
    }

    func clearAllMessages() {
        let ids = Array(conversations.keys)
        conversations.removeAll()
        for peerID in ids { saveConversation(peerID) }
        statusKind = .idle
        statusText = "已清空全部设备的聊天记录，已收到的文件不会被删除"
    }

    func isPaired(_ peerID: String) -> Bool {
        pairLock.lock()
        defer { pairLock.unlock() }
        return paired.contains(peerID)
    }

    func forgetPairs() {
        pairLock.lock()
        paired.removeAll()
        pairLock.unlock()
        savePaired()
        friends.removeAll()
        saveFriends()
        selectPeer(nil)
        pairedCount = 0
        statusKind = .idle
        statusText = "已清除配对记录，下次发送需要重新输入配对码"
    }

    func forget(_ peer: LANPeer) {
        pairLock.lock()
        let removed = paired.remove(peer.id) != nil
        let count = paired.count
        pairLock.unlock()
        if removed { savePaired() }
        friends.removeAll { $0.id == peer.id }
        saveFriends()
        if selectedPeerID == peer.id { selectPeer(friends.first?.id) }
        pairedCount = count
        statusKind = .idle
        statusText = "已取消与「\(peer.name)」的配对，下次发送需要重新输入配对码"
    }

    func clearPendingPair() {
        pendingPairName = nil
        pendingPairPeerID = nil
    }

    func regenerateCode() {
        pairingCode = Self.makePairingCode()
        statusKind = .idle
        statusText = "已换新配对码：\(pairingCode)"
    }

    // MARK: - 启动 / 网络

    private func start() {
        guard !started else { return }
        started = true
        netQueue.async { [weak self] in
            self?.openSockets()
        }

        // 睡眠唤醒后套接字可能已经失效，重新建立并立刻广播
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.autoReconnect(reason: "电脑刚从睡眠中唤醒")
            }

        // Wi-Fi / 有线网络切换（含断网恢复）时自动重连
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = "\(path.status) " + path.availableInterfaces.map { $0.name }.joined(separator: ",")
            guard let previous = self.lastPathSignature else {
                self.lastPathSignature = signature
                return
            }
            guard signature != previous else { return }
            self.lastPathSignature = signature
            guard path.status == .satisfied else { return }
            self.restartNetwork(force: false, message: "网络已切换，正在自动重连…")
        }
        monitor.start(queue: netQueue)
        pathMonitor = monitor

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshPeerPresence()
        }
    }

    /// 每 2 秒刷新在线状态：先标记离线（保留在列表里），2 分钟都收不到心跳才移除。
    private func refreshPeerPresence() {
        let now = Date()
        var wentOffline: LANPeer?
        for index in peers.indices {
            let online = now.timeIntervalSince(peers[index].lastSeen) <= Self.offlineThreshold
            if peers[index].online != online {
                peers[index].online = online
                if !online { wentOffline = peers[index] }
            }
        }

        let before = peers.count
        peers.removeAll { now.timeIntervalSince($0.lastSeen) > Self.offlineRetention }
        if peers.count != before,
           let selected = selectedPeerID,
           !peers.contains(where: { $0.id == selected }),
           !friends.contains(where: { $0.id == selected }) {
            let next = friends.first(where: { isOnline($0.id) })?.id
                ?? peers.first(where: { $0.online })?.id
                ?? peers.first?.id
                ?? friends.first?.id
            selectPeer(next)
        }

        let onlinePeers = peers.filter { $0.online }

        if reconnecting {
            if !onlinePeers.isEmpty {
                reconnecting = false
                statusKind = .success
                statusText = "已重新连接，当前 \(onlinePeers.count) 台设备在线"
            } else if let begun = reconnectStartedAt, now.timeIntervalSince(begun) > 10 {
                reconnecting = false
                statusKind = .idle
                statusText = friends.isEmpty
                    ? "暂时没找到设备，正在继续自动搜索…"
                    : "已配对设备仍离线，正在继续自动重连…"
            }
        }

        if peers.isEmpty, !reconnecting, !busy, statusKind != .failure {
            statusKind = .idle
            statusText = friends.isEmpty
                ? "正在搜索局域网内的设备…"
                : "已配对设备暂时离线，正在自动重连…"
        } else if let peer = wentOffline, peer.id == selectedPeerID,
                  !busy, !reconnecting {
            statusKind = .idle
            statusText = "「\(peer.name)」暂时离线，正在自动重连…"
        } else if !peers.isEmpty, onlinePeers.isEmpty,
                  !busy, !reconnecting {
            statusKind = .idle
            statusText = friends.isEmpty
                ? "附近设备暂时离线，正在自动重连…"
                : "已配对设备暂时离线，正在自动重连…"
        }
    }

    // MARK: - 重连

    /// 手动重连：重新建立发现/监听套接字，并立即广播一轮。
    func reconnectAll() {
        guard !busy else {
            statusKind = .failure
            statusText = "正在发送，请稍后再重连"
            return
        }
        DispatchQueue.main.async {
            self.reconnecting = true
            self.reconnectStartedAt = Date()
            self.statusKind = .idle
            self.statusText = "正在重新连接…"
        }
        netQueue.async { [weak self] in
            self?.restartNetwork(force: true)
        }
    }

    /// 对指定设备手动重连：先单播心跳，已配对的再做一次 TCP 握手探活。
    func reconnect(to peer: LANPeer, completion: @escaping (LANOutcome) -> Void) {
        guard !busy else {
            completion(.failure("正在发送，请稍后再试"))
            return
        }
        beginSend(label: "重连 \(peer.name)", cancellable: false)
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.netQueue.async { [weak self] in
                self?.sendUnicastAnnouncement(toHost: peer.host)
            }
            if self.isPaired(peer.id) {
                if let fd = self.connectWithRetry(to: peer, attempts: 2) {
                    let result = self.handshake(fd, peer: peer, code: nil)
                    close(fd)
                    if case .ok = result {
                        self.markPeerOnline(peer)
                        self.finish(.ok, completion,
                                    successText: "已重新连接「\(peer.name)」")
                        return
                    }
                }
                self.finish(.failure("暂时连不上「\(peer.name)」，后台会继续自动重连"),
                            completion)
            } else {
                self.finish(.ok, completion,
                            successText: "已向「\(peer.name)」发出重连请求，等待对方回应…")
            }
        }
    }

    private func autoReconnect(reason: String) {
        netQueue.async { [weak self] in
            self?.restartNetwork(force: false, message: "\(reason)，正在自动重连…")
        }
    }

    /// 重新建立 UDP/TCP 套接字。必须在 netQueue 上调用。
    private func restartNetwork(force: Bool, message: String = "正在重新连接…") {
        let now = Date()
        if !force, now.timeIntervalSince(lastRestartAt) < 2 { return }
        lastRestartAt = now
        teardownNetwork()
        openSockets()
        announce()
        DispatchQueue.main.async {
            self.reconnecting = true
            self.reconnectStartedAt = Date()
            self.statusKind = .idle
            self.statusText = message
        }
    }

    private func teardownNetwork() {
        announceTimer?.cancel()
        announceTimer = nil
        udpSource?.cancel()
        udpSource = nil
        tcpSource?.cancel()
        tcpSource = nil
        if udpRecvFD >= 0 { close(udpRecvFD); udpRecvFD = -1 }
        if udpSendFD >= 0 { close(udpSendFD); udpSendFD = -1 }
        if tcpListenFD >= 0 { close(tcpListenFD); tcpListenFD = -1 }
        tcpPort = 0
    }

    private func markPeerOnline(_ peer: LANPeer) {
        DispatchQueue.main.async {
            if let index = self.peers.firstIndex(where: { $0.id == peer.id }) {
                self.peers[index].lastSeen = Date()
                self.peers[index].online = true
            }
        }
    }

    private func openSockets() {
        // UDP 接收：多实例共用同一端口，广播会送到所有监听者
        let recvFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard recvFD >= 0 else {
            reportNetworkFailure("无法创建局域网套接字")
            return
        }
        var reuse: Int32 = 1
        setsockopt(recvFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(recvFD, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var recvAddr = sockaddr_in()
        recvAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        recvAddr.sin_family = sa_family_t(AF_INET)
        recvAddr.sin_port = Self.discoveryPort.bigEndian
        recvAddr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &recvAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(recvFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(recvFD)
            reportNetworkFailure("端口 \(Self.discoveryPort) 被占用，无法启动局域网发现")
            return
        }
        udpRecvFD = recvFD
        let udpSrc = DispatchSource.makeReadSource(fileDescriptor: recvFD, queue: netQueue)
        udpSrc.setEventHandler { [weak self] in
            self?.readDiscoveryPackets()
        }
        udpSrc.resume()
        udpSource = udpSrc

        // UDP 发送
        udpSendFD = socket(AF_INET, SOCK_DGRAM, 0)
        if udpSendFD >= 0 {
            var broadcast: Int32 = 1
            setsockopt(udpSendFD, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
        }

        // TCP 监听：随机端口，随广播一起发布
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            reportNetworkFailure("无法创建 TCP 监听")
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
        guard listenBound == 0, Darwin.listen(listenFD, 8) == 0 else {
            close(listenFD)
            reportNetworkFailure("无法开始监听传输连接")
            return
        }

        // 监听套接字必须非阻塞：下面的 accept 循环在拿到一个连接后如果继续 accept，
        // 阻塞模式下会永远卡在这里，把整个发现 / 发送队列一起冻住（对端就会被误判离线）。
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
            guard let self else { return }
            while true {
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(self.tcpListenFD, $0, &clientLen)
                    }
                }
                if client < 0 { break }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                           socklen_t(MemoryLayout<Int32>.size))
                // macOS 上 accept 出来的 socket 会继承监听端的 O_NONBLOCK；
                // 后续 handleClient 按「阻塞 + 30 秒超时」读写，这里必须把非阻塞标志清掉，
                // 否则 hello 之后的内容（文字 / 文件字节）会被当成 EOF 直接断开。
                let clientFlags = fcntl(client, F_GETFL, 0)
                _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.handleClient(client)
                }
            }
        }
        tcpSrc.resume()
        tcpSource = tcpSrc

        let timer = DispatchSource.makeTimerSource(queue: netQueue)
        timer.schedule(deadline: .now() + 0.2, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.announce()
        }
        timer.resume()
        announceTimer = timer

        DispatchQueue.main.async {
            self.statusKind = .idle
            self.statusText = self.friends.isEmpty
                ? "本机已上线，正在查找附近的设备…"
                : "本机已上线，正在连接已配对设备…"
        }
    }

    private func reportNetworkFailure(_ message: String) {
        DispatchQueue.main.async {
            self.statusKind = .failure
            self.statusText = message
        }
    }

    private func announcementPayload() -> Data? {
        guard tcpPort != 0 else { return nil }
        let payload: [String: Any] = [
            "app": Self.appTag,
            "v": Self.protocolVersion,
            "id": deviceID,
            "name": deviceName,
            "port": Int(tcpPort)
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private func announce() {
        guard udpSendFD >= 0, let data = announcementPayload() else { return }

        var broadcastAddr = sockaddr_in()
        broadcastAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        broadcastAddr.sin_family = sa_family_t(AF_INET)
        broadcastAddr.sin_port = Self.discoveryPort.bigEndian
        broadcastAddr.sin_addr = in_addr(s_addr: INADDR_BROADCAST)
        sendPacket(data, to: &broadcastAddr)

        // 本机回环：方便同一台电脑开两个实例联调
        var loopAddr = sockaddr_in()
        loopAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        loopAddr.sin_family = sa_family_t(AF_INET)
        loopAddr.sin_port = Self.discoveryPort.bigEndian
        loopAddr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        sendPacket(data, to: &loopAddr)

        // 广播在酒店 / 公司 Wi-Fi 上经常被 AP 过滤或丢包。再给已知设备单播发一份
        // 同样的心跳（报文格式完全不变），对端只要收到就能刷新在线状态。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 已配对好友即使离线也保留在列表里，同样给它们单播心跳
            let hosts = Set(self.peers.map { $0.host } + self.friends.map { $0.host })
                .filter { !$0.isEmpty }
            guard !hosts.isEmpty else { return }
            self.netQueue.async { [weak self] in
                guard let self else { return }
                for host in hosts {
                    self.sendUnicastAnnouncement(data: data, toHost: host)
                }
            }
        }
    }

    private func sendUnicastAnnouncement(toHost host: String) {
        guard let data = announcementPayload() else { return }
        sendUnicastAnnouncement(data: data, toHost: host)
    }

    private func sendUnicastAnnouncement(data: Data, toHost host: String) {
        guard udpSendFD >= 0 else { return }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.discoveryPort.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        sendPacket(data, to: &address)
    }

    private func sendPacket(_ data: Data, to address: inout sockaddr_in) {
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return 0 }
                    return sendto(udpSendFD, base, data.count, 0, sockPtr,
                                  socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func readDiscoveryPackets() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var fromAddr = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let received = withUnsafeMutablePointer(to: &fromAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(udpRecvFD, &buffer, buffer.count, 0, $0, &fromLen)
            }
        }
        guard received > 0 else { return }
        let data = Data(buffer[0..<received])
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["app"] as? String == Self.appTag,
              let peerID = obj["id"] as? String, peerID != deviceID,
              let name = obj["name"] as? String,
              let portValue = obj["port"] as? Int,
              portValue > 0, portValue < 65536 else {
            return
        }

        var hostChars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var address = fromAddr.sin_addr
        inet_ntop(AF_INET, &address, &hostChars, socklen_t(INET_ADDRSTRLEN))
        let host = String(cString: hostChars)

        let peer = LANPeer(id: peerID, name: name, host: host,
                           port: UInt16(portValue), lastSeen: Date())
        DispatchQueue.main.async {
            if let index = self.peers.firstIndex(where: { $0.id == peerID }) {
                let wasOffline = !self.peers[index].online
                self.peers[index] = peer
                self.updateFriend(from: peer)
                if wasOffline {
                    self.reconnecting = false
                    self.statusKind = .success
                    self.statusText = self.isPaired(peerID)
                        ? "「\(peer.name)」已重新连接，可以直接发消息"
                        : "「\(peer.name)」已重新连接"
                }
            } else {
                self.peers.append(peer)
                self.peers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.updateFriend(from: peer)
                if self.selectedPeerID == nil {
                    self.selectPeer(peerID)
                }
                if self.isPaired(peerID) {
                    self.statusKind = .success
                    self.statusText = "「\(peer.name)」已上线，可以直接发消息"
                } else {
                    self.statusKind = .idle
                    self.statusText = "发现 \(self.peers.count) 台设备"
                }
            }
        }
    }

    // MARK: - 发送

    func sendText(_ text: String, to peer: LANPeer, code: String?,
                  completion: @escaping (LANOutcome) -> Void) {
        let value = text
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure("先输入要发送的文字"))
            return
        }
        beginSend(label: "文字")
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.performText(value, peer: peer, code: code) { [weak self] outcome in
                guard let self else { return }
                if case .ok = outcome {
                    self.appendMessage(LANMessage(direction: .outgoing,
                                                  peerName: peer.name,
                                                  text: value),
                                       peerID: peer.id)
                }
                completion(outcome)
            }
        }
    }

    private func performText(_ text: String, peer: LANPeer, code: String?,
                             completion: @escaping (LANOutcome) -> Void) {
        guard let fd = connectWithRetry(to: peer) else {
            // 失败后立刻补发一次单播心跳，触发对方的在线状态刷新（心跳只在 netQueue 上操作 socket）
            netQueue.async { [weak self] in
                self?.sendUnicastAnnouncement(toHost: peer.host)
            }
            if isSendCancelled {
                finishCancelled(completion)
            } else {
                finish(.failure("连不上「\(peer.name)」，已自动重试 3 次；正在后台自动重连，稍后可直接重发"), completion)
            }
            return
        }
        trackSendSocket(fd)
        defer { closeSendSocket(fd) }

        if isSendCancelled {
            finishCancelled(completion)
            return
        }

        switch handshake(fd, peer: peer, code: code) {
        case .ok:
            if isSendCancelled {
                finishCancelled(completion)
                return
            }
            guard writeJSON(fd, ["type": "text", "text": text]),
                  let responseData = readFrame(fd),
                  let response = jsonObject(responseData),
                  response["type"] as? String == "ok" else {
                if isSendCancelled {
                    finishCancelled(completion)
                } else {
                    finish(.failure("发送文字失败，对方没有确认"), completion)
                }
                return
            }
            _ = writeJSON(fd, ["type": "bye"])
            if isSendCancelled {
                finishCancelled(completion)
            } else {
                finish(.ok, completion, successText: "已把文字发送给 \(peer.name)")
            }
        case .needsPairing(let name):
            if isSendCancelled {
                finishCancelled(completion)
            } else {
                finish(.needsPairing(peerName: name), completion)
            }
        case .failure(let message):
            if isSendCancelled {
                finishCancelled(completion)
            } else {
                finish(.failure(message), completion)
            }
        }
    }

    func sendFiles(_ urls: [URL], to peer: LANPeer, code: String?,
                   completion: @escaping (LANOutcome) -> Void) {
        guard !urls.isEmpty else {
            completion(.failure("先选择文件"))
            return
        }
        beginSend(label: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个文件")
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.performFiles(urls, peer: peer, code: code, completion: completion)
        }
    }

    /// 主动配对：只握手，不发送内容
    func pair(with peer: LANPeer, code: String,
              completion: @escaping (LANOutcome) -> Void) {
        let value = code.trimmingCharacters(in: .whitespaces)
        guard value.count == 6, value.allSatisfy({ $0.isNumber }) else {
            completion(.failure("配对码是 6 位数字"))
            return
        }
        beginSend(label: "配对", cancellable: false)
        sendQueue.async { [weak self] in
            guard let self else { return }
            guard let fd = self.connectWithRetry(to: peer, attempts: 2) else {
                self.netQueue.async { [weak self] in
                    self?.sendUnicastAnnouncement(toHost: peer.host)
                }
                self.finish(.failure("连不上「\(peer.name)」，正在后台自动重连"), completion)
                return
            }
            defer { close(fd) }
            switch self.handshake(fd, peer: peer, code: value) {
            case .ok:
                _ = self.writeJSON(fd, ["type": "bye"])
                self.finish(.ok, completion,
                            successText: "已与「\(peer.name)」配对，可以直接发送文字和文件")
            case .needsPairing:
                self.finish(.failure("配对码不对，再看一眼对方屏幕上显示的数字"), completion)
            case .failure(let message):
                self.finish(.failure(message), completion)
            }
        }
    }

    private func performFiles(_ urls: [URL], peer: LANPeer, code: String?,
                              completion: @escaping (LANOutcome) -> Void) {
        var currentCode = code

        for (index, url) in urls.enumerated() {
            if isSendCancelled {
                finishCancelled(completion)
                return
            }

            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else {
                finish(.failure("读不到文件：\(url.lastPathComponent)"), completion)
                return
            }

            DispatchQueue.main.async {
                self.activeSendLabel = urls.count > 1
                    ? "\(index + 1)/\(urls.count) \(url.lastPathComponent)"
                    : url.lastPathComponent
                self.sendProgress = urls.count > 1 ? Double(index) / Double(urls.count) : 0
            }

            guard let fd = connectWithRetry(to: peer) else {
                netQueue.async { [weak self] in
                    self?.sendUnicastAnnouncement(toHost: peer.host)
                }
                if isSendCancelled {
                    finishCancelled(completion)
                } else {
                    finish(.failure("连不上「\(peer.name)」，已自动重试 3 次；正在后台自动重连，稍后可直接重发"), completion)
                }
                return
            }
            trackSendSocket(fd)

            if isSendCancelled {
                closeSendSocket(fd)
                finishCancelled(completion)
                return
            }

            let handshakeResult = handshake(fd, peer: peer, code: currentCode)
            switch handshakeResult {
            case .needsPairing(let name):
                closeSendSocket(fd)
                if isSendCancelled { finishCancelled(completion) } else { finish(.needsPairing(peerName: name), completion) }
                return
            case .failure(let message):
                closeSendSocket(fd)
                if isSendCancelled { finishCancelled(completion) } else { finish(.failure(message), completion) }
                return
            case .ok:
                currentCode = nil
            }

            guard writeJSON(fd, ["type": "file",
                                 "name": url.lastPathComponent,
                                 "size": size]) else {
                closeSendSocket(fd)
                if isSendCancelled { finishCancelled(completion) } else { finish(.failure("发送文件信息失败"), completion) }
                return
            }

            guard let handle = try? FileHandle(forReadingFrom: url) else {
                closeSendSocket(fd)
                finish(.failure("读不到文件：\(url.lastPathComponent)"), completion)
                return
            }

            var sentBytes = 0
            var failed = false
            var cancelled = false

            while true {
                if isSendCancelled {
                    cancelled = true
                    break
                }
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: 256 * 1024)
                } catch {
                    chunk = nil
                    failed = true
                    break
                }
                guard let chunk, !chunk.isEmpty else { break }
                guard writeAll(fd, chunk) else {
                    if isSendCancelled { cancelled = true } else { failed = true }
                    break
                }
                sentBytes += chunk.count
                let fraction = Double(sentBytes) / Double(size)
                let overall = (Double(index) + fraction) / Double(urls.count)
                DispatchQueue.main.async {
                    self.sendProgress = min(0.99, overall)
                }
            }
            try? handle.close()

            if cancelled || isSendCancelled {
                closeSendSocket(fd)
                finishCancelled(completion)
                return
            }

            if failed {
                closeSendSocket(fd)
                finish(.failure("网络中断，文件没发完"), completion)
                return
            }

            guard let responseData = readFrame(fd),
                  let response = jsonObject(responseData),
                  response["type"] as? String == "ok" else {
                closeSendSocket(fd)
                if isSendCancelled { finishCancelled(completion) } else { finish(.failure("对方没有确认收到文件"), completion) }
                return
            }

            _ = writeJSON(fd, ["type": "bye"])
            closeSendSocket(fd)

            // 每个文件成功就立刻记进聊天记录：中途取消时，已经发出去的文件也留痕
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path))
                .flatMap { ($0[.size] as? NSNumber)?.intValue }
            appendMessage(LANMessage(direction: .outgoing,
                                     peerName: peer.name,
                                     fileURL: url,
                                     fileSize: fileSize),
                          peerID: peer.id)
        }

        if isSendCancelled {
            finishCancelled(completion)
            return
        }

        let message = urls.count == 1
            ? "已把「\(urls[0].lastPathComponent)」发送给 \(peer.name)"
            : "已把 \(urls.count) 个文件发送给 \(peer.name)"
        finish(.ok, completion, successText: message)
    }

    private func beginSend(label: String, cancellable: Bool = true) {
        resetSendCancellation()
        DispatchQueue.main.async {
            self.busy = true
            self.sendProgress = 0
            self.activeSendLabel = label
            self.canCancelSend = cancellable
            self.statusKind = .idle
            self.statusText = "正在连接…"
        }
    }

    private func finish(_ outcome: LANOutcome,
                        _ completion: ((LANOutcome) -> Void)? = nil,
                        successText: String? = nil) {
        DispatchQueue.main.async {
            self.busy = false
            self.sendProgress = 0
            self.activeSendLabel = ""
            self.canCancelSend = false
            switch outcome {
            case .ok:
                self.statusKind = .success
                self.statusText = successText ?? "已发送"
            case .needsPairing(let name):
                self.statusKind = .idle
                self.statusText = "首次给「\(name)」发送，需要输入对方屏幕上显示的 6 位配对码"
            case .failure(let message):
                self.statusKind = .failure
                self.statusText = message
            }
            completion?(outcome)
        }
    }

    /// 用户点 X 主动取消：不显示成红色错误
    private func finishCancelled(_ completion: ((LANOutcome) -> Void)? = nil) {
        DispatchQueue.main.async {
            self.busy = false
            self.sendProgress = 0
            self.activeSendLabel = ""
            self.canCancelSend = false
            self.statusKind = .idle
            self.statusText = "已取消发送"
        }
        completion?(.failure("已取消发送"))
    }

    // MARK: - 取消发送

    /// 取消当前发送：置取消标记 + shutdown 当前 socket，让阻塞中的读写立刻返回。
    func cancelSend() {
        guard busy, canCancelSend else { return }
        sendStateLock.lock()
        sendCancelled = true
        let fd = activeSendFD
        sendStateLock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        DispatchQueue.main.async {
            self.statusKind = .idle
            self.statusText = "正在取消发送…"
        }
    }

    private var isSendCancelled: Bool {
        sendStateLock.lock()
        defer { sendStateLock.unlock() }
        return sendCancelled
    }

    private func resetSendCancellation() {
        sendStateLock.lock()
        sendCancelled = false
        activeSendFD = -1
        sendStateLock.unlock()
    }

    private func trackSendSocket(_ fd: Int32) {
        sendStateLock.lock()
        activeSendFD = fd
        let alreadyCancelled = sendCancelled
        sendStateLock.unlock()
        if alreadyCancelled { shutdown(fd, SHUT_RDWR) }
    }

    private func closeSendSocket(_ fd: Int32) {
        sendStateLock.lock()
        if activeSendFD == fd { activeSendFD = -1 }
        sendStateLock.unlock()
        close(fd)
    }

    // MARK: - 握手

    private enum Handshake {
        case ok
        case needsPairing(String)
        case failure(String)
    }

    private func handshake(_ fd: Int32, peer: LANPeer, code: String?) -> Handshake {
        var hello: [String: Any] = [
            "app": Self.appTag,
            "v": Self.protocolVersion,
            "id": deviceID,
            "name": deviceName
        ]
        if let code, !code.isEmpty {
            hello["code"] = code
        }
        guard writeJSON(fd, hello),
              let data = readFrame(fd),
              let response = jsonObject(data),
              let type = response["type"] as? String else {
            return .failure("对方没有响应")
        }

        switch type {
        case "hello_ok":
            rememberPaired(peer.id)
            rememberFriend(peer)
            return .ok
        case "pair_required":
            return .needsPairing(response["name"] as? String ?? peer.name)
        case "error":
            return .failure(response["message"] as? String ?? "对方拒绝了连接")
        default:
            return .failure("协议不匹配，请确认两端版本一致")
        }
    }

    // MARK: - 接收

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        setTimeout(fd, seconds: 30)

        guard let helloData = readFrame(fd),
              let hello = jsonObject(helloData),
              hello["app"] as? String == Self.appTag,
              let peerID = hello["id"] as? String, peerID != deviceID,
              let peerName = hello["name"] as? String else {
            _ = writeJSON(fd, ["type": "error", "message": "协议不匹配，请升级两端应用"])
            return
        }

        pairLock.lock()
        let alreadyPaired = paired.contains(peerID)
        pairLock.unlock()

        if !alreadyPaired {
            let code = (hello["code"] as? String)?.trimmingCharacters(in: .whitespaces)
            guard let code, code == pairingCode else {
                DispatchQueue.main.async {
                    self.pendingPairName = peerName
                    self.pendingPairPeerID = peerID
                    self.statusKind = .idle
                    self.statusText = "「\(peerName)」正在请求配对，把配对码告诉对方即可"
                }
                _ = writeJSON(fd, ["type": "pair_required", "name": deviceName])
                return
            }
            rememberPaired(peerID)
        }

        // 对方主动连过来时也刷新好友记录（端口未知，等对方广播时补全）
        rememberFriend(id: peerID, name: peerName, host: remoteHost(fd), port: 0)

        guard writeJSON(fd, ["type": "hello_ok", "name": deviceName, "id": deviceID]) else {
            return
        }

        DispatchQueue.main.async {
            self.statusKind = .idle
            self.statusText = "\(peerName) 已连接"
        }

        while true {
            guard let frame = readFrame(fd),
                  let obj = jsonObject(frame),
                  let type = obj["type"] as? String else {
                return
            }

            switch type {
            case "text":
                guard let text = obj["text"] as? String else { return }
                self.appendMessage(LANMessage(direction: .incoming,
                                              peerName: peerName,
                                              text: text),
                                   peerID: peerID)
                DispatchQueue.main.async {
                    self.statusKind = .success
                    self.statusText = "收到 \(peerName) 发来的文字"
                }
                guard writeJSON(fd, ["type": "ok"]) else { return }

            case "file":
                guard let name = obj["name"] as? String,
                      let size = obj["size"] as? Int, size >= 0 else {
                    return
                }
                DispatchQueue.main.async {
                    self.statusKind = .idle
                    self.statusText = "正在接收 \(peerName) 发来的「\(name)」…"
                }
                guard let url = receiveFile(fd, name: name, size: size) else {
                    _ = writeJSON(fd, ["type": "error", "message": "保存文件失败"])
                    return
                }
                self.appendMessage(LANMessage(direction: .incoming,
                                              peerName: peerName,
                                              fileURL: url,
                                              fileSize: size),
                                   peerID: peerID)
                DispatchQueue.main.async {
                    self.statusKind = .success
                    self.statusText = "已收到「\(url.lastPathComponent)」，存在 \(url.deletingLastPathComponent().path)"
                }
                guard writeJSON(fd, ["type": "ok"]) else { return }

            case "bye":
                return

            default:
                return
            }
        }
    }

    private func receiveFile(_ fd: Int32, name: String, size: Int) -> URL? {
        let manager = FileManager.default
        let directory = URL(fileURLWithPath: receiveDir, isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = (name as NSString).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else { return nil }

        var url = directory.appendingPathComponent(safeName)
        let base = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        var index = 2
        while manager.fileExists(atPath: url.path) {
            let candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            url = directory.appendingPathComponent(candidate)
            index += 1
        }

        guard manager.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            return nil
        }

        var remaining = size
        while remaining > 0 {
            let want = min(256 * 1024, remaining)
            guard let chunk = readN(fd, want) else {
                try? handle.close()
                try? manager.removeItem(at: url)
                return nil
            }
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                try? handle.close()
                try? manager.removeItem(at: url)
                return nil
            }
            remaining -= chunk.count
        }
        try? handle.close()
        return url
    }

    // MARK: - 网络工具

    private func remoteHost(_ fd: Int32) -> String {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &len)
            }
        }
        guard result == 0 else { return "" }
        var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var address = addr.sin_addr
        inet_ntop(AF_INET, &address, &chars, socklen_t(INET_ADDRSTRLEN))
        return String(cString: chars)
    }

    /// 发送前自动重试连接几次，避开 Wi-Fi 抖动 / 对端刚启动时的偶发失败。
    private func connectWithRetry(to peer: LANPeer, attempts: Int = 3) -> Int32? {
        guard attempts > 0 else { return nil }
        for attempt in 1...attempts {
            if isSendCancelled { return nil }
            if let fd = connect(to: peer) { return fd }
            if attempt < attempts {
                Thread.sleep(forTimeInterval: attempt == 1 ? 0.6 : 1.4)
            }
        }
        return nil
    }

    private func connect(to peer: LANPeer, timeoutSeconds: Int32 = 6) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                   socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = peer.port.bigEndian
        inet_pton(AF_INET, peer.host, &address.sin_addr)

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result != 0 {
            guard errno == EINPROGRESS else {
                close(fd)
                return nil
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, timeoutSeconds * 1000)
            guard ready > 0 else {
                close(fd)
                return nil
            }
            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength)
            guard socketError == 0 else {
                close(fd)
                return nil
            }
        }

        _ = fcntl(fd, F_SETFL, flags)
        setTimeout(fd, seconds: 30)
        return fd
    }

    private func setTimeout(_ fd: Int32, seconds: Int) {
        var value = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    private func readN(_ fd: Int32, _ count: Int) -> Data? {
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let readBytes = recv(fd, &buffer[offset], count - offset, 0)
            if readBytes <= 0 { return nil }
            offset += readBytes
        }
        return Data(buffer)
    }

    private func readFrame(_ fd: Int32) -> Data? {
        guard let header = readN(fd, 4) else { return nil }
        let bytes = [UInt8](header)
        let length = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16)
            | (Int(bytes[2]) << 8) | Int(bytes[3])
        guard length > 0, length <= 16 * 1024 * 1024 else { return nil }
        return readN(fd, length)
    }

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        var ok = true
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let written = send(fd, base.advanced(by: offset), data.count - offset, 0)
                if written <= 0 {
                    ok = false
                    return
                }
                offset += written
            }
        }
        return ok
    }

    private func writeJSON(_ fd: Int32, _ object: [String: Any]) -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: object),
              body.count <= 16 * 1024 * 1024 else {
            return false
        }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return writeAll(fd, frame)
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - 接收目录

    func chooseReceiveDir() {
        let panel = NSOpenPanel()
        panel.title = "选择接收文件的保存目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: receiveDir, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            receiveDir = url.path
            statusKind = .idle
            statusText = "接收目录已改为 \(url.path)"
        }
    }

    func copyText(_ message: LANMessage) {
        guard let text = message.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusKind = .success
        statusText = "已复制到剪贴板"
    }

    /// 文件消息对应的文件是否已经不在本地
    func fileMissing(_ message: LANMessage) -> Bool {
        guard message.kind == .file, let path = message.filePath, !path.isEmpty else { return true }
        return !FileManager.default.fileExists(atPath: path)
    }

    /// 打开接收目录（文件已不存在时，右键「打开接收目录」走这里）
    func openReceiveDirectory() {
        let dir = URL(fileURLWithPath: receiveDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// 查看文件：用系统默认 App 打开（图片 / 视频等）
    func previewFile(_ message: LANMessage) {
        guard let path = message.filePath, !path.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            statusKind = .failure
            statusText = "文件已经不在了：\(path)"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 打开文件所在位置；文件不在时退回到接收目录
    func openFileLocation(_ message: LANMessage) {
        guard let path = message.filePath, !path.isEmpty else {
            openReceiveDirectory()
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            statusKind = .idle
            statusText = "文件已经不在了，已打开接收目录"
            openReceiveDirectory()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func revealFile(_ message: LANMessage) {
        guard let path = message.filePath else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            statusKind = .idle
            statusText = "文件已经不在了，已打开接收目录"
            openReceiveDirectory()
            return
        }
        if message.direction == .incoming {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
