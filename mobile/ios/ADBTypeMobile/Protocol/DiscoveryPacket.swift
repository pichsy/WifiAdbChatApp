import Foundation

/// 解析 UDP 52730 收到的发现报文（规格 §2.2）。
/// 只校验报文本身；来源 IP 由调用方从 recvfrom 取得，不使用 payload 里的字段。
struct DiscoveryPacket: Equatable {
    let peerID: String
    let name: String
    let port: UInt16

    static func parse(_ data: Data, localDeviceID: String) -> DiscoveryPacket? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["app"] as? String == LinkProtocol.appTag,
              let peerID = object["id"] as? String,
              !peerID.isEmpty,
              peerID != localDeviceID,
              let name = object["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let portValue = portNumber(object["port"]),
              portValue >= 1, portValue <= 65_535 else {
            return nil
        }
        // v 不等于 1 也接受（向前兼容），仅忽略。
        return DiscoveryPacket(peerID: peerID, name: name, port: UInt16(portValue))
    }

    private static func portNumber(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
