import Foundation

/// 一条聊天记录。字段与电脑端 LANMessage / 规格 §8 保持一致：
/// id、direction、peerName、date、kind、text、fileName、filePath、fileSize，
/// 空的可选字段不写进 JSON；date 是 Swift Date 的默认编码（2001-01-01 起的秒数）。
struct LANMessage: Identifiable, Codable, Hashable {
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

    init(id: UUID = UUID(),
         direction: Direction,
         peerName: String,
         date: Date = Date(),
         text: String) {
        self.id = id
        self.direction = direction
        self.peerName = peerName
        self.date = date
        self.kind = .text
        self.text = text
        self.fileName = nil
        self.filePath = nil
        self.fileSize = nil
    }

    init(id: UUID = UUID(),
         direction: Direction,
         peerName: String,
         date: Date = Date(),
         fileURL: URL,
         fileSize: Int?) {
        self.id = id
        self.direction = direction
        self.peerName = peerName
        self.date = date
        self.kind = .file
        self.text = nil
        self.fileName = fileURL.lastPathComponent
        self.filePath = fileURL.path
        self.fileSize = fileSize
    }

    var fileURL: URL? {
        guard let filePath, !filePath.isEmpty else { return nil }
        return URL(fileURLWithPath: filePath)
    }

    /// 文件是否还存在于本地（聊天记录里的路径只做展示，App 容器重装后可能失效）。
    var fileExists: Bool {
        guard kind == .file, let fileURL else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
}
