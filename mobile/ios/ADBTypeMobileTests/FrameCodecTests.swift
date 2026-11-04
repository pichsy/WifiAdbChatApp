import XCTest
@testable import ADBTypeMobile

final class FrameCodecTests: XCTestCase {
    func testEncodeWritesBigEndianLengthAndJSONBody() throws {
        let frame = try XCTUnwrap(FrameCodec.encode(["type": "ok"]))
        XCTAssertGreaterThan(frame.count, 4)
        let bytes = [UInt8](frame.prefix(4))
        let length = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        XCTAssertEqual(length, frame.count - 4)
        let body = frame.subdata(in: 4..<frame.count)
        let object = try XCTUnwrap(FrameCodec.decode(body))
        XCTAssertEqual(object["type"] as? String, "ok")
    }

    func testFrameLengthFromHeaderBounds() {
        XCTAssertNil(FrameCodec.frameLength(fromHeader: Data([0, 0, 0])))
        XCTAssertNil(FrameCodec.frameLength(fromHeader: makeHeader(0)))
        XCTAssertNil(FrameCodec.frameLength(fromHeader: makeHeader(LinkProtocol.maxFrameBytes + 1)))
        XCTAssertEqual(FrameCodec.frameLength(fromHeader: makeHeader(LinkProtocol.maxFrameBytes)),
                       LinkProtocol.maxFrameBytes)
        XCTAssertEqual(FrameCodec.frameLength(fromHeader: makeHeader(1)), 1)
    }

    func testUnicodeTextRoundTrip() throws {
        let text = "你好，世界 👋 emoji 🎉 \n第二行 \"quoted\""
        let frame = try XCTUnwrap(FrameCodec.encode(LinkMessages.text(text)))
        let body = frame.dropFirst(4)
        let object = try XCTUnwrap(FrameCodec.decode(Data(body)))
        XCTAssertEqual(object["type"] as? String, "text")
        XCTAssertEqual(object["text"] as? String, text)
    }

    func testDecodeRejectsInvalidJSON() {
        XCTAssertNil(FrameCodec.decode(Data("not json".utf8)))
        XCTAssertNil(FrameCodec.decode(Data("[1,2,3]".utf8)))
        XCTAssertNil(FrameCodec.decode(Data("\"string\"".utf8)))
    }

    private func makeHeader(_ length: Int) -> Data {
        let value = UInt32(length)
        return Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }
}
