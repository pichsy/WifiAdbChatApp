import Foundation

/// 设备身份与本机配对码。
enum DeviceIdentity {
    static let deviceIDKey = "lanDeviceID"

    /// 首次启动生成 UUID 并持久化，之后不变（UserDefaults key 与电脑端一致：lanDeviceID）。
    static func loadOrCreateDeviceID(defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: deviceIDKey), !saved.isEmpty {
            return saved
        }
        let value = UUID().uuidString
        defaults.set(value, forKey: deviceIDKey)
        return value
    }

    /// 6 位数字配对码，每次启动 / 手动「换一个」时生成。
    static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}
