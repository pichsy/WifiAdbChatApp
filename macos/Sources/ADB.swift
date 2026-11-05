import Foundation

/// 一次 shell/adb 调用的结果
struct ShellResult {
    let status: Int32
    let text: String
    let launched: Bool

    var ok: Bool { launched && status == 0 }
}

struct ADBDevice: Identifiable, Hashable {
    let serial: String
    let model: String
    let state: String

    var id: String { serial }

    var displayName: String {
        model.isEmpty ? serial : "\(model)  ·  \(serial)"
    }
}

enum DefaultsKey {
    static let adbPath = "adbPath"
    static let clearFirst = "clearFirst"
    static let pressEnter = "pressEnter"
    static let selectedSerial = "selectedSerial"
    static let history = "history"
    static let screenshotDir = "screenshotDir"
}

enum ADB {
    // MARK: - 执行进程

    static func runOnce(_ executable: String,
                        _ arguments: [String],
                        timeout: TimeInterval) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return ShellResult(status: -1,
                               text: "无法运行 \(executable)：\(error.localizedDescription)",
                               launched: false)
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ShellResult(status: process.terminationStatus, text: text, launched: true)
    }

    /// adb server 版本冲突（例如 QtScrcpy 自带的 adb 抢占了 5037 端口）时自动重试一次
    static func run(_ executable: String,
                    _ arguments: [String],
                    timeout: TimeInterval = 20) -> ShellResult {
        var result = runOnce(executable, arguments, timeout: timeout)
        if !result.ok, result.text.lowercased().contains("server version") {
            Thread.sleep(forTimeInterval: 0.6)
            result = runOnce(executable, arguments, timeout: timeout)
        }
        return result
    }

    /// 截取手机当前屏幕，返回原始 PNG 数据。
    /// 必须用 `exec-out` 而不是 `shell`，否则 Windows/部分设备会把换行符转成 CRLF 破坏 PNG。
    static func captureScreenshot(adb: String,
                                  serial: String,
                                  timeout: TimeInterval = 30) -> (data: Data?, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["-s", serial, "exec-out", "screencap", "-p"]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return (nil, "无法运行 adb：\(error.localizedDescription)")
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let stderr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !outData.isEmpty else {
            return (nil, stderr.isEmpty ? "截屏失败，请确认手机已解锁、USB 调试已允许" : stderr)
        }
        // PNG 文件头：89 50 4E 47 0D 0A 1A 0A
        let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard outData.count > 8, Array(outData.prefix(8)) == pngHeader else {
            let hint = stderr.isEmpty ? "返回数据不是有效 PNG" : stderr
            return (nil, "截屏失败：\(hint)")
        }
        return (outData, nil)
    }

    // MARK: - 定位 adb

    static func locate() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []

        func add(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            let expanded = (path as NSString).expandingTildeInPath
            if !candidates.contains(expanded) { candidates.append(expanded) }
        }

        add(UserDefaults.standard.string(forKey: DefaultsKey.adbPath))
        add(ProcessInfo.processInfo.environment["ANDROID_HOME"].map { $0 + "/platform-tools/adb" })
        add(ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"].map { $0 + "/platform-tools/adb" })
        add("~/Android/sdk/platform-tools/adb")
        add("~/Library/Android/sdk/platform-tools/adb")
        add("/opt/homebrew/bin/adb")
        add("/usr/local/bin/adb")
        add("/usr/bin/adb")

        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }

        // GUI App 默认拿不到 shell 的 PATH，借登录 shell 再找一次
        for shell in ["/bin/zsh", "/bin/bash"] {
            let result = runOnce(shell, ["-lc", "command -v adb"], timeout: 8)
            let path = result.text
                .split(separator: "\n")
                .last
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if result.ok, !path.isEmpty, fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - 设备列表

    static func listDevices(adb: String) -> (devices: [ADBDevice], error: String?) {
        let result = run(adb, ["devices", "-l"], timeout: 12)
        guard result.ok else {
            return ([], friendly(result.text, fallback: "adb 无法连接"))
        }

        var devices: [ADBDevice] = []
        var issues: [String] = []

        for rawLine in result.text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices") || line.hasPrefix("*") { continue }

            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { continue }

            let serial = fields[0]
            let state = fields[1]
            var model = ""
            for field in fields.dropFirst(2) where field.hasPrefix("model:") {
                let raw = String(field.dropFirst("model:".count))
                model = raw.replacingOccurrences(of: "_", with: " ")
            }

            switch state {
            case "device":
                devices.append(ADBDevice(serial: serial, model: model, state: state))
            case "unauthorized":
                issues.append("\(serial) 未授权：请在手机上点击「允许 USB 调试」")
            case "offline":
                issues.append("\(serial) 离线：请重新插拔数据线")
            default:
                issues.append("\(serial) 状态：\(state)")
            }
        }

        return (devices, issues.isEmpty ? nil : issues.joined(separator: "；"))
    }

    // MARK: - 命令构造

    /// 组装 "input text '...'"，由远端 sh 解析
    static func inputTextCommand(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        // input text 用 %s 表示空格
        value = value.replacingOccurrences(of: " ", with: "%s")
        return "input text " + shellQuote(value)
    }

    /// 单引号包裹，内部单引号转义，避免被远端 shell 解释
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 光标移到末尾后连续删除：一次 adb 调用搞定
    static func clearCommand(deletes: Int = 40) -> String {
        (["input", "keyevent", "123"] + Array(repeating: "67", count: deletes))
            .joined(separator: " ")
    }

    /// 老设备不支持一次多个键码时的兜底
    static func clearCommandSlow(deletes: Int = 40) -> String {
        Array(repeating: "input keyevent 67", count: deletes).joined(separator: "; ")
    }

    static func friendly(_ raw: String, fallback: String = "adb 执行失败") -> String {
        let message = raw.lowercased()
        if message.isEmpty { return fallback }
        if message.contains("no devices") { return "未检测到设备，请连接手机并开启 USB 调试" }
        if message.contains("unauthorized") { return "设备未授权，请在手机上点击「允许 USB 调试」" }
        if message.contains("offline") { return "设备离线，请重新插拔 USB 数据线后重试" }
        if message.contains("closed") { return "连接已断开，请重新连接设备" }
        if message.contains("not found") { return "adb 不可用：\(raw)" }
        if message.contains("exception") || message.contains("java.lang") {
            return "手机端执行 input 出错，请确认屏幕已解锁、输入框可编辑后重试"
        }
        return shorten(raw, lines: 3)
    }

    static func shorten(_ text: String, lines: Int) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard all.count > lines else { return text }
        return all.prefix(lines).joined(separator: "\n") + " …"
    }
}

extension ADB {
    static let clipJarRemotePath = "/data/local/tmp/adbtype-clip.jar"

    /// 把内置的 dex 推到手机
    static func uploadClipJar(adb: String, serial: String, localPath: String) -> ShellResult {
        run(adb, ["-s", serial, "push", localPath, clipJarRemotePath], timeout: 25)
    }

    /// 以 shell 身份运行 dex，把文本写进系统剪贴板
    static func setClipboard(adb: String, serial: String, text: String) -> ShellResult {
        let base64 = Data(text.utf8).base64EncodedString()
        let command = "CLASSPATH=\(clipJarRemotePath) app_process /system/bin Clip \(base64)"
        return run(adb, ["-s", serial, "shell", command], timeout: 25)
    }

    // MARK: - 文件传输

    static func mkdir(adb: String, serial: String, dir: String) -> ShellResult {
        run(adb, ["-s", serial, "shell", "mkdir -p " + shellQuote(dir)], timeout: 20)
    }

    /// push 并解析 adb 输出的百分比，onProgress 回调在后台线程
    static func push(adb: String,
                     serial: String,
                     localPath: String,
                     remotePath: String,
                     timeout: TimeInterval,
                     onProgress: ((Int) -> Void)? = nil) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["-s", serial, "push", "-p", localPath, remotePath]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return ShellResult(status: -1,
                               text: "无法运行 \(adb)：\(error.localizedDescription)",
                               launched: false)
        }

        let handle = pipe.fileHandleForReading
        let buffer = NSMutableData()
        let lock = NSLock()
        let regex = try? NSRegularExpression(pattern: "(\\d{1,3})%")

        func scan(_ chunk: Data) {
            guard let onProgress, !chunk.isEmpty,
                  let text = String(data: chunk, encoding: .utf8) else { return }
            let source = text as NSString
            guard let matches = regex?.matches(in: text, options: [],
                                               range: NSRange(location: 0, length: source.length)),
                  let last = matches.last else { return }
            if let value = Int(source.substring(with: last.range(at: 1))) {
                onProgress(max(0, min(100, value)))
            }
        }

        handle.readabilityHandler = { fileHandle in
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                fileHandle.readabilityHandler = nil
                return
            }
            lock.lock()
            buffer.append(chunk)
            lock.unlock()
            scan(chunk)
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        handle.readabilityHandler = nil

        if let rest = try? handle.readToEnd(), !rest.isEmpty {
            lock.lock()
            buffer.append(rest)
            lock.unlock()
            scan(rest)
        }

        let text = String(data: buffer as Data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ShellResult(status: process.terminationStatus, text: text, launched: true)
    }
}
