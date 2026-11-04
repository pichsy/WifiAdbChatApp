import XCTest
@testable import ADBTypeMobile

final class LinkMessagesTests: XCTestCase {
    func testProtocolConstantsMatchSpec() {
        XCTAssertEqual(LinkProtocol.appTag, "ADBTypeLink")
        XCTAssertEqual(LinkProtocol.version, 1)
        XCTAssertEqual(LinkProtocol.discoveryPort, 52730)
        XCTAssertEqual(LinkProtocol.maxFrameBytes, 16 * 1024 * 1024)
        XCTAssertEqual(LinkProtocol.fileChunkBytes, 256 * 1024)
        XCTAssertEqual(LinkProtocol.connectTimeout, 6)
        XCTAssertEqual(LinkProtocol.ioTimeout, 30)
        XCTAssertEqual(LinkProtocol.announceInterval, 2)
        XCTAssertEqual(LinkProtocol.offlineThreshold, 8)
    }

    func testAnnouncementFields() throws {
        let payload = LinkMessages.announce(id: "device-id", name: "iPhone", port: 43210)
        XCTAssertEqual(payload["app"] as? String, "ADBTypeLink")
        XCTAssertEqual(payload["v"] as? Int, 1)
        XCTAssertEqual(payload["id"] as? String, "device-id")
        XCTAssertEqual(payload["name"] as? String, "iPhone")
        XCTAssertEqual(payload["port"] as? Int, 43210)
        // 广播报文里没有 type 字段
        XCTAssertNil(payload["type"])
    }

    func testHelloCodeIsOptionalAndTrimmed() {
        let plain = LinkMessages.hello(id: "id", name: "手机", code: nil)
        XCTAssertNil(plain["code"])

        let empty = LinkMessages.hello(id: "id", name: "手机", code: "   ")
        XCTAssertNil(empty["code"])

        let withCode = LinkMessages.hello(id: "id", name: "手机", code: " 123456 ")
        XCTAssertEqual(withCode["code"] as? String, "123456")
        XCTAssertEqual(withCode["app"] as? String, "ADBTypeLink")
        XCTAssertEqual(withCode["v"] as? Int, 1)
    }

    func testContentMessageShapes() {
        XCTAssertEqual(LinkMessages.helloOk(name: "Mac", id: "mac-id")["type"] as? String, "hello_ok")
        XCTAssertEqual(LinkMessages.pairRequired(name: "Mac")["name"] as? String, "Mac")
        XCTAssertEqual(LinkMessages.error("坏了")["message"] as? String, "坏了")
        XCTAssertEqual(LinkMessages.text("你好")["text"] as? String, "你好")
        XCTAssertEqual(LinkMessages.file(name: "a.bin", size: 12)["size"] as? Int, 12)
        XCTAssertEqual(LinkMessages.ok()["type"] as? String, "ok")
        XCTAssertEqual(LinkMessages.bye()["type"] as? String, "bye")
    }

    func testPairingPromptCopy() {
        let prompt = PairingPrompt(peerID: "p", peerName: "书房电脑", mode: .beforeSend)
        XCTAssertEqual(prompt.title, "与「书房电脑」配对")
        XCTAssertEqual(prompt.confirmTitle, "配对并发送")
        XCTAssertTrue(prompt.message.contains("首次给「书房电脑」发送"))

        let manual = PairingPrompt(peerID: "p", peerName: "书房电脑", mode: .manual)
        XCTAssertEqual(manual.confirmTitle, "配对")
    }
}
