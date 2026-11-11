import SwiftUI
import AppKit

/// 独立的手机文件浏览窗口，和截屏窗口一样可自由缩放。
final class DeviceFileBrowserWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [String: DeviceFileBrowserWindowController] = [:]
    private let serial: String

    static func present(adbPath: String, device: ADBDevice) {
        if let existing = controllers[device.serial], let window = existing.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = DeviceFileBrowserView(adbPath: adbPath, device: device)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)

        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "设备文件 · \(device.model.isEmpty ? device.serial : device.model)"
        window.contentMinSize = NSSize(width: 780, height: 520)
        window.setContentSize(NSSize(width: 1020, height: 680))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DeviceFileBrowserWindowFrame")
        window.center()

        let controller = DeviceFileBrowserWindowController(window: window, serial: device.serial)
        controllers[device.serial] = controller
        window.delegate = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private init(window: NSWindow, serial: String) {
        self.serial = serial
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        Self.controllers.removeValue(forKey: serial)
    }
}
