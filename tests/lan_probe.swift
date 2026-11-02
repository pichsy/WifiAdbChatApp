import Foundation
import AppKit

enum StatusKind {
    case idle
    case success
    case failure
}

/// 命令行协议探针：复用 macOS 端真正的 LANModel，用来和另一端的实现（Avalonia 版 / Python 模拟端）
/// 做无界面的收发联调。
///
/// 用法：
///   lan_probe serve --seconds 60 [--name MacProbe] [--receive-dir /tmp/...]
///   lan_probe send  --peer-name WinProbe [--text 你好] [--file /tmp/a.bin] [--code 123456] [--seconds 40]
///   lan_probe pair  --peer-name WinProbe --code 123456 [--seconds 20]
@main
struct LanProbe {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first else {
            print("usage: lan_probe serve|send|pair [--options]")
            exit(2)
        }
        args.removeFirst()

        var opts: [String: String] = [:]
        var index = 0
        while index < args.count {
            let key = args[index]
            if key.hasPrefix("--"), index + 1 < args.count {
                opts[String(key.dropFirst(2))] = args[index + 1]
                index += 2
            } else {
                index += 1
            }
        }

        let seconds = Double(opts["seconds"] ?? "40") ?? 40
        let deadline = Date().addingTimeInterval(seconds)

        let model = LANModel()
        if let name = opts["name"] { model.deviceName = name }
        if let dir = opts["receive-dir"] { model.receiveDir = dir }

        switch mode {
        case "serve":
            serve(model, deadline: deadline)
        case "send":
            send(model, opts: opts, deadline: deadline)
        case "pair":
            pair(model, opts: opts, deadline: deadline)
        default:
            print("unknown mode \(mode)")
            exit(2)
        }
    }

    // MARK: - 模式

    private static func serve(_ model: LANModel, deadline: Date) {
        var seen = model.messages.count
        var lastStatus = ""
        print("READY name=\(model.deviceName) code=\(model.pairingCode) recv=\(model.receiveDir)")
        fflush(stdout)

        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))

            if model.statusText != lastStatus {
                lastStatus = model.statusText
                print("STATUS \(model.statusText)")
                fflush(stdout)
            }

            while seen < model.messages.count {
                let message = model.messages[seen]
                seen += 1
                if message.kind == .text {
                    print("MSG \(message.direction.rawValue) TEXT \(message.text ?? "") peer=\(message.peerName)")
                } else {
                    print("MSG \(message.direction.rawValue) FILE \(message.fileName ?? "?") size=\(message.fileSize ?? 0) path=\(message.filePath ?? "?") peer=\(message.peerName)")
                }
                fflush(stdout)
            }
        }
        print("DONE messages=\(model.messages.count)")
        exit(0)
    }

    private static func send(_ model: LANModel, opts: [String: String], deadline: Date) {
        let target = opts["peer-name"] ?? ""
        let code = opts["code"]
        var peer: LANPeer?
        var textOutcome: LANOutcome?
        var fileOutcome: LANOutcome?
        var fileStarted = false

        // 可选：跳过发现，直连指定地址（联调时用）。
        var fixedPeer: LANPeer?
        if let host = opts["host"], let portText = opts["port"], let port = UInt16(portText) {
            fixedPeer = LANPeer(id: opts["peer-id"] ?? "manual-peer",
                                name: target.isEmpty ? host : target,
                                host: host, port: port, lastSeen: Date())
        }

        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))

            if peer == nil,
               let found = fixedPeer ?? model.peers.first(where: { $0.name.contains(target) || target.isEmpty }) {
                peer = found
                print("PEER \(found.name) \(found.host):\(found.port)")
                fflush(stdout)
                if let text = opts["text"] {
                    model.sendText(text, to: found, code: code) { outcome in
                        textOutcome = outcome
                        print("TEXT RESULT \(describe(outcome))")
                        fflush(stdout)
                    }
                } else {
                    textOutcome = .ok
                }
            }

            if let found = peer, textOutcome != nil, !fileStarted, let file = opts["file"] {
                fileStarted = true
                model.sendFiles([URL(fileURLWithPath: file)], to: found, code: code) { outcome in
                    fileOutcome = outcome
                    print("FILE RESULT \(describe(outcome))")
                    fflush(stdout)
                }
            }

            let fileDone = opts["file"] == nil || fileOutcome != nil
            if textOutcome != nil, fileDone {
                print("DONE")
                exit(0)
            }
        }

        print("TIMEOUT peer=\(peer?.name ?? "none") text=\(textOutcome.map(describe) ?? "none") file=\(fileOutcome.map(describe) ?? "none")")
        exit(1)
    }

    private static func pair(_ model: LANModel, opts: [String: String], deadline: Date) {
        let target = opts["peer-name"] ?? ""
        guard let code = opts["code"] else {
            print("missing --code")
            exit(2)
        }
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
            if let found = model.peers.first(where: { $0.name.contains(target) || target.isEmpty }) {
                print("PEER \(found.name) \(found.host):\(found.port)")
                var finished = false
                model.pair(with: found, code: code) { outcome in
                    print("PAIR RESULT \(describe(outcome))")
                    finished = true
                }
                while !finished, Date() < deadline {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
                }
                print(finished ? "DONE" : "TIMEOUT")
                exit(finished ? 0 : 1)
            }
        }
        print("NO PEER")
        exit(1)
    }

    // MARK: - 工具

    private static func describe(_ outcome: LANOutcome) -> String {
        switch outcome {
        case .ok:
            return "ok"
        case .needsPairing(let name):
            return "needs-pairing(\(name))"
        case .failure(let message):
            return "failure(\(message))"
        }
    }
}
