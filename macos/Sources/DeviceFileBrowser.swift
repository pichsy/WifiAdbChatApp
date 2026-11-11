import Foundation
import AppKit
import Combine

/// 手机文件系统里的一个条目。
struct DeviceFileEntry: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let modified: String
    let permissions: String
    let linkTarget: String?

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }

    var iconName: String {
        if isDirectory { return "folder.fill" }
        if isSymlink { return "link" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp":
            return "photo"
        case "mp4", "mov", "mkv", "webm", "avi":
            return "film"
        case "mp3", "wav", "m4a", "flac", "aac":
            return "music.note"
        case "apk", "zip", "rar", "7z", "gz", "tar":
            return "shippingbox"
        case "txt", "log", "json", "xml", "md", "conf", "ini", "yml", "yaml":
            return "doc.text"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }
}

/// 统一处理手机路径，防止用户输入 ../ 后跑出预期目录。
enum DevicePath {
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "/" }
        if !value.hasPrefix("/") { value = "/" + value }
        var parts: [String] = []
        for component in value.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if !parts.isEmpty { parts.removeLast() }
            default:
                parts.append(String(component))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func join(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/" + name }
        return directory + "/" + name
    }

    static func parent(of path: String) -> String {
        let normalized = normalize(path)
        if normalized == "/" { return "/" }
        let ns = normalized as NSString
        let parent = ns.deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    /// 应用数据目录只允许浏览；删除、新建、上传都不应落到 /data 下。
    static func isAppDataPath(_ path: String) -> Bool {
        let normalized = normalize(path)
        return normalized == "/data" || normalized == "/data/data" || normalized.hasPrefix("/data/data/")
    }

    /// 只允许手机路径；防止把 Mac 的 /Users、/Volumes 等宿主路径当成设备目录。
    static func isHostOnlyPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasPrefix("file://") { return true }
        let hostPrefixes = ["/users/", "/volumes/", "/applications/", "/library/", "/private/"]
        return hostPrefixes.contains { lower.hasPrefix($0) }
    }
}

/// ls -la 的解析器，单独拆出来方便测试。
enum DeviceFileParser {
    static func parse(_ output: String, directory: String) -> [DeviceFileEntry] {
        var entries: [DeviceFileEntry] = []
        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .newlines)
            if line.isEmpty || line.hasPrefix("total ") { continue }
            let parts = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard parts.count >= 8 else { continue }
            let permissions = String(parts[0])
            guard permissions.count >= 10 else { continue }
            let type = permissions.first!
            guard "dl-bcps".contains(type) else { continue }

            let size = Int64(parts[4]) ?? 0
            let modified = String(parts[5]) + " " + String(parts[6])
            var name = String(parts[7])
            var linkTarget: String?
            if let range = name.range(of: " -> ") {
                linkTarget = String(name[range.upperBound...])
                name = String(name[..<range.lowerBound])
            }
            if name.isEmpty || name == "." || name == ".." { continue }
            let path = DevicePath.join(directory, name)
            entries.append(DeviceFileEntry(name: name,
                                           path: path,
                                           isDirectory: type == "d",
                                           isSymlink: type == "l",
                                           size: size,
                                           modified: modified,
                                           permissions: permissions,
                                           linkTarget: linkTarget))
        }
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return entries
    }

    /// /data/data 普通 shell 不可读时，用 pm list packages 合成包名目录；
    /// 只有 debuggable 应用进入后才会再尝试 run-as。
    static func parsePackages(_ output: String, directory: String) -> [DeviceFileEntry] {
        var names = Set<String>()
        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("package:") else { continue }
            let name = String(line.dropFirst("package:".count))
            guard !name.isEmpty, !name.contains("/") else { continue }
            names.insert(name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            DeviceFileEntry(name: name,
                            path: DevicePath.join(directory, name),
                            isDirectory: true,
                            isSymlink: false,
                            size: 0,
                            modified: "—",
                            permissions: "app",
                            linkTarget: nil)
        }
    }
}

/// 一个独立文件浏览窗口的数据源。
final class DeviceFileBrowserModel: ObservableObject {
    let adbPath: String
    let serial: String
    let deviceName: String

    @Published var path: String
    @Published var entries: [DeviceFileEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var statusText = "正在读取手机目录…"
    @Published var selectedPaths: Set<String> = []
    @Published var isGrid = false
    @Published var showHidden = false
    @Published var isBusy = false
    @Published var transferProgress: Int?
    @Published var lastDownloadedURL: URL?
    @Published private(set) var backStack: [String] = []

    private var loadToken = UUID()
    private var pendingSelectionPath: String?

    init(adbPath: String, serial: String, deviceName: String, startPath: String = "/sdcard") {
        self.adbPath = adbPath
        self.serial = serial
        self.deviceName = deviceName
        self.path = DevicePath.normalize(startPath)
    }

    /// 单选时返回该路径；多选时返回 nil。保留这个 computed 属性给只适合单选的按钮使用。
    var selectedPath: String? {
        get { selectedPaths.count == 1 ? selectedPaths.first : nil }
        set { selectedPaths = newValue.map { [$0] } ?? [] }
    }

    var selectedEntries: [DeviceFileEntry] {
        entries.filter { selectedPaths.contains($0.path) }
    }

    var selectedEntry: DeviceFileEntry? {
        selectedPaths.count == 1 ? selectedEntries.first : nil
    }

    func entry(for path: String) -> DeviceFileEntry? {
        entries.first { $0.path == path }
    }

    /// 根目录下只隐藏系统软链和不可访问的占位项；保留 /sdcard 这类用户存储快捷方式。
    private static let hiddenRootLinks: Set<String> = [
        "bin", "bugreports", "cache", "d", "etc", "init"
    ]

    var visibleEntries: [DeviceFileEntry] {
        entries.filter { entry in
            if !showHidden && entry.isHidden { return false }
            if path == "/" {
                if entry.isSymlink && Self.hiddenRootLinks.contains(entry.name) { return false }
                if entry.permissions.contains("?") { return false }
            }
            return true
        }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoUp: Bool { path != "/" }

    var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
    }

    // MARK: - 浏览

    func reload() {
        let target = path
        let token = UUID()
        loadToken = token
        isLoading = true
        errorMessage = nil

        let adb = adbPath
        let serial = self.serial
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ADB.listDirectory(adb: adb, serial: serial, path: target)
            DispatchQueue.main.async {
                guard let self, self.loadToken == token, self.path == target else { return }
                self.isLoading = false
                if let entries = result.entries {
                    self.entries = entries
                    self.errorMessage = nil
                    self.statusText = "共 \(self.visibleEntries.count) 项"
                    if let pending = self.pendingSelectionPath {
                        if entries.contains(where: { $0.path == pending }) {
                            self.selectedPaths = [pending]
                        } else {
                            self.selectedPaths.removeAll()
                        }
                        self.pendingSelectionPath = nil
                    } else {
                        self.selectedPaths.formIntersection(Set(entries.map(\.path)))
                    }
                } else {
                    self.entries = []
                    self.errorMessage = result.error ?? "无法读取这个目录"
                    self.statusText = "读取失败"
                }
            }
        }
    }

    func navigate(to rawPath: String, selecting selection: String? = nil) {
        let target = DevicePath.normalize(rawPath)
        guard !DevicePath.isHostOnlyPath(target) else {
            errorMessage = "只能浏览手机目录，不能跳转到电脑的系统目录"
            statusText = "已阻止电脑路径"
            return
        }
        if !path.isEmpty && target != path {
            backStack.append(path)
            if backStack.count > 50 { backStack.removeFirst() }
        }
        path = target
        selectedPaths.removeAll()
        pendingSelectionPath = selection
        reload()
    }

    /// 路径栏输入：目录直接进入；精确文件路径则进入父目录并选中该文件，不打开文件。
    func openPath(_ rawPath: String) {
        let target = DevicePath.normalize(rawPath)
        guard !DevicePath.isHostOnlyPath(target) else {
            errorMessage = "只能浏览手机目录，不能跳转到电脑的系统目录"
            statusText = "已阻止电脑路径"
            return
        }
        let adb = adbPath
        let serial = self.serial
        isLoading = true
        errorMessage = nil
        statusText = "正在定位…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let kind = ADB.itemKind(adb: adb, serial: serial, path: target)
            DispatchQueue.main.async {
                guard let self else { return }
                switch kind {
                case .directory:
                    self.navigate(to: target)
                case .file:
                    let parent = DevicePath.parent(of: target)
                    let name = (target as NSString).lastPathComponent
                    self.navigate(to: parent, selecting: target)
                    self.statusText = "已定位 \(name)"
                case .missing:
                    self.isLoading = false
                    self.errorMessage = "路径不存在：\(target)"
                    self.statusText = "路径不存在"
                }
            }
        }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        path = previous
        selectedPaths.removeAll()
        pendingSelectionPath = nil
        reload()
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: DevicePath.parent(of: path))
    }

    func refresh() { reload() }

    func toggleHidden() {
        showHidden.toggle()
        statusText = "共 \(visibleEntries.count) 项"
    }

    func open(_ entry: DeviceFileEntry) {
        if entry.isDirectory {
            navigate(to: entry.path)
        } else if entry.isSymlink {
            openSymlink(entry)
        } else {
            downloadAndOpen(entry)
        }
    }

    /// 软链/文件夹快捷方式先确认目标是否为目录，是则跳转，不是再按文件下载。
    private func openSymlink(_ entry: DeviceFileEntry) {
        guard !isBusy else { return }
        statusText = "正在解析快捷方式…"
        let adb = adbPath
        let serial = self.serial
        let path = entry.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isDirectory = ADB.isDirectory(adb: adb, serial: serial, path: path)
            DispatchQueue.main.async {
                guard let self else { return }
                if isDirectory {
                    self.navigate(to: path)
                } else {
                    self.downloadAndOpen(entry)
                }
            }
        }
    }

    // MARK: - 下载 / 打开

    func download(_ entry: DeviceFileEntry, to destination: URL, completion: ((Bool) -> Void)? = nil) {
        guard !entry.isDirectory else {
            statusText = "文件夹不能直接下载"
            completion?(false)
            return
        }
        guard !isBusy else { return }
        isBusy = true
        transferProgress = 0
        statusText = "正在下载 \(entry.name)…"

        let adb = adbPath
        let serial = self.serial
        let parent = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        let timeout = max(60, min(900, Double(max(entry.size, 1)) / 1024 / 1024 * 2 + 60))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ADB.pull(adb: adb,
                                  serial: serial,
                                  remotePath: entry.path,
                                  localPath: destination.path,
                                  timeout: timeout) { value in
                DispatchQueue.main.async { self?.transferProgress = value }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.transferProgress = nil
                if result.ok {
                    self.lastDownloadedURL = destination
                    self.statusText = "已下载 \(entry.name)"
                    completion?(true)
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    self.statusText = ADB.fileBrowserError(result, fallback: "下载失败")
                    completion?(false)
                }
            }
        }
    }

    /// 多选 / 目录下载：选择一个目标文件夹，按原名称直接保存进去，不重命名。
    func download(_ entries: [DeviceFileEntry], to directory: URL, completion: ((Bool) -> Void)? = nil) {
        guard !entries.isEmpty, !isBusy else { return }
        isBusy = true
        transferProgress = 0
        statusText = "正在下载 \(entries.count) 项…"
        let adb = adbPath
        let serial = self.serial
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            for (index, entry) in entries.enumerated() {
                let destination = directory.appendingPathComponent(entry.name)
                let timeout: TimeInterval = entry.isDirectory ? 600 : max(60, min(900, Double(max(entry.size, 1)) / 1024 / 1024 * 2 + 60))
                let result = ADB.pull(adb: adb,
                                      serial: serial,
                                      remotePath: entry.path,
                                      localPath: destination.path,
                                      timeout: timeout) { value in
                    let perFile = Double(value) / 100.0
                    let total = (Double(index) + perFile) / Double(entries.count)
                    let overall = Int(total * 100.0)
                    DispatchQueue.main.async { self?.transferProgress = overall }
                }
                if !result.ok {
                    failure = ADB.fileBrowserError(result, fallback: "下载 \(entry.name) 失败")
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.transferProgress = nil
                if let failure {
                    self.statusText = failure
                    completion?(false)
                } else {
                    self.lastDownloadedURL = directory
                    self.statusText = "已下载 \(entries.count) 项到 \(directory.lastPathComponent)"
                    completion?(true)
                }
            }
        }
    }

    /// 双击文件：下载到临时目录，再用默认应用打开。
    func downloadAndOpen(_ entry: DeviceFileEntry) {
        guard !isBusy else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTypeFileBrowser", isDirectory: true)
            .appendingPathComponent(serial, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(entry.name)
        download(entry, to: destination) { [weak self] ok in
            guard let self, ok else { return }
            self.statusText = "已打开 \(entry.name)"
            NSWorkspace.shared.open(destination)
        }
    }

    // MARK: - 上传

    func upload(_ urls: [URL], to destination: String? = nil) {
        guard !urls.isEmpty, !isBusy else { return }
        let directory = DevicePath.normalize(destination ?? path)
        guard !DevicePath.isHostOnlyPath(directory) else {
            statusText = "只能上传到手机目录"
            return
        }
        guard !DevicePath.isAppDataPath(directory) else {
            statusText = "应用数据目录只能浏览，不能上传"
            return
        }
        isBusy = true
        transferProgress = 0
        statusText = "正在上传 \(urls.count) 个文件…"

        let adb = adbPath
        let serial = self.serial
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            for (index, url) in urls.enumerated() {
                let remotePath = DevicePath.join(directory, url.lastPathComponent)
                let result = ADB.push(adb: adb,
                                      serial: serial,
                                      localPath: url.path,
                                      remotePath: remotePath,
                                      timeout: 300) { value in
                    let perFile = Double(value) / 100.0
                    let total = (Double(index) + perFile) / Double(urls.count)
                    let overall = Int(total * 100.0)
                    DispatchQueue.main.async { self?.transferProgress = overall }
                }
                if !result.ok {
                    failure = ADB.fileBrowserError(result, fallback: "上传 \(url.lastPathComponent) 失败")
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.transferProgress = nil
                if let failure {
                    self.statusText = failure
                } else {
                    self.statusText = "已上传 \(urls.count) 项"
                    if directory == self.path {
                        self.reload()
                    } else {
                        self.navigate(to: directory)
                    }
                }
            }
        }
    }

    /// 在指定目录新建空文件或文件夹，成功后进入该目录并选中新项目。
    func create(name: String, isDirectory: Bool, in directory: String) {
        guard !isBusy else { return }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            statusText = "名称无效"
            return
        }
        let parent = DevicePath.normalize(directory)
        guard !DevicePath.isHostOnlyPath(parent) else {
            statusText = "只能操作手机目录"
            return
        }
        guard !DevicePath.isAppDataPath(parent) else {
            statusText = "应用数据目录只能浏览，不能新建"
            return
        }
        let target = DevicePath.join(parent, name)
        isBusy = true
        statusText = isDirectory ? "正在新建文件夹…" : "正在新建文件…"
        let adb = adbPath
        let serial = self.serial
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ADB.create(adb: adb, serial: serial, path: target, isDirectory: isDirectory)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                if result.ok {
                    self.statusText = "已新建 \(name)"
                    if parent == self.path {
                        self.pendingSelectionPath = target
                        self.reload()
                    } else {
                        self.navigate(to: parent, selecting: target)
                    }
                } else {
                    self.statusText = ADB.fileBrowserError(result, fallback: "新建失败")
                }
            }
        }
    }

    /// 删除手机上的一个文件/文件夹。调用方必须先弹确认框；这里不会再询问。
    func delete(_ entry: DeviceFileEntry) {
        delete([entry])
    }

    /// 支持多选删除；每个目标仍会逐个执行，失败不会影响其它目标。
    func delete(_ targets: [DeviceFileEntry]) {
        guard !targets.isEmpty, !isBusy else { return }
        var unique: [DeviceFileEntry] = []
        var seen = Set<String>()
        for entry in targets where !seen.contains(entry.path) {
            seen.insert(entry.path)
            let target = DevicePath.normalize(entry.path)
            guard target != "/", !DevicePath.isHostOnlyPath(target), !DevicePath.isAppDataPath(target) else {
                statusText = "选中项包含不可删除的手机目录"
                return
            }
            unique.append(entry)
        }

        isBusy = true
        statusText = unique.count == 1 ? "正在删除 \(unique[0].name)…" : "正在删除 \(unique.count) 项…"
        let adb = adbPath
        let serial = self.serial
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var removed = Set<String>()
            var failures: [String] = []
            for entry in unique {
                let result = ADB.remove(adb: adb, serial: serial, path: entry.path)
                if result.ok {
                    removed.insert(entry.path)
                } else {
                    failures.append("\(entry.name): \(ADB.fileBrowserError(result, fallback: "删除失败"))")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.entries.removeAll { removed.contains($0.path) }
                self.selectedPaths.subtract(removed)
                if failures.isEmpty {
                    self.statusText = unique.count == 1 ? "已删除 \(unique[0].name)" : "已删除 \(unique.count) 项"
                    self.errorMessage = nil
                } else {
                    self.statusText = "已删除 \(removed.count) 项，\(failures.count) 项失败：\(failures[0])"
                }
            }
        }
    }

    func copyPath(_ path: String) {
        copyPaths([path])
    }

    /// 多选复制：所有路径用换行符拼接，粘贴时每行一个路径。
    func copyPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        statusText = paths.count == 1 ? "已复制路径" : "已复制 \(paths.count) 条路径"
    }

    func revealLastDownload() {
        guard let url = lastDownloadedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension ADB {
    /// 列出手机目录。ls 的原始输出交给 DeviceFileParser，UI 不直接解析。
    static func listDirectory(adb: String, serial: String, path: String) -> (entries: [DeviceFileEntry]?, error: String?) {
        let target = DevicePath.normalize(path)
        // 末尾必须带 /，否则 toybox ls 会把 /sdcard 这类符号链接本身列出来，而不是目录内容。
        let listingPath = target == "/" ? "/" : (target.hasSuffix("/") ? target : target + "/")
        let command = "ls -la " + shellQuote(listingPath)
        let result = run(adb, ["-s", serial, "shell", command], timeout: 25)
        if result.ok {
            return (DeviceFileParser.parse(result.text, directory: target), nil)
        }

        // /data + /data/data：普通 shell 通常被 SELinux 拒绝，但包名可以通过 pm 列出来。
        if target == "/data" {
            let dataEntry = DeviceFileEntry(name: "data",
                                            path: "/data/data",
                                            isDirectory: true,
                                            isSymlink: false,
                                            size: 0,
                                            modified: "—",
                                            permissions: "dir",
                                            linkTarget: nil)
            return ([dataEntry], nil)
        }
        if target == "/data/data" {
            if let packages = listPackages(adb: adb, serial: serial) {
                return (packages, nil)
            }
        }
        if target.hasPrefix("/data/data/") {
            if let runAs = listWithRunAs(adb: adb, serial: serial, path: target) {
                return runAs
            }
        }
        return (nil, fileBrowserError(result, fallback: "无法读取 \(target)"))
    }

    private static func listPackages(adb: String, serial: String) -> [DeviceFileEntry]? {
        let result = run(adb, ["-s", serial, "shell", "pm list packages"], timeout: 25)
        guard result.ok else { return nil }
        let entries = DeviceFileParser.parsePackages(result.text, directory: "/data/data")
        return entries.isEmpty ? nil : entries
    }

    /// debuggable 应用的数据目录：普通 shell 不可读，改用 run-as 以应用自身身份列目录。
    private static func listWithRunAs(adb: String, serial: String, path: String) -> (entries: [DeviceFileEntry]?, error: String?)? {
        let prefix = "/data/data/"
        let relative = String(path.dropFirst(prefix.count))
        let components = relative.split(separator: "/").map(String.init)
        guard let package = components.first, !package.isEmpty else { return nil }
        let subpath = components.dropFirst().joined(separator: "/")
        let command = "run-as " + shellQuote(package) + " ls -la " + shellQuote(subpath.isEmpty ? "." : subpath)
        let result = run(adb, ["-s", serial, "shell", command], timeout: 25)
        if result.ok {
            return (DeviceFileParser.parse(result.text, directory: path), nil)
        }
        let lower = result.text.lowercased()
        if lower.contains("not debuggable") {
            return (nil, "\(package) 不是 debuggable 应用，无法读取它的数据目录")
        }
        if lower.contains("not an application") {
            return (nil, "\(package) 没有可访问的应用数据目录")
        }
        return (nil, fileBrowserError(result, fallback: "无法读取 \(path)"))
    }

    /// 在手机上新建空文件或文件夹；先检查同名，避免覆盖已有内容。
    static func create(adb: String, serial: String, path: String, isDirectory: Bool) -> ShellResult {
        let target = DevicePath.normalize(path)
        guard target != "/" else {
            return ShellResult(status: -1, text: "不能在手机根目录执行这个操作", launched: true)
        }
        guard !DevicePath.isHostOnlyPath(target) else {
            return ShellResult(status: -1, text: "只能操作手机目录", launched: true)
        }
        let quoted = shellQuote(target)
        let check = run(adb, ["-s", serial, "shell", "if [ -e \(quoted) ]; then echo __adbtype_exists__; fi"], timeout: 15)
        if check.ok, check.text.contains("__adbtype_exists__") {
            return ShellResult(status: -1, text: "同名文件或文件夹已存在", launched: true)
        }
        let command = isDirectory ? "mkdir \(quoted)" : ": > \(quoted)"
        return run(adb, ["-s", serial, "shell", command], timeout: 20)
    }

    /// 删除手机上的文件或文件夹；只接受手机绝对路径，根目录直接拒绝。
    static func remove(adb: String, serial: String, path: String) -> ShellResult {
        let target = DevicePath.normalize(path)
        guard target != "/" else {
            return ShellResult(status: -1, text: "不能删除手机根目录", launched: true)
        }
        guard !DevicePath.isHostOnlyPath(target) else {
            return ShellResult(status: -1, text: "只能删除手机目录里的内容", launched: true)
        }
        guard !DevicePath.isAppDataPath(target) else {
            return ShellResult(status: -1, text: "应用数据目录只能浏览，不能删除", launched: true)
        }
        let command = "rm -rf " + shellQuote(target)
        return run(adb, ["-s", serial, "shell", command], timeout: 30)
    }

    enum ItemKind { case directory, file, missing }

    /// 判断手机路径类型；[ -d ] / [ -e ] 跟随软链，且只操作手机路径。
    static func itemKind(adb: String, serial: String, path: String) -> ItemKind {
        let normalized = DevicePath.normalize(path)
        // /data/data 对普通 shell 不可读，但包目录本身按目录处理；是否能展开由 run-as 再判断。
        if normalized == "/data" || normalized == "/data/data" || normalized.hasPrefix("/data/data/") {
            return .directory
        }
        let quoted = shellQuote(normalized)
        let command = "if [ -d \(quoted) ]; then echo __adbtype_dir__; elif [ -e \(quoted) ]; then echo __adbtype_file__; else echo __adbtype_missing__; fi"
        let result = run(adb, ["-s", serial, "shell", command], timeout: 15)
        guard result.ok else { return .missing }
        if result.text.contains("__adbtype_dir__") { return .directory }
        if result.text.contains("__adbtype_file__") { return .file }
        return .missing
    }

    /// 跟随软链判断目标是否为目录；[ -d ] 在 Android sh 里可用，且只操作手机路径。
    static func isDirectory(adb: String, serial: String, path: String) -> Bool {
        itemKind(adb: adb, serial: serial, path: path) == .directory
    }

    /// adb pull，带百分比回调。
    static func pull(adb: String,
                     serial: String,
                     remotePath: String,
                     localPath: String,
                     timeout: TimeInterval,
                     onProgress: ((Int) -> Void)? = nil) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["-s", serial, "pull", "-p", remotePath, localPath]
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
            if process.isRunning { process.terminate() }
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

    /// 文件浏览专用错误文案，避免把远端「目录不存在」误报成 adb 不可用。
    static func fileBrowserError(_ result: ShellResult, fallback: String) -> String {
        if !result.launched { return result.text }
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        if lower.contains("permission denied") { return "没有权限读取这个路径" }
        if lower.contains("no such file or directory") { return "路径不存在" }
        if lower.contains("not a directory") { return "这不是一个文件夹" }
        if lower.contains("no devices") || lower.contains("unauthorized") || lower.contains("offline") {
            return ADB.friendly(raw)
        }
        return raw.isEmpty ? fallback : ADB.shorten(raw, lines: 3)
    }
}
