import SwiftUI
import AppKit

/// 独立的手机文件浏览窗口：左侧常用目录，右侧文件列表。
struct DeviceFileBrowserView: View {
    @StateObject private var model: DeviceFileBrowserModel
    @State private var pathDraft: String
    @State private var toastMessage: String?
    @State private var toastWork: DispatchWorkItem?

    init(adbPath: String, device: ADBDevice) {
        _model = StateObject(wrappedValue: DeviceFileBrowserModel(adbPath: adbPath,
                                                                  serial: device.serial,
                                                                  deviceName: device.displayName))
        _pathDraft = State(initialValue: "/sdcard")
    }

    private struct Location: Identifiable {
        let name: String
        let path: String
        let icon: String
        var id: String { path }
    }

    private let locations: [Location] = [
        Location(name: "内部存储", path: "/sdcard", icon: "internaldrive"),
        Location(name: "下载", path: "/sdcard/Download", icon: "arrow.down.circle"),
        Location(name: "图片", path: "/sdcard/Pictures", icon: "photo"),
        Location(name: "相机", path: "/sdcard/DCIM", icon: "camera"),
        Location(name: "临时目录", path: "/data/local/tmp", icon: "clock"),
        Location(name: "根目录", path: "/", icon: "externaldrive")
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                sidebar
                    .frame(minWidth: 170, idealWidth: 190, maxWidth: 220)
                content
                    .frame(minWidth: 540)
            }
            Divider()
            footer
        }
        .frame(minWidth: 780, minHeight: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            pathDraft = model.path
            model.reload()
        }
        .onChange(of: model.path) { newPath in
            pathDraft = newPath
        }
        .onChange(of: model.selectedPath) { _ in
            // 输入精确文件路径时父目录可能等于当前目录，path 不变，也要把路径栏更新到文件夹。
            pathDraft = model.path
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(toastMessage)
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
                .padding(.bottom, 46)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: toastMessage)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            Label("设备文件", systemImage: "folder")
                .font(.headline)
            Text(model.deviceName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)

            Button {
                if let entry = model.selectedEntry { model.open(entry) }
            } label: {
                Label("打开", systemImage: "arrow.up.right.square")
            }
            .controlSize(.small)
            .disabled(model.selectedEntry == nil || model.isBusy)
            .help("打开选中的文件或文件夹")

            Button {
                downloadSelected()
            } label: {
                Label("下载", systemImage: "square.and.arrow.down")
            }
            .controlSize(.small)
            .disabled(model.selectedEntry == nil || model.selectedEntry?.isDirectory == true || model.isBusy)
            .help("把选中的文件下载到 Mac")

            Button {
                upload()
            } label: {
                Label("上传", systemImage: "square.and.arrow.up")
            }
            .controlSize(.small)
            .disabled(model.isBusy)
            .help("把 Mac 上的文件 / 文件夹上传到当前目录")

            Button(role: .destructive) {
                confirmDeleteSelected()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(model.selectedEntry == nil || model.isBusy)
            .keyboardShortcut(.delete, modifiers: .command)
            .help("删除选中的文件或文件夹（⌘⌫），会先确认")

            Button {
                model.toggleHidden()
            } label: {
                Image(systemName: model.showHidden ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .help(model.showHidden ? "隐藏以 . 开头的文件" : "显示隐藏文件")

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)
            .help("刷新当前目录")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 左侧常用目录

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("常用位置")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                ForEach(locations) { location in
                    Button {
                        model.navigate(to: location.path)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: location.icon)
                                .frame(width: 16)
                                .foregroundStyle(model.path == location.path ? Color.accentColor : .secondary)
                            Text(location.name)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(model.path == location.path ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(location.path)
                }

                Divider()
                    .padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text("设备")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(model.deviceName)
                        .font(.caption)
                        .lineLimit(2)
                    Text(model.serial)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    // MARK: - 右侧文件列表

    private var content: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            columnHeader
            Divider()

            ZStack {
                if model.isLoading && model.entries.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取手机目录…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = model.errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 360)
                        Button("重试") { model.refresh() }
                    }
                    .padding(24)
                } else if model.visibleEntries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "folder")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("这个目录是空的")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.visibleEntries.enumerated()), id: \.element.id) { index, entry in
                                fileRow(entry, index: index)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contextMenu {
            blankContextMenu
        }
    }

    @ViewBuilder
    private var blankContextMenu: some View {
        Menu("新建") {
            Button("文件") { promptCreate(in: model.path, isDirectory: false) }
            Button("文件夹") { promptCreate(in: model.path, isDirectory: true) }
        }
        Button("上传到当前目录…") { upload(to: model.path) }
        Divider()
        Button("刷新") { model.refresh() }
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .help("后退")

            Button {
                model.goUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canGoUp)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("上一级")

            TextField("/sdcard", text: $pathDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit {
                    model.openPath(pathDraft)
                }

            Button("前往") {
                model.openPath(pathDraft)
            }
            .controlSize(.small)
            .disabled(pathDraft == model.path)

            Spacer(minLength: 4)

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                if let progress = model.transferProgress {
                    Text("\(progress)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("名称")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("大小")
                .frame(width: 78, alignment: .trailing)
            Text("修改时间")
                .frame(width: 132, alignment: .leading)
            Text("权限")
                .frame(width: 92, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func fileRow(_ entry: DeviceFileEntry, index: Int) -> some View {
        let selected = model.selectedPath == entry.path
        return HStack(spacing: 10) {
            Image(systemName: entry.iconName)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let target = entry.linkTarget {
                    Text("→ \(target)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.isDirectory ? "—" : byteString(entry.size))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)

            Text(entry.modified)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 132, alignment: .leading)

            Text(entry.permissions)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .background(
            selected
                ? Color.accentColor.opacity(0.55)
                : (index.isMultiple(of: 2) ? Color.primary.opacity(0.022) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.selectedPath = entry.path
            model.open(entry)
        }
        .onTapGesture {
            model.selectedPath = entry.path
        }
        .contextMenu {
            Menu("新建") {
                Button("文件") { promptCreate(in: creationDirectory(for: entry), isDirectory: false) }
                Button("文件夹") { promptCreate(in: creationDirectory(for: entry), isDirectory: true) }
            }
            Button("上传到当前目录…") { upload(to: model.path) }
            Divider()
            Button(entry.isDirectory ? "打开文件夹" : "打开文件") {
                model.selectedPath = entry.path
                model.open(entry)
            }
            Button("下载到 Mac…") {
                model.selectedPath = entry.path
                downloadSelected()
            }
            .disabled(entry.isDirectory || model.isBusy)
            Divider()
            Button("复制路径") {
                model.copyPath(entry.path)
                showToast("已复制路径")
            }
            Divider()
            Button(role: .destructive) {
                model.selectedPath = entry.path
                confirmDelete(entry)
            } label: {
                Label("删除…", systemImage: "trash")
            }
            .disabled(model.isBusy)
        }
    }

    // MARK: - 底部状态

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = model.errorMessage, !error.isEmpty {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if model.isBusy, let progress = model.transferProgress {
                ProgressView(value: Double(progress), total: 100)
                    .frame(width: 110)
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.lastDownloadedURL != nil {
                Button("在 Finder 中显示") {
                    model.revealLastDownload()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            Text("\(model.visibleEntries.count) 项")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 动作

    /// 右键文件夹：建在文件夹里；右键文件 / 空白：建在当前目录。
    private func creationDirectory(for entry: DeviceFileEntry) -> String {
        entry.isDirectory ? entry.path : model.path
    }

    private func promptCreate(in directory: String, isDirectory: Bool) {
        guard !model.isBusy else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isDirectory ? "新建文件夹" : "新建文件"
        alert.informativeText = "位置：\(directory)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = isDirectory ? "文件夹名称" : "文件名（可带扩展名）"
        alert.accessoryView = field
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "创建")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = nameValidationError(name) {
            showNameError(error)
            return
        }
        model.create(name: name, isDirectory: isDirectory, in: directory)
    }

    private func nameValidationError(_ name: String) -> String? {
        if name.isEmpty { return "名称不能为空。" }
        if name == "." || name == ".." { return "名称不能是 . 或 ..。" }
        if name.contains("/") { return "名称不能包含 /。" }
        if name.rangeOfCharacter(from: .newlines) != nil { return "名称不能包含换行。" }
        if name.utf8.count > 255 { return "名称不能超过 255 个字节。" }
        return nil
    }

    private func showNameError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "名称无效"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func confirmDeleteSelected() {
        guard let entry = model.selectedEntry else { return }
        confirmDelete(entry)
    }

    /// 任何删除入口都必须先到这里；默认焦点在「取消」，不会静默删除。
    private func confirmDelete(_ entry: DeviceFileEntry) {
        guard !model.isBusy else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = entry.isDirectory ? "删除文件夹？" : "删除文件？"
        let detail = entry.isDirectory
            ? "将从手机永久删除这个文件夹及其中的所有内容，此操作无法撤销。"
            : "将从手机永久删除这个文件，此操作无法撤销。"
        alert.informativeText = detail + "\n\n" + entry.path
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "删除")
        if #available(macOS 11.0, *) {
            alert.buttons[1].hasDestructiveAction = true
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            model.delete(entry)
        }
    }

    private func downloadSelected() {
        guard let entry = model.selectedEntry, !entry.isDirectory else {
            showToast("请先选择一个文件")
            return
        }
        let panel = NSSavePanel()
        panel.title = "下载到 Mac"
        panel.prompt = "下载"
        panel.nameFieldStringValue = entry.name
        panel.directoryURL = model.downloadsDirectory
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            model.download(entry, to: url) { ok in
                if ok { showToast("已下载 \(entry.name)") }
            }
        }
    }

    private func upload(to destination: String? = nil) {
        let panel = NSOpenPanel()
        panel.title = "上传到手机"
        panel.prompt = "上传"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK {
            model.upload(panel.urls, to: destination)
        }
    }

    private func byteString(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func showToast(_ message: String) {
        toastWork?.cancel()
        toastMessage = message
        let work = DispatchWorkItem { toastMessage = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }
}
