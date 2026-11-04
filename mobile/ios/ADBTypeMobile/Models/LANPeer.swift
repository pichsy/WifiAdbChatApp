import Foundation

/// 局域网里的一台电脑。既用于「附近设备」（UDP 发现的实时信息），
/// 也用于「已配对」好友（friends.json 持久化，离线也保留）。
struct LANPeer: Identifiable, Hashable {
    let id: String
    var name: String
    var host: String
    var port: UInt16
    var lastSeen: Date
    /// 最近 8 秒内收到过对方广播/单播心跳。离线好友仍保留在列表里。
    var online: Bool = false
    /// 本地别名（friends.json）；当前 iOS 端未提供改名入口，保留协议字段。
    var alias: String? = nil

    var displayName: String {
        if let alias {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "电脑" : trimmedName
    }

    /// 广播里通告了可连接的地址和端口
    var hasAddress: Bool { !host.isEmpty && port > 0 }
}
