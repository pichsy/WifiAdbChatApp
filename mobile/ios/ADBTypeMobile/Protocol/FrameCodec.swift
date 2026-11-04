import Foundation

/// TCP 帧格式：4 字节大端长度 + UTF-8 JSON 正文（规格 §3）。
/// 文件内容是裸字节，不套 JSON 帧。
enum FrameCodec {
    /// 把一条 JSON 消息编码成带 4 字节大端长度头的帧。
    static func encode(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              let body = try? JSONSerialization.data(withJSONObject: object),
              !body.isEmpty,
              body.count <= LinkProtocol.maxFrameBytes else {
            return nil
        }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    /// 从 4 字节长度头解析正文长度；0 / 超过 16 MiB / 长度不足都视为协议错误。
    static func frameLength(fromHeader header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let bytes = [UInt8](header)
        let length = (Int(bytes[0]) << 24)
            | (Int(bytes[1]) << 16)
            | (Int(bytes[2]) << 8)
            | Int(bytes[3])
        guard length > 0, length <= LinkProtocol.maxFrameBytes else { return nil }
        return length
    }

    /// 解析帧正文；必须是 JSON 对象，否则返回 nil。
    static func decode(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}
