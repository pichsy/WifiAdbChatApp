import XCTest
@testable import ADBTypeMobile

final class FriendStoreTests: XCTestCase {
    func testPairedIDsRoundTrip() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FriendStore(directory: directory)

        XCTAssertEqual(store.loadPairedIDs(), [])
        store.savePairedIDs(["id-b", "id-a"])
        XCTAssertEqual(store.loadPairedIDs(), ["id-a", "id-b"])

        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: store.pairedFileURL)))
        XCTAssertEqual(raw as? [String], ["id-a", "id-b"])
    }

    func testFriendsRoundTripKeepsFieldsAndAlias() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FriendStore(directory: directory)

        let seen = Date(timeIntervalSinceReferenceDate: 42)
        let friend = LANPeer(id: "peer-1",
                             name: "pichs 的 MacBook Pro",
                             host: "192.168.1.10",
                             port: 51234,
                             lastSeen: seen,
                             online: false,
                             alias: "书房电脑")
        store.saveFriends([friend])

        let loaded = store.loadFriends(pairedIDs: [])
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "peer-1")
        XCTAssertEqual(loaded[0].name, "pichs 的 MacBook Pro")
        XCTAssertEqual(loaded[0].host, "192.168.1.10")
        XCTAssertEqual(loaded[0].port, 51234)
        XCTAssertEqual(loaded[0].alias, "书房电脑")
        XCTAssertEqual(loaded[0].lastSeen.timeIntervalSinceReferenceDate, 42, accuracy: 0.001)

        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: store.friendsFileURL)) as? [[String: Any]])
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw[0]["id"] as? String, "peer-1")
        XCTAssertEqual(raw[0]["alias"] as? String, "书房电脑")
        XCTAssertNil(raw[0]["peerId"])
        XCTAssertNotNil(raw[0]["lastSeen"] as? NSNumber)
        XCTAssertNotNil(raw[0]["lastSeen"] as? NSNumber)
    }

    func testPairedIDWithoutFriendGetsPlaceholder() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FriendStore(directory: directory)

        let friends = store.loadFriends(pairedIDs: ["only-paired-id"])
        XCTAssertEqual(friends.count, 1)
        XCTAssertEqual(friends[0].id, "only-paired-id")
        XCTAssertEqual(friends[0].name, "已配对设备")
        XCTAssertFalse(friends[0].online)
    }

    func testFriendsSortedByName() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FriendStore(directory: directory)

        store.saveFriends([
            LANPeer(id: "b", name: "B 电脑", host: "", port: 0, lastSeen: Date()),
            LANPeer(id: "a", name: "A 电脑", host: "", port: 0, lastSeen: Date())
        ])
        XCTAssertEqual(store.loadFriends(pairedIDs: []).map(\.id), ["a", "b"])
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTypeMobileFriendStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
