import Foundation

/// 配对关系与好友名册的持久化：
/// - paired.json：已配对设备 ID 数组（规格 §8）；
/// - friends.json：好友记录（id / name / host / port / lastSeen / alias）。
final class FriendStore {
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL = AppDirectories.supportDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    var pairedFileURL: URL { directory.appendingPathComponent("paired.json") }
    var friendsFileURL: URL { directory.appendingPathComponent("friends.json") }

    func loadPairedIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: pairedFileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(list)
    }

    func savePairedIDs(_ ids: Set<String>) {
        guard let data = try? JSONEncoder().encode(ids.sorted()) else { return }
        ensureDirectory()
        try? data.write(to: pairedFileURL, options: .atomic)
    }

    /// 好友列表 = friends.json 里的记录 + 只在 paired.json 里的设备（名字等上线后补全）。
    func loadFriends(pairedIDs: Set<String>) -> [LANPeer] {
        var result: [LANPeer] = []
        if let data = try? Data(contentsOf: friendsFileURL),
           let records = try? JSONDecoder().decode([StoredFriend].self, from: data) {
            result = records.map {
                LANPeer(id: $0.id,
                        name: $0.name,
                        host: $0.host,
                        port: $0.port,
                        lastSeen: $0.lastSeen,
                        online: false,
                        alias: $0.alias)
            }
        }
        let knownIDs = Set(result.map(\.id))
        for id in pairedIDs where !knownIDs.contains(id) {
            result.append(LANPeer(id: id,
                                  name: "已配对设备",
                                  host: "",
                                  port: 0,
                                  lastSeen: .distantPast,
                                  online: false))
        }
        return result.sorted(by: FriendStore.sortByName)
    }

    func saveFriends(_ friends: [LANPeer]) {
        let records = friends.map {
            StoredFriend(id: $0.id,
                         name: $0.name,
                         host: $0.host,
                         port: $0.port,
                         lastSeen: $0.lastSeen,
                         alias: $0.alias)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        ensureDirectory()
        try? data.write(to: friendsFileURL, options: .atomic)
    }

    static func sortByName(_ lhs: LANPeer, _ rhs: LANPeer) -> Bool {
        lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private func ensureDirectory() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
