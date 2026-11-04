import Foundation

/// 一次发送动作的结果。
enum LANOutcome {
    case ok
    /// 对方要求先配对（首次连接且配对码不正确 / 未携带）。
    case needsPairing(peerName: String)
    case failure(String)
}
