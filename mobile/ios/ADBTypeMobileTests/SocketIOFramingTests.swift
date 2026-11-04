import XCTest
import Darwin
@testable import ADBTypeMobile

final class SocketIOFramingTests: XCTestCase {
    func testFrameRoundTripOverSocketPair() throws {
        let pair = try makeSocketPair()
        defer {
            close(pair.write)
            close(pair.read)
        }

        let hello = LinkMessages.hello(id: "phone-id", name: "测试 iPhone 📱", code: "123456")
        XCTAssertTrue(SocketIO.writeJSON(pair.write, hello))

        let body = try XCTUnwrap(SocketIO.readFrame(pair.read))
        let object = try XCTUnwrap(FrameCodec.decode(body))
        XCTAssertEqual(object["id"] as? String, "phone-id")
        XCTAssertEqual(object["name"] as? String, "测试 iPhone 📱")
        XCTAssertEqual(object["code"] as? String, "123456")
    }

    func testMultipleFramesStayFramed() throws {
        let pair = try makeSocketPair()
        defer {
            close(pair.write)
            close(pair.read)
        }

        XCTAssertTrue(SocketIO.writeJSON(pair.write, LinkMessages.text("第一条")))
        XCTAssertTrue(SocketIO.writeJSON(pair.write, LinkMessages.ok()))

        let first = try XCTUnwrap(FrameCodec.decode(try XCTUnwrap(SocketIO.readFrame(pair.read))))
        let second = try XCTUnwrap(FrameCodec.decode(try XCTUnwrap(SocketIO.readFrame(pair.read))))
        XCTAssertEqual(first["text"] as? String, "第一条")
        XCTAssertEqual(second["type"] as? String, "ok")
    }

    func testInvalidLengthHeaderTerminatesRead() throws {
        let pair = try makeSocketPair()
        defer {
            close(pair.write)
            close(pair.read)
        }
        // 0 长度是非法帧
        XCTAssertTrue(SocketIO.writeAll(pair.write, Data([0, 0, 0, 0])))
        XCTAssertNil(SocketIO.readFrame(pair.read))
    }

    func testReadExactlyReturnsNilOnEOF() throws {
        let pair = try makeSocketPair()
        close(pair.write)
        XCTAssertNil(SocketIO.readExactly(pair.read, count: 4))
        close(pair.read)
    }

    func testReadExactlyReadsRequestedBytesOnly() throws {
        let pair = try makeSocketPair()
        defer {
            close(pair.write)
            close(pair.read)
        }
        XCTAssertTrue(SocketIO.writeAll(pair.write, Data("abcdef".utf8)))
        XCTAssertEqual(SocketIO.readExactly(pair.read, count: 3), Data("abc".utf8))
        XCTAssertEqual(SocketIO.readExactly(pair.read, count: 3), Data("def".utf8))
        XCTAssertEqual(SocketIO.readExactly(pair.read, count: 0), Data())
    }

    private struct SocketPair {
        let read: Int32
        let write: Int32
    }

    private func makeSocketPair() throws -> SocketPair {
        var fds: [Int32] = [-1, -1]
        let result = fds.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        guard result == 0 else {
            throw NSError(domain: "SocketIOFramingTests", code: Int(errno))
        }
        return SocketPair(read: fds[1], write: fds[0])
    }
}
