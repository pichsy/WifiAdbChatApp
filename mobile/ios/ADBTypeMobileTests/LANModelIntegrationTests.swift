import Foundation
import XCTest
import Darwin
@testable import ADBTypeMobile

/// 本机回环上的端到端协议测试：
/// - App 作为服务端接收电脑发来的配对 / 文字 / 文件；
/// - App 作为客户端向「电脑」发送文字 / 文件，并覆盖首次配对后自动重发。
final class LANModelIntegrationTests: XCTestCase {
    // MARK: - 服务端：接收

    func testReceivesPairingTextAndFiles() throws {
        let env = try makeEnvironment()
        defer { cleanup(env) }
        let model = makeModel(env)
        model.start()

        waitUntil("TCP 监听端口就绪") {
            model.listeningPortSnapshot() > 0 && model.serverReady
        }
        let port = model.listeningPortSnapshot()
        XCTAssertGreaterThan(port, 0)

        let peerID = "test-peer-\(UUID().uuidString)"
        let peerName = "测试电脑"
        let wrongCode = wrongPairingCode(for: model.pairingCode)

        // 1) 错误配对码 → pair_required，界面记录「正在请求配对」
        let first = try XCTUnwrap(SocketIO.connect(host: "127.0.0.1", port: port, timeout: 3))
        XCTAssertTrue(SocketIO.writeJSON(first, LinkMessages.hello(id: peerID, name: peerName, code: wrongCode)))
        XCTAssertEqual(try readType(first), "pair_required")
        close(first)

        waitUntil("界面收到配对请求") {
            model.pendingPairPeerID == peerID && model.pendingPairName == peerName
        }

        // 2) 正确配对码 → hello_ok，然后发文字 / 文件
        let second = try XCTUnwrap(SocketIO.connect(host: "127.0.0.1", port: port, timeout: 3))
        XCTAssertTrue(SocketIO.writeJSON(second, LinkMessages.hello(id: peerID,
                                                                     name: peerName,
                                                                     code: model.pairingCode)))
        let helloOk = try XCTUnwrap(try readObject(second))
        XCTAssertEqual(helloOk["type"] as? String, "hello_ok")
        XCTAssertEqual(helloOk["name"] as? String, "测试 iPhone")
        XCTAssertEqual(helloOk["id"] as? String, model.deviceID)

        let text = "你好 👋 emoji 🎉 中文"
        XCTAssertTrue(SocketIO.writeJSON(second, LinkMessages.text(text)))
        XCTAssertEqual(try readType(second), "ok")

        let fileData = Data("file content 中文 📦".utf8)
        XCTAssertTrue(SocketIO.writeJSON(second, LinkMessages.file(name: "../../evil.txt", size: fileData.count)))
        XCTAssertTrue(SocketIO.writeAll(second, fileData))
        XCTAssertEqual(try readType(second), "ok")

        // 同名再发一次 → 自动编号
        XCTAssertTrue(SocketIO.writeJSON(second, LinkMessages.file(name: "evil.txt", size: fileData.count)))
        XCTAssertTrue(SocketIO.writeAll(second, fileData))
        XCTAssertEqual(try readType(second), "ok")

        XCTAssertTrue(SocketIO.writeJSON(second, LinkMessages.bye()))
        close(second)

        waitUntil("聊天记录收到 3 条消息") {
            model.messages(for: peerID).count == 3
        }
        let messages = model.messages(for: peerID)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages.first?.kind, .text)
        XCTAssertEqual(messages.first?.direction, .incoming)
        XCTAssertEqual(messages.first?.text, text)
        XCTAssertEqual(messages[1].kind, .file)
        XCTAssertEqual(messages[2].kind, .file)
        XCTAssertTrue(model.isPaired(peerID))
        XCTAssertNil(model.pendingPairPeerID)

        // 新文件保存到 Documents/Downloads（「文件」App 可见），
        // 路径穿越被清理成最后一段，重名自动加编号
        let savedNames = try FileManager.default.contentsOfDirectory(atPath: env.downloads.path).sorted()
        XCTAssertEqual(savedNames, ["evil (2).txt", "evil.txt"])
        XCTAssertEqual(try Data(contentsOf: env.downloads.appendingPathComponent("evil.txt")), fileData)

        // 3) 非法文件名（".."）被拒绝：回 error 并关闭
        let third = try XCTUnwrap(SocketIO.connect(host: "127.0.0.1", port: port, timeout: 3))
        XCTAssertTrue(SocketIO.writeJSON(third, LinkMessages.hello(id: peerID, name: peerName, code: nil)))
        XCTAssertEqual(try readType(third), "hello_ok")
        XCTAssertTrue(SocketIO.writeJSON(third, LinkMessages.file(name: "..", size: 0)))
        XCTAssertEqual(try readType(third), "error")
        close(third)
        XCTAssertEqual(model.messages(for: peerID).count, 3)

        // 4) 持久化：paired.json / friends.json / chats/<id>.json
        XCTAssertEqual(env.friendStore.loadPairedIDs(), [peerID])
        XCTAssertEqual(env.friendStore.loadFriends(pairedIDs: [peerID]).first?.id, peerID)
        XCTAssertEqual(try env.chatStore.load(peerID: peerID)?.count, 3)
    }

    // MARK: - 客户端：发送

    func testSendsTextAndFilesAfterPairingRetry() throws {
        let env = try makeEnvironment()
        defer { cleanup(env) }
        let server = try FakePeerServer()
        server.start()
        defer { server.stop() }

        let model = makeModel(env)
        model.start()

        let peer = LANPeer(id: "fake-peer-id",
                           name: "假电脑",
                           host: "127.0.0.1",
                           port: server.port,
                           lastSeen: Date(),
                           online: true)

        // 首次发送：对方回 pair_required → 界面弹出配对框，内容暂存在待重发队列
        model.sendText("你好 👋 来自 iOS", to: peer)
        waitUntil("首次发送弹出配对框") {
            model.pairingPrompt != nil
        }
        XCTAssertEqual(model.pairingPrompt?.mode, .beforeSend)
        XCTAssertEqual(model.pairingPrompt?.peerID, peer.id)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(server.texts, [])

        // 配对码错误 → 弹窗里显示错误，继续可重试
        model.submitPairingCode("000000")
        waitUntil("配对码错误的提示出现") {
            model.pairingPrompt?.errorText?.contains("配对码不对") == true
        }
        XCTAssertEqual(model.pairingPrompt?.peerID, peer.id)

        // 配对码正确 → 配对成功并自动重发刚才的文字
        model.submitPairingCode("123456")
        waitUntil("配对后自动重发文字") {
            server.texts == ["你好 👋 来自 iOS"] && model.messages(for: peer.id).count == 1
        }
        XCTAssertNil(model.pairingPrompt)
        XCTAssertTrue(model.isPaired(peer.id))
        XCTAssertEqual(server.helloCodes, [nil, "000000", "123456", nil])
        let textMessage = try XCTUnwrap(model.messages(for: peer.id).first)
        XCTAssertEqual(textMessage.kind, .text)
        XCTAssertEqual(textMessage.direction, .outgoing)
        XCTAssertEqual(textMessage.text, "你好 👋 来自 iOS")

        // 已配对后发文件
        let fileURL = env.root.appendingPathComponent("发送测试.txt")
        let fileData = Data("file from iOS 📎 中文".utf8)
        try fileData.write(to: fileURL)
        model.sendFiles([fileURL], to: peer)
        waitUntil("文件发送成功") {
            server.files.count == 1 && model.messages(for: peer.id).count == 2
        }
        let fileMessage = try XCTUnwrap(model.messages(for: peer.id).last)
        XCTAssertEqual(fileMessage.kind, .file)
        XCTAssertEqual(fileMessage.direction, .outgoing)
        XCTAssertEqual(fileMessage.fileName, "发送测试.txt")
        XCTAssertEqual(fileMessage.fileSize, fileData.count)
        XCTAssertEqual(fileMessage.filePath, fileURL.path)
        XCTAssertEqual(server.files.first?.0, "发送测试.txt")
        XCTAssertEqual(server.files.first?.1, fileData)
        XCTAssertEqual(server.helloCodes, [nil, "000000", "123456", nil, nil])

        // 持久化
        XCTAssertEqual(try env.chatStore.load(peerID: peer.id)?.count, 2)
        XCTAssertEqual(env.friendStore.loadPairedIDs(), [peer.id])
    }

    // MARK: - 旧 Received 迁移

    func testMigratesLegacyReceivedFilesAndChatPaths() throws {
        let env = try makeEnvironment()
        defer { cleanup(env) }

        let legacyFile = env.legacyReceived.appendingPathComponent("旧文件.txt")
        try FileManager.default.createDirectory(at: env.legacyReceived, withIntermediateDirectories: true)
        let data = Data("legacy content 旧文件 📦".utf8)
        try data.write(to: legacyFile)

        let peerID = "legacy-peer"
        let message = LANMessage(direction: .incoming,
                                 peerName: "旧电脑",
                                 fileURL: legacyFile,
                                 fileSize: data.count)
        env.chatStore.save([message], peerID: peerID)

        // LANModel 初始化时自动把 Documents/Received 迁到 Documents/Downloads，并修正聊天记录路径
        let model = makeModel(env)

        let migratedURL = env.downloads.appendingPathComponent("旧文件.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertEqual(try Data(contentsOf: migratedURL), data)
        XCTAssertEqual(model.messages(for: peerID).first?.filePath, migratedURL.path)

        let stored = try XCTUnwrap(env.chatStore.load(peerID: peerID)?.first)
        XCTAssertEqual(stored.filePath, migratedURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.legacyReceived.path))
    }

    // MARK: - 工具

    private struct TestEnvironment {
        let root: URL
        let downloads: URL
        let legacyReceived: URL
        let friendStore: FriendStore
        let chatStore: ChatStore
        let suiteName: String
    }

    private func makeEnvironment() throws -> TestEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTypeMobileIntegration-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        let downloads = root.appendingPathComponent("Documents/Downloads", isDirectory: true)
        let legacyReceived = root.appendingPathComponent("Documents/Received", isDirectory: true)
        for directory in [support, chats, downloads] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return TestEnvironment(root: root,
                               downloads: downloads,
                               legacyReceived: legacyReceived,
                               friendStore: FriendStore(directory: support),
                               chatStore: ChatStore(directory: chats),
                               suiteName: "ADBTypeMobileIntegration-\(UUID().uuidString)")
    }

    private func makeModel(_ env: TestEnvironment) -> LANModel {
        let defaults = UserDefaults(suiteName: env.suiteName) ?? .standard
        return LANModel(defaults: defaults,
                        friendStore: env.friendStore,
                        chatStore: env.chatStore,
                        receivedDirectory: env.downloads,
                        legacyReceivedDirectory: env.legacyReceived,
                        overrideDeviceName: "测试 iPhone")
    }

    private func cleanup(_ env: TestEnvironment) {
        try? FileManager.default.removeItem(at: env.root)
        UserDefaults(suiteName: env.suiteName)?.removePersistentDomain(forName: env.suiteName)
    }

    private func waitUntil(_ message: String,
                           timeout: TimeInterval = 8,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func readObject(_ fd: Int32) throws -> [String: Any]? {
        guard let data = SocketIO.readFrame(fd) else { return nil }
        return FrameCodec.decode(data)
    }

    private func readType(_ fd: Int32) throws -> String? {
        try readObject(fd)?["type"] as? String
    }

    private func wrongPairingCode(for code: String) -> String {
        let first = code.first.map(String.init) ?? "0"
        return first == "0" ? "1" + code.dropFirst() : "0" + code.dropFirst()
    }
}

/// 冒充电脑端的最小 TCP 服务：第一次无码连接回 pair_required；
/// 带码连接校验 123456；配对成功后接受 text / file 并回 ok。
private final class FakePeerServer {
    let port: UInt16
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "tests.fake-peer-server")
    private let lock = NSLock()
    private var closed = false
    private var helloCodesStorage: [String?] = []
    private var textsStorage: [String] = []
    private var filesStorage: [(String, Data)] = []
    private let expectedCode = "123456"

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "FakePeerServer", code: 1) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw NSError(domain: "FakePeerServer", code: 2)
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: actual.sin_port)
    }

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            while true {
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(self.listenFD, $0, &clientLen)
                    }
                }
                if client < 0 { return }
                SocketIO.setIODeadline(client, seconds: 5)
                self.handle(client)
                close(client)
            }
        }
    }

    func stop() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
    }

    var helloCodes: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return helloCodesStorage
    }

    var texts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return textsStorage
    }

    var files: [(String, Data)] {
        lock.lock()
        defer { lock.unlock() }
        return filesStorage
    }

    private func handle(_ fd: Int32) {
        guard let helloData = SocketIO.readFrame(fd),
              let hello = FrameCodec.decode(helloData) else {
            return
        }
        let code = hello["code"] as? String
        lock.lock()
        helloCodesStorage.append(code)
        let connectionNumber = helloCodesStorage.count
        lock.unlock()

        if let code {
            if code == expectedCode {
                _ = SocketIO.writeJSON(fd, LinkMessages.helloOk(name: "假电脑", id: "fake-peer-id"))
                _ = SocketIO.readFrame(fd) // 配对连接上的 bye
            } else {
                _ = SocketIO.writeJSON(fd, LinkMessages.pairRequired(name: "假电脑"))
            }
            return
        }

        // 第一次无码连接 = 首次发送，要求配对
        if connectionNumber == 1 {
            _ = SocketIO.writeJSON(fd, LinkMessages.pairRequired(name: "假电脑"))
            return
        }

        guard SocketIO.writeJSON(fd, LinkMessages.helloOk(name: "假电脑", id: "fake-peer-id")) else {
            return
        }
        while let frame = SocketIO.readFrame(fd),
              let object = FrameCodec.decode(frame),
              let type = object["type"] as? String {
            switch type {
            case "text":
                lock.lock()
                textsStorage.append(object["text"] as? String ?? "")
                lock.unlock()
                guard SocketIO.writeJSON(fd, LinkMessages.ok()) else { return }
            case "file":
                guard let name = object["name"] as? String,
                      let size = object["size"] as? Int,
                      let data = SocketIO.readExactly(fd, count: size) else {
                    return
                }
                lock.lock()
                filesStorage.append((name, data))
                lock.unlock()
                guard SocketIO.writeJSON(fd, LinkMessages.ok()) else { return }
            case "bye":
                return
            default:
                return
            }
        }
    }
}
