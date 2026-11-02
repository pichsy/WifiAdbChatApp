import Foundation
import AppKit
import Combine

enum StatusKind {
    case idle
    case success
    case failure
}

final class AppModel: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var adbPath: String = ""
    @Published var devices: [ADBDevice] = []
    @Published var selectedSerial: String = "" { didSet { defaults.set(selectedSerial, forKey: DefaultsKey.selectedSerial) } }
    @Published var input: String = ""
    @Published var clearFirst: Bool = true { didSet { defaults.set(clearFirst, forKey: DefaultsKey.clearFirst) } }
    @Published var pressEnter: Bool = false { didSet { defaults.set(pressEnter, forKey: DefaultsKey.pressEnter) } }
    @Published var busy: Bool = false
    @Published var scanning: Bool = false
    @Published var statusText: String = "输入内容后按 Enter，发送到手机当前光标所在位置"
    @Published var statusKind: StatusKind = .idle
    @Published var deviceError: String? = nil
    @Published var history: [String] = []

    private var scanningInFlight = false
    /// 已经推送过剪贴板 dex 的设备，避免每次发送都推一遍
    private var clipPushedSerials = Set<String>()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init() {
        let savedClear = defaults.object(forKey: DefaultsKey.clearFirst) as? Bool ?? true
        clearFirst = savedClear
        pressEnter = defaults.bool(forKey: DefaultsKey.pressEnter)
        selectedSerial = defaults.string(forKey: DefaultsKey.selectedSerial) ?? ""
        history = defaults.stringArray(forKey: DefaultsKey.history) ?? []

        if let savedPath = defaults.string(forKey: DefaultsKey.adbPath),
           FileManager.default.isExecutableFile(atPath: savedPath) {
            adbPath = savedPath
        } else if let found = ADB.locate() {
            adbPath = found
            defaults.set(found, forKey: DefaultsKey.adbPath)
        } else {
            adbPath = ""
            statusKind = .failure
            statusText = "未找到 adb，请点右下角设置按钮，选择 Android SDK 里的 platform-tools/adb"
        }

        refreshDevices(silent: true)
    }

    // MARK: - 状态

    var adbAvailable: Bool {
        !adbPath.isEmpty && FileManager.default.isExecutableFile(atPath: adbPath)
    }

    var selectedDevice: ADBDevice? {
        devices.first { $0.serial == selectedSerial }
    }

    /// 含中文 / emoji 时走剪贴板粘贴，纯 ASCII 直接 input text
    var needsClipboard: Bool {
        !nonASCII(in: input).isEmpty
    }

    private func nonASCII(in text: String) -> String {
        var seen = Set<Character>()
        var found: [Character] = []
        for character in text {
            if character.unicodeScalars.allSatisfy({ $0.isASCII }) { continue }
            if !seen.contains(character) {
                seen.insert(character)
                found.append(character)
            }
        }
        return String(found)
    }

    /// 窗口处于前台时每 4 秒静默刷新设备，插拔手机即时生效
    func autoTick() {
        guard NSApp.isActive, !busy else { return }
        refreshDevices(silent: true)
    }

    // MARK: - 设备

    func refreshDevices(silent: Bool) {
        guard !scanningInFlight else { return }
        guard adbAvailable else { return }
        scanningInFlight = true
        if !silent { scanning = true }

        let adb = adbPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ADB.listDevices(adb: adb)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanningInFlight = false
                self.scanning = false
                self.devices = result.devices
                self.deviceError = result.error

                if !result.devices.contains(where: { $0.serial == self.selectedSerial }) {
                    self.selectedSerial = result.devices.first?.serial ?? ""
                }

                if !silent {
                    if let error = result.error, result.devices.isEmpty {
                        self.statusKind = .failure
                        self.statusText = error
                    } else if let device = self.selectedDevice {
                        self.statusKind = .idle
                        self.statusText = "已连接 \(device.displayName)"
                    }
                }
            }
        }
    }

    // MARK: - 发送

    func send() {
        guard !busy else { return }

        guard adbAvailable else {
            statusKind = .failure
            statusText = "adb 不可用，请在右下角设置中重新选择 adb 路径"
            return
        }
        guard let device = selectedDevice else {
            statusKind = .failure
            statusText = deviceError ?? "未检测到设备，请连接手机并开启 USB 调试"
            return
        }

        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesClipboard = !nonASCII(in: text).isEmpty
        // 剪贴板模式只写剪贴板，不动手机界面：清空/回车都交给用户手动完成
        let shouldClear = clearFirst && !usesClipboard
        let shouldEnter = pressEnter && !usesClipboard

        guard !text.isEmpty || shouldClear || shouldEnter else {
            statusKind = .failure
            statusText = "请输入要发送的内容"
            return
        }

        busy = true
        statusKind = .idle
        statusText = usesClipboard ? "正在复制到手机剪贴板…" : "发送中…"

        let adb = adbPath
        let serial = device.serial
        let clipJar = Bundle.main.path(forResource: "adbtype-clip", ofType: "jar")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var failure: String?
            var didClear = false
            var didType = false
            var didCopy = false

            if shouldClear {
                var result = ADB.run(adb, ["-s", serial, "shell", ADB.clearCommand()], timeout: 20)
                if !result.ok {
                    result = ADB.run(adb, ["-s", serial, "shell", ADB.clearCommandSlow()], timeout: 30)
                }
                if result.ok {
                    didClear = true
                } else {
                    failure = ADB.friendly(result.text, fallback: "清空设备输入框失败")
                }
            }

            if failure == nil, usesClipboard {
                if let error = self.writePhoneClipboard(adb: adb, serial: serial, text: text, jarPath: clipJar) {
                    failure = error
                } else {
                    didCopy = true
                }
            } else if failure == nil, !text.isEmpty {
                let result = ADB.run(adb, ["-s", serial, "shell", ADB.inputTextCommand(text)], timeout: 20)
                if result.ok {
                    didType = true
                } else {
                    failure = ADB.friendly(result.text, fallback: "发送文本失败")
                }
            }

            if failure == nil, shouldEnter {
                let result = ADB.run(adb, ["-s", serial, "shell", "input keyevent 66"], timeout: 12)
                if !result.ok {
                    failure = ADB.friendly(result.text, fallback: "发送回车键失败")
                }
            }

            DispatchQueue.main.async {
                self.busy = false

                if let failure {
                    self.statusKind = .failure
                    self.statusText = failure
                    return
                }

                var summary: String
                if didCopy {
                    let preview = text.count > 18 ? String(text.prefix(18)) + "…" : text
                    summary = "已复制「\(preview)」到手机剪贴板 · 请在手机上长按输入框，点「粘贴」"
                } else if didType {
                    summary = "已发送「\(text)」"
                } else if didClear {
                    summary = "已清空设备输入框"
                } else {
                    summary = "已发送回车键"
                }
                if shouldEnter, didType { summary += "，并按下回车" }

                self.statusKind = .success
                self.statusText = summary + "  ·  " + Self.timeFormatter.string(from: Date())
                if didType || didCopy { self.pushHistory(text) }
                self.selectAllInput()
                self.refreshDevices(silent: true)
            }
        }
    }

    /// 含中文 / emoji：只把文字写进手机剪贴板，然后提示用户自己长按粘贴。返回 nil 表示成功
    private func writePhoneClipboard(adb: String, serial: String, text: String, jarPath: String?) -> String? {
        guard let jarPath else {
            return "安装包缺少内置组件 adbtype-clip.jar，请重新构建应用"
        }

        if !clipPushedSerials.contains(serial) {
            let push = ADB.uploadClipJar(adb: adb, serial: serial, localPath: jarPath)
            guard push.ok else {
                return ADB.friendly(push.text, fallback: "推送手机端剪贴板组件失败")
            }
            clipPushedSerials.insert(serial)
        }

        let setResult = ADB.setClipboard(adb: adb, serial: serial, text: text)
        guard setResult.ok, setResult.text.contains("OK setPrimaryClip") else {
            if setResult.text.contains("Exception") || setResult.text.contains("denied") {
                clipPushedSerials.remove(serial)
            }
            return ADB.friendly(setResult.text, fallback: "写入手机剪贴板失败")
        }
        return nil
    }

    /// 发送后全选输入框内容，下一次输入直接覆盖
    private func selectAllInput() {
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    // MARK: - 历史

    private func pushHistory(_ item: String) {
        var items = history.filter { $0 != item }
        items.insert(item, at: 0)
        history = Array(items.prefix(12))
        defaults.set(history, forKey: DefaultsKey.history)
    }

    func clearHistory() {
        history = []
        defaults.set([String](), forKey: DefaultsKey.history)
    }

    // MARK: - adb 路径

    func chooseADB() {
        let panel = NSOpenPanel()
        panel.title = "选择 adb"
        panel.message = "请选择 Android SDK 中 platform-tools 目录下的 adb 文件"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: (adbPath as NSString?)?.deletingLastPathComponent ?? "/usr/local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            setADBPath(url.path)
        }
    }

    func setADBPath(_ path: String) {
        let check = ADB.runOnce(path, ["version"], timeout: 10)
        guard check.ok else {
            statusKind = .failure
            statusText = "该文件不是可用的 adb：\(check.text)"
            return
        }
        adbPath = path
        defaults.set(path, forKey: DefaultsKey.adbPath)
        statusKind = .idle
        statusText = "已切换 adb：\(path)"
        refreshDevices(silent: false)
    }

    func redetectADB() {
        guard let found = ADB.locate() else {
            statusKind = .failure
            statusText = "自动检测失败，请手动选择 adb 路径"
            return
        }
        adbPath = found
        defaults.set(found, forKey: DefaultsKey.adbPath)
        statusKind = .idle
        statusText = "adb：\(found)"
        refreshDevices(silent: false)
    }

    func revealADB() {
        guard !adbPath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: adbPath)])
    }
}
