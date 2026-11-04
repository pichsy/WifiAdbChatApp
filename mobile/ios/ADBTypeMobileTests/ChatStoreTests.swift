import XCTest
@testable import ADBTypeMobile

final class ChatStoreTests: XCTestCase {
    func testSaveAndLoadRoundTrip() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatStore(directory: directory)

        let textMessage = LANMessage(direction: .incoming, peerName: "电脑", text: "你好 👋")
        let fileURL = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: fileURL)
        let fileMessage = LANMessage(direction: .outgoing,
                                     peerName: "电脑",
                                     fileURL: fileURL,
                                     fileSize: 5)

        store.save([textMessage, fileMessage], peerID: "peer-1")
        let loaded = try XCTUnwrap(store.load(peerID: "peer-1"))
        XCTAssertEqual(loaded, [textMessage, fileMessage])
        XCTAssertEqual(loaded.first?.text, "你好 👋")
        XCTAssertEqual(loaded.last?.fileSize, 5)
    }

    func testEachPeerKeepsSeparateConversation() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatStore(directory: directory)

        store.save([LANMessage(direction: .incoming, peerName: "A", text: "from A")], peerID: "peer-a")
        store.save([LANMessage(direction: .incoming, peerName: "B", text: "from B")], peerID: "peer-b")

        XCTAssertEqual(store.load(peerID: "peer-a")?.first?.text, "from A")
        XCTAssertEqual(store.load(peerID: "peer-b")?.first?.text, "from B")
        XCTAssertEqual(Set(store.loadAll().keys), ["peer-a", "peer-b"])
    }

    func testKeepsOnlyLatest500Messages() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatStore(directory: directory)

        let messages = (0..<510).map {
            LANMessage(direction: .outgoing, peerName: "电脑", text: "m\($0)")
        }
        store.save(messages, peerID: "peer-cap")
        let loaded = try XCTUnwrap(store.load(peerID: "peer-cap"))
        XCTAssertEqual(loaded.count, ChatStore.maxMessagesPerPeer)
        XCTAssertEqual(loaded.first?.text, "m10")
        XCTAssertEqual(loaded.last?.text, "m509")
    }

    func testChatFileNameSanitizesDeviceID() {
        XCTAssertEqual(ChatStore.fileName(for: "abc-123"), "abc-123.json")
        XCTAssertEqual(ChatStore.fileName(for: "a/b:c"), "a_b_c.json")
        XCTAssertEqual(ChatStore.fileName(for: ""), "unknown.json")
    }

    func testMessageJSONMatchesSpecShape() throws {
        let message = LANMessage(direction: .outgoing,
                                 peerName: "电脑",
                                 date: Date(timeIntervalSinceReferenceDate: 123.456),
                                 text: "hi")
        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["direction"] as? String, "outgoing")
        XCTAssertEqual(object["kind"] as? String, "text")
        XCTAssertEqual(object["peerName"] as? String, "电脑")
        XCTAssertEqual(object["text"] as? String, "hi")
        XCTAssertNotNil(object["id"] as? String)
        // date 是 Swift Date 默认编码（2001-01-01 起的秒数），不是字符串
        let date = try XCTUnwrap(object["date"] as? NSNumber)
        XCTAssertEqual(date.doubleValue, 123.456, accuracy: 0.001)
        // 空的可选字段不应出现
        XCTAssertNil(object["fileName"])
        XCTAssertNil(object["filePath"])
        XCTAssertNil(object["fileSize"])
        XCTAssertNil(object["peerId"])
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTypeMobileChatStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
