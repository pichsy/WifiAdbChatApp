import SwiftUI
import AppKit

enum StatusKind {
    case idle
    case success
    case failure
}

@main
struct RenderChatUI {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let model = LANModel()
        model.deviceName = "pichs 的 MacBook Pro"
        model.pairingCode = "428193"
        model.pairedCount = 1
        model.peers = [
            LANPeer(id: "peer-a", name: "pichs 的 Windows 笔记本", host: "192.168.1.32", port: 52311, lastSeen: Date()),
            LANPeer(id: "peer-b", name: "Mac mini", host: "192.168.1.7", port: 62200, lastSeen: Date())
        ]
        model.selectedPeerID = "peer-a"

        let now = Date()
        model.messages = [
            LANMessage(direction: .incoming, peerName: "pichs 的 Windows 笔记本",
                       date: now.addingTimeInterval(-360), text: "在吗？把那个安装包发我一下"),
            LANMessage(direction: .outgoing, peerName: "pichs 的 Windows 笔记本",
                       date: now.addingTimeInterval(-340), text: "好，马上发，稍等"),
            LANMessage(direction: .incoming, peerName: "pichs 的 Windows 笔记本",
                       date: now.addingTimeInterval(-320), text: "另外这条是中文和 emoji 测试：😀 收到请回复～"),
            LANMessage(direction: .outgoing, peerName: "pichs 的 Windows 笔记本",
                       date: now.addingTimeInterval(-200),
                       fileURL: URL(fileURLWithPath: "/Users/pichs/Downloads/ADBType-1.2-macOS.zip"),
                       fileSize: 12_884_901),
            LANMessage(direction: .incoming, peerName: "pichs 的 Windows 笔记本",
                       date: now.addingTimeInterval(-120),
                       fileURL: URL(fileURLWithPath: "/Users/pichs/Downloads/ADBType 接收/Windows 端需求.xlsx"),
                       fileSize: 842_112),
            LANMessage(direction: .outgoing, peerName: "pichs 的 Windows 笔记本",
                       date: now.addingTimeInterval(-30), text: "Windows 端代码先按这个规格写，配对码我用 428193")
        ]
        model.statusKind = .idle
        model.statusText = "已收到「Windows 端需求.xlsx」，存在 ~/Downloads/ADBType 接收"

        let args = CommandLine.arguments
        let width = CGFloat(Double(args.count > 1 ? args[1] : "1180") ?? 1180)
        let height = CGFloat(Double(args.count > 2 ? args[2] : "760") ?? 760)
        let outputPath = args.count > 3 ? args[3] : "/tmp/chat-ui.png"
        if args.count > 4, args[4] == "light" {
            app.appearance = NSAppearance(named: .aqua)
        }
        let hosting = NSHostingView(rootView: LANTransferView().environmentObject(model))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "ADBType 传输"
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        // 给 SwiftUI 一点时间完成布局与首次绘制
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                print("RENDER FAILED: no bitmap")
                exit(1)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                print("RENDER FAILED: no png")
                exit(1)
            }
            try? png.write(to: URL(fileURLWithPath: outputPath))
            print("RENDER OK", png.count)
            exit(0)
        }
        app.run()
    }
}
