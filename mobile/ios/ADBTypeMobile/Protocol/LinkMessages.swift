import Foundation

/// 协议消息构造器，字段与规格 §2 / §5 完全一致。
enum LinkMessages {
    static func announce(id: String, name: String, port: UInt16) -> [String: Any] {
        [
            "app": LinkProtocol.appTag,
            "v": LinkProtocol.version,
            "id": id,
            "name": name,
            "port": Int(port)
        ]
    }

    static func hello(id: String, name: String, code: String?) -> [String: Any] {
        var hello: [String: Any] = [
            "app": LinkProtocol.appTag,
            "v": LinkProtocol.version,
            "id": id,
            "name": name
        ]
        if let code {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { hello["code"] = trimmed }
        }
        return hello
    }

    static func helloOk(name: String, id: String) -> [String: Any] {
        ["type": "hello_ok", "name": name, "id": id]
    }

    static func pairRequired(name: String) -> [String: Any] {
        ["type": "pair_required", "name": name]
    }

    static func error(_ message: String) -> [String: Any] {
        ["type": "error", "message": message]
    }

    static func text(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    static func file(name: String, size: Int) -> [String: Any] {
        ["type": "file", "name": name, "size": size]
    }

    static func ok() -> [String: Any] {
        ["type": "ok"]
    }

    static func bye() -> [String: Any] {
        ["type": "bye"]
    }
}
