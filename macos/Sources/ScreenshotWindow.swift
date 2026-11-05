import SwiftUI
import AppKit

private final class ScreenshotWindowBox {
    weak var window: NSWindow?
}

/// 独立的可缩放截屏窗口。SwiftUI 的 .sheet 在 macOS 上尺寸固定，
/// 这里用带 .resizable 的 NSWindow，用户可以直接拖四角/四边改变大小。
final class ScreenshotWindowController: NSWindowController, NSWindowDelegate {
    private static var current: ScreenshotWindowController?

    static func present(model: AppModel) {
        if let existing = current, let window = existing.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let box = ScreenshotWindowBox()
        let root = ScreenshotSheet(model: model, onClose: { box.window?.close() })
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        box.window = window

        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "手机截屏"
        window.contentMinSize = NSSize(width: 780, height: 500)
        window.setContentSize(NSSize(width: 900, height: 720))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ScreenshotWindowFrame")
        window.center()

        let controller = ScreenshotWindowController(window: window)
        current = controller
        window.delegate = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}
