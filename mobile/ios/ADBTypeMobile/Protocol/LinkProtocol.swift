import Foundation

/// 局域网协议常量，与 docs/LAN-transfer-spec.md / 电脑端保持一致。
enum LinkProtocol {
    /// 广播报文里的应用标识，用于过滤其它程序的 UDP 报文。
    static let appTag = "ADBTypeLink"
    /// 协议版本，当前为 1。
    static let version = 1
    /// 设备发现固定 UDP 端口。
    static let discoveryPort: UInt16 = 52730
    /// 单帧 JSON 上限 16 MiB。
    static let maxFrameBytes = 16 * 1024 * 1024
    /// 文件传输分块 256 KiB。
    static let fileChunkBytes = 256 * 1024
    /// TCP 连接超时（规格 §7）。
    static let connectTimeout: TimeInterval = 6
    /// 已建立连接上的读写超时（规格 §7）。
    static let ioTimeout: TimeInterval = 30
    /// 广播间隔 2 秒（规格 §2.1）。
    static let announceInterval: TimeInterval = 2
    /// 超过 8 秒没收到广播视为离线（规格 §2.2）。
    static let offlineThreshold: TimeInterval = 8
    /// 离线设备保留时长，避免列表里突然消失（好友本身永久保留）。
    static let offlineRetention: TimeInterval = 120
    /// 在线状态清理间隔。
    static let pruneInterval: TimeInterval = 3
}
