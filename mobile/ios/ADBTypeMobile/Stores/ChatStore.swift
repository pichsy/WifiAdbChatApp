import Foundation

/// 每台电脑一份聊天记录：chats/<设备ID>.json，最多保留 500 条（规格 §8）。
final class ChatStore {
    static let maxMessagesPerPeer = 500

    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL = AppDirectories.chatsDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// 设备 ID 里的 "/" 和 ":" 换成 "_"，避免生成非法文件名。
    static func fileName(for peerID: String) -> String {
        let sanitized = peerID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let name = sanitized.isEmpty ? "unknown" : sanitized
        return "\(name).json"
    }

    func loadAll() -> [String: [LANMessage]] {
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var result: [String: [LANMessage]] = [:]
        for url in urls where url.pathExtension == "json" {
            let peerID = url.deletingPathExtension().lastPathComponent
            if let messages = load(peerID: peerID), !messages.isEmpty {
                result[peerID] = messages
            }
        }
        return result
    }

    func load(peerID: String) -> [LANMessage]? {
        let url = directory.appendingPathComponent(Self.fileName(for: peerID))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([LANMessage].self, from: data)
    }

    func save(_ messages: [LANMessage], peerID: String) {
        let capped = Array(messages.suffix(Self.maxMessagesPerPeer))
        guard let data = try? JSONEncoder().encode(capped) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(Self.fileName(for: peerID)), options: .atomic)
    }
}
