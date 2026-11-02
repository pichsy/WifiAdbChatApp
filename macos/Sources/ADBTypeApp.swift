import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ADBTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var fileModel = FileTransferModel()
    @StateObject private var lanModel = LANModel()

    var body: some Scene {
        Window("ADBType 传输", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(fileModel)
                .environmentObject(lanModel)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("操作") {
                Button("发送到手机") { model.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("清空输入框") { model.input = "" }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("刷新设备列表") { model.refreshDevices(silent: false) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("选择 adb 路径…") { model.chooseADB() }
                Divider()
                Button("清除历史记录") { model.clearHistory() }
            }
        }
    }
}
