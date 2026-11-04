import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        // 窗口显示 / 重新获得焦点时都确保红色关闭按钮被替换成「最小化」。
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            self?.installMinimizeCloseButton(on: window)
        }
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            installMinimizeCloseButton(on: window)
        }
    }

    deinit {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }

    /// 点红色关闭按钮 = 最小化到 Dock，而不是关掉窗口 / 退出进程。
    private func installMinimizeCloseButton(on window: NSWindow) {
        guard window.canBecomeMain,
              let closeButton = window.standardWindowButton(.closeButton) else { return }
        closeButton.target = self
        closeButton.action = #selector(minimizeFromCloseButton(_:))
        closeButton.toolTip = "最小化到 Dock（不退出）"
    }

    @objc private func minimizeFromCloseButton(_ sender: Any?) {
        let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.canBecomeMain })
        window?.performMiniaturize(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点 Dock 图标 / 重新打开 App 时，把最小化的窗口还原出来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        for window in sender.windows where window.canBecomeMain {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}

@main
struct ADBTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var fileModel = FileTransferModel()
    @StateObject private var lanModel = LANModel()

    var body: some Scene {
        Window("文件互传助手", id: "main") {
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
