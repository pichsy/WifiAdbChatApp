import Foundation

/// friends.json 的一条记录，字段与电脑端完全一致（id / name / host / port / lastSeen / alias）。
struct StoredFriend: Codable, Equatable {
    var id: String
    var name: String
    var host: String
    var port: UInt16
    var lastSeen: Date
    var alias: String? = nil
}
