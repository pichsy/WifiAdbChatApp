import XCTest
@testable import ADBTypeMobile

final class DiscoveryPacketTests: XCTestCase {
    private let localID = "local-device-id"

    func testParsesValidAnnouncement() throws {
        let packet = try XCTUnwrap(DiscoveryPacket.parse(
            makeData([
                "app": "ADBTypeLink",
                "v": 1,
                "id": "peer-1",
                "name": "pichs 的 MacBook Pro",
                "port": 51234
            ]),
            localDeviceID: localID))
        XCTAssertEqual(packet.peerID, "peer-1")
        XCTAssertEqual(packet.name, "pichs 的 MacBook Pro")
        XCTAssertEqual(packet.port, 51234)
    }

    func testIgnoresSelf() {
        XCTAssertNil(DiscoveryPacket.parse(
            makeData(["app": "ADBTypeLink", "v": 1, "id": localID, "name": "自己", "port": 5000]),
            localDeviceID: localID))
    }

    func testRejectsInvalidFields() {
        let invalidPayloads: [[String: Any]] = [
            ["app": "OtherApp", "id": "peer", "name": "电脑", "port": 5000],
            ["app": "ADBTypeLink", "id": "", "name": "电脑", "port": 5000],
            ["app": "ADBTypeLink", "id": "peer", "name": "", "port": 5000],
            ["app": "ADBTypeLink", "id": "peer", "name": "   ", "port": 5000],
            ["app": "ADBTypeLink", "id": "peer", "name": "电脑", "port": 0],
            ["app": "ADBTypeLink", "id": "peer", "name": "电脑", "port": 65536],
            ["app": "ADBTypeLink", "id": "peer", "name": "电脑"],
            ["app": "ADBTypeLink", "id": 123, "name": "电脑", "port": 5000],
            ["app": "ADBTypeLink", "id": "peer", "name": "电脑", "port": "5000"]
        ]
        for payload in invalidPayloads {
            XCTAssertNil(DiscoveryPacket.parse(makeData(payload), localDeviceID: localID),
                         "应当丢弃非法报文：\(payload)")
        }
    }

    func testAcceptsUnknownProtocolVersionForForwardCompatibility() throws {
        let packet = try XCTUnwrap(DiscoveryPacket.parse(
            makeData(["app": "ADBTypeLink", "v": 99, "id": "peer", "name": "Windows", "port": 6000]),
            localDeviceID: localID))
        XCTAssertEqual(packet.port, 6000)
    }

    func testRejectsMalformedData() {
        XCTAssertNil(DiscoveryPacket.parse(Data("not-json".utf8), localDeviceID: localID))
        XCTAssertNil(DiscoveryPacket.parse(Data("[1,2,3]".utf8), localDeviceID: localID))
        XCTAssertNil(DiscoveryPacket.parse(Data(), localDeviceID: localID))
    }

    private func makeData(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
