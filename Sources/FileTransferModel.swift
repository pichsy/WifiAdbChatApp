import Foundation
import AppKit

struct TransferItem: Identifiable {
    enum Status {
        case pending
        case sending
        case done
        case failed
    }

    let id = UUID()
    let url: URL
    let size: Int64
    var status: Status = .pending
    var progress: Double = 0
    var message: String? = nil

    var name: String { url.lastPathComponent }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

final class FileTransferModel: ObservableObject {
    @Published var items: [TransferItem] = []
    @Published var targetDir: String {
        didSet { defaults.set(targetDir, forKey: Self.targetDirKey) }
    }
    @Published var busy = false
    @Published var overallProgress: Double = 0
    @Published var statusText = "把文件拖进来，或选择文件 / 从剪贴板粘贴"
    @Published var statusKind: StatusKind = .idle

    static let targetDirKey = "fileTargetDir"
    static let defaultDir = "/sdcard/Download"

    private let defaults = UserDefaults.standard

    init() {
        targetDir = defaults.string(forKey: Self.targetDirKey) ?? Self.defaultDir
    }

    var pendingCount: Int {
        items.filter { $0.status != .done }.count
    }

    var totalBytes: Int64 {
        items.reduce(0) { $0 + max(0, $1.size) }
    }

    // MARK: - 添加文件

    func add(_ urls: [URL]) {
        let fm = FileManager.default
        var added = 0
        var problem: String?

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                problem = "「\(url.lastPathComponent)」不存在或已被移动"
                continue
            }
            if isDirectory.boolValue {
                problem = "暂不支持整个文件夹，请选择具体文件"
                continue
            }
            if items.contains(where: { $0.url.path == url.path }) { continue }

            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            items.append(TransferItem(url: url, size: size))
            added += 1
        }

        if added > 0 {
            statusKind = .idle
            statusText = "已添加 \(added) 个文件" + (problem.map { "（\($0)）" } ?? "")
        } else if let problem {
            statusKind = .failure
            statusText = problem
        }
    }

    func remove(_ item: TransferItem) {
        guard !busy else { return }
        items.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        guard !busy else { return }
        items.removeAll { $0.status == .done }
    }

    func clearAll() {
        guard !busy else { return }
        items = []
        overallProgress = 0
        statusKind = .idle
        statusText = "把文件拖进来，或选择文件 / 从剪贴板粘贴"
    }

    func resetTargetDir() {
        targetDir = Self.defaultDir
    }

    // MARK: - 剪贴板

    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(urls)
            return
        }

        let stamp = Self.stampFormatter.string(from: Date())
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            saveClipboardFile(data: png, name: "剪贴板图片-\(stamp).png")
            return
        }

        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saveClipboardFile(data: Data(text.utf8), name: "剪贴板文本-\(stamp).txt")
            return
        }

        statusKind = .failure
        statusText = "剪贴板里没有文件、图片或文字"
    }

    private func saveClipboardFile(data: Data, name: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTypePaste", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            add([url])
        } catch {
            statusKind = .failure
            statusText = "保存剪贴板内容失败：\(error.localizedDescription)"
        }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: - 传输

    func start(adb: String, serial: String) {
        guard !busy else { return }
        guard !items.isEmpty else {
            fail("先添加要传的文件")
            return
        }
        guard !serial.isEmpty else {
            fail("未连接手机，请先选择设备")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: adb) else {
            fail("adb 不可用，请在右下角设置里重新选择")
            return
        }

        var dir = targetDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if dir.isEmpty { dir = Self.defaultDir }
        if !dir.hasPrefix("/") { dir = "/" + dir }
        while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
        targetDir = dir

        let pending = items.filter { $0.status != .done }
        guard !pending.isEmpty else {
            fail("列表里的文件都已传完，可以清空后再加新文件")
            return
        }

        let total = pending.reduce(Int64(0)) { $0 + max(0, $1.size) }
        let snapshot = pending.map { ($0.id, $0.url, $0.size) }

        busy = true
        overallProgress = 0
        statusKind = .idle
        statusText = "准备传输 \(pending.count) 个文件…"

        for item in pending {
            update(item.id) { entry in
                entry.status = .pending
                entry.progress = 0
                entry.message = nil
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let mkdir = ADB.mkdir(adb: adb, serial: serial, dir: dir)
            guard mkdir.ok else {
                DispatchQueue.main.async {
                    self.busy = false
                    self.fail(ADB.friendly(mkdir.text, fallback: "创建手机目录失败"))
                }
                return
            }

            var completedBytes: Int64 = 0
            var succeeded = 0
            var failed = 0
            var lastError: String?

            for (id, url, size) in snapshot {
                self.update(id) { entry in
                    entry.status = .sending
                    entry.progress = 0
                }

                let remote = dir + "/" + url.lastPathComponent
                let timeout = max(120, Double(size) / 200_000 + 60)
                let result = ADB.push(adb: adb, serial: serial,
                                      localPath: url.path, remotePath: remote,
                                      timeout: timeout) { percent in
                    let fraction = Double(percent) / 100
                    let overall = total > 0
                        ? (Double(completedBytes) + Double(max(0, size)) * fraction) / Double(total)
                        : 0
                    DispatchQueue.main.async {
                        self.overallProgress = min(1, max(0, overall))
                    }
                    self.update(id) { entry in
                        entry.progress = fraction
                    }
                }

                if result.ok {
                    completedBytes += max(0, size)
                    succeeded += 1
                    self.update(id) { entry in
                        entry.status = .done
                        entry.progress = 1
                    }
                    DispatchQueue.main.async {
                        self.overallProgress = total > 0 ? Double(completedBytes) / Double(total) : 1
                    }
                } else {
                    failed += 1
                    let message = ADB.friendly(result.text, fallback: "传输失败")
                    lastError = message
                    self.update(id) { entry in
                        entry.status = .failed
                        entry.message = message
                    }
                }
            }

            DispatchQueue.main.async {
                self.busy = false
                if failed == 0 {
                    self.statusKind = .success
                    self.statusText = "已传输 \(succeeded) 个文件到 \(dir)"
                    self.overallProgress = 1
                } else {
                    self.statusKind = .failure
                    self.statusText = succeeded > 0
                        ? "\(succeeded) 个成功，\(failed) 个失败：\(lastError ?? "未知错误")"
                        : "传输失败：\(lastError ?? "未知错误")"
                }
            }
        }
    }

    // MARK: - 私有

    private func update(_ id: UUID, _ change: @escaping (inout TransferItem) -> Void) {
        DispatchQueue.main.async {
            guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            change(&self.items[index])
        }
    }

    private func fail(_ message: String) {
        statusKind = .failure
        statusText = message
    }
}
