import SwiftUI
import AppKit

/// 独立的手机文件浏览窗口：左侧常用目录，右侧文件列表。
struct DeviceFileBrowserView: View {
    @StateObject private var model: DeviceFileBrowserModel
    @State private var pathDraft: String
    @State private var toastMessage: String?
    @State private var toastWork: DispatchWorkItem?
    @State private var gridAnchorPath: String?

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
        Location(name: "应用数据", path: "/data/data", icon: "shippingbox"),
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
        .background(
            RightClickObserver(
                onSelect: { path in
                    if !model.selectedPaths.contains(path) {
                        model.selectedPaths = [path]
                    }
                },
                onSingleClick: { path in
                    model.selectedPaths = [path]
                },
                onOpen: { path in
                    if let entry = model.entry(for: path) { model.open(entry) }
                }
            )
        )
        .onAppear {
            pathDraft = model.path
            model.reload()
        }
        .onChange(of: model.path) { newPath in
            pathDraft = newPath
        }
        .onChange(of: model.selectedPaths) { _ in
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
            .disabled(model.selectedEntries.isEmpty || model.isBusy)
            .help("把选中的文件 / 目录下载到 Mac")

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
            .disabled(model.selectedEntries.isEmpty || model.isBusy)
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
            if !model.isGrid {
                columnHeader
                Divider()
            }

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
                } else if model.isGrid {
                    fileGrid
                } else {
                    List(selection: $model.selectedPaths) {
                        ForEach(Array(model.visibleEntries.enumerated()), id: \.element.id) { index, entry in
                            fileRow(entry, index: index)
                                .tag(entry.path)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
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

            Button {
                model.isGrid.toggle()
            } label: {
                Image(systemName: model.isGrid ? "list.bullet" : "square.grid.2x2")
            }
            .buttonStyle(.borderless)
            .help(model.isGrid ? "切换为列表" : "切换为网格")
            .accessibilityLabel(model.isGrid ? "切换为列表" : "切换为网格")

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


    private var fileGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("grid-top")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 160), spacing: 14)],
                              alignment: .leading,
                              spacing: 14) {
                        ForEach(model.visibleEntries) { entry in
                            gridCell(entry)
                        }
                    }
                    .padding(14)
                }
            }
            .id("fileGrid-\(model.path)")
            .onAppear { scrollGridToTop(proxy) }
            .onChange(of: model.path) { _ in scrollGridToTop(proxy) }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.18))
    }

    private func scrollGridToTop(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("grid-top", anchor: .top)
        }
    }

    private func gridCell(_ entry: DeviceFileEntry) -> some View {
        let selected = model.selectedPaths.contains(entry.path)
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
                if DeviceThumbnailView.supports(entry) {
                    DeviceThumbnailView(entry: entry, adbPath: model.adbPath, serial: model.serial)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Image(systemName: entry.iconName)
                        .font(.system(size: 34))
                        .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                }
            }
            .frame(height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(spacing: 2) {
                Text(entry.name)
                    .font(.caption)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                Text(entry.isDirectory ? "—" : byteString(entry.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .top)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 148, maxHeight: 148, alignment: .top)
        .background(
            selected ? Color.accentColor.opacity(0.42) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .background(RowHitTarget(path: entry.path))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { handleGridClick(entry) }
        .contextMenu { rowContextMenu(entry) }
        .help(entry.path)
    }

    private func handleGridClick(_ entry: DeviceFileEntry) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.selectedPaths.contains(entry.path) {
                model.selectedPaths.remove(entry.path)
            } else {
                model.selectedPaths.insert(entry.path)
            }
            gridAnchorPath = entry.path
        } else if flags.contains(.shift) {
            let entries = model.visibleEntries
            let anchor = gridAnchorPath ?? model.selectedPaths.first ?? entry.path
            if let start = entries.firstIndex(where: { $0.path == anchor }),
               let end = entries.firstIndex(where: { $0.path == entry.path }) {
                let range = start <= end ? start...end : end...start
                model.selectedPaths = Set(entries[range].map(\.path))
            } else {
                model.selectedPaths = [entry.path]
            }
        } else {
            model.selectedPaths = [entry.path]
            gridAnchorPath = entry.path
        }
    }

    private func fileRow(_ entry: DeviceFileEntry, index: Int) -> some View {
        let selected = model.selectedPaths.contains(entry.path)
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
        .background(RowHitTarget(path: entry.path))
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(Color.accentColor).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { rowContextMenu(entry) }
    }

    @ViewBuilder
    private func rowContextMenu(_ entry: DeviceFileEntry) -> some View {
        let multipleSelected = model.selectedPaths.count > 1 && model.selectedPaths.contains(entry.path)
        if multipleSelected || model.isBusy {
            Button("新建") {}
                .disabled(true)
        } else {
            Menu("新建") {
                Button("文件") { promptCreate(in: creationDirectory(for: entry), isDirectory: false) }
                Button("文件夹") { promptCreate(in: creationDirectory(for: entry), isDirectory: true) }
            }
        }
        Button(entry.isDirectory ? "上传到此文件夹…" : "上传到当前目录…") {
            upload(to: creationDirectory(for: entry))
        }
        .disabled(multipleSelected || model.isBusy)
        Divider()
        Button(entry.isDirectory ? "打开文件夹" : "打开文件") {
            model.open(entry)
        }
        .disabled(multipleSelected || model.isBusy)
        Button("下载到 Mac…") {
            downloadEntries(deleteTargets(for: entry))
        }
        .disabled(model.isBusy)
        Divider()
        Button("复制路径") {
            let paths = multipleSelected ? model.selectedEntries.map(\.path) : [entry.path]
            model.copyPaths(paths)
            showToast(paths.count == 1 ? "已复制路径" : "已复制 \(paths.count) 条路径")
        }
        Divider()
        Button {
            model.refresh()
        } label: {
            Label("刷新", systemImage: "arrow.clockwise")
        }
        Divider()
        Button(role: .destructive) {
            confirmDelete(deleteTargets(for: entry))
        } label: {
            Label("删除…", systemImage: "trash")
        }
        .disabled(model.isBusy)
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
            if model.selectedPaths.count > 1 {
                Text("已选 \(model.selectedPaths.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    private func deleteTargets(for entry: DeviceFileEntry) -> [DeviceFileEntry] {
        model.selectedPaths.contains(entry.path) ? model.selectedEntries : [entry]
    }

    private func confirmDeleteSelected() {
        guard !model.selectedEntries.isEmpty else { return }
        confirmDelete(model.selectedEntries)
    }

    /// 任何删除入口都必须先到这里；默认焦点在「取消」，不会静默删除。
    private func confirmDelete(_ entries: [DeviceFileEntry]) {
        guard !entries.isEmpty, !model.isBusy else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if entries.count == 1, let entry = entries.first {
            alert.messageText = entry.isDirectory ? "删除文件夹？" : "删除文件？"
            let detail = entry.isDirectory
                ? "将从手机永久删除这个文件夹及其中的所有内容，此操作无法撤销。"
                : "将从手机永久删除这个文件，此操作无法撤销。"
            alert.informativeText = detail + "\n\n" + entry.path
        } else {
            alert.messageText = "删除 \(entries.count) 个项目？"
            let names = entries.prefix(6).map(\.name).joined(separator: "\n")
            alert.informativeText = "将从手机永久删除选中的 \(entries.count) 个项目；文件夹会连同里面的内容一起删除。\n此操作无法撤销。\n\n\(names)"
        }
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "删除")
        if #available(macOS 11.0, *) {
            alert.buttons[1].hasDestructiveAction = true
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            model.delete(entries)
        }
    }

    private func downloadSelected() {
        downloadEntries(model.selectedEntries)
    }

    /// 单个文件才弹重命名保存框；目录或多选用一个目标文件夹直接保存，不重命名。
    private func downloadEntries(_ entries: [DeviceFileEntry]) {
        guard !entries.isEmpty else { return }
        if entries.count == 1, let entry = entries.first, !entry.isDirectory {
            download(entry)
            return
        }
        let panel = NSOpenPanel()
        panel.title = entries.count == 1 ? "选择保存文件夹" : "下载 \(entries.count) 个项目到…"
        panel.prompt = "下载到这里"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.downloadsDirectory
        if panel.runModal() == .OK, let directory = panel.url {
            model.download(entries, to: directory) { ok in
                if ok { showToast("已下载 \(entries.count) 项") }
            }
        }
    }

    private func download(_ entry: DeviceFileEntry) {
        guard !entry.isDirectory else {
            showToast("文件夹不能直接下载")
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

/// 每行背后挂一个透明 NSView，用来把右键的屏幕坐标精确映射到行；
/// 不依赖 SwiftUI 的 geometry 坐标，避免标题栏/滚动偏移导致选错。
private final class RowHitRegistry {
    static let shared = RowHitRegistry()
    private var views: [String: WeakView] = [:]

    private struct WeakView {
        weak var view: NSView?
    }

    func register(path: String, view: NSView) {
        views[path] = WeakView(view: view)
    }

    func unregister(path: String, view: NSView) {
        if let existing = views[path]?.view, existing === view {
            views.removeValue(forKey: path)
        }
    }

    func path(at screenPoint: NSPoint) -> String? {
        for (path, box) in views {
            guard let view = box.view, let window = view.window else { continue }
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let local = view.convert(windowPoint, from: nil)
            if view.bounds.contains(local) { return path }
        }
        return nil
    }
}

private final class RowHitView: NSView {
    var path: String
    init(path: String) {
        self.path = path
        super.init(frame: .zero)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { RowHitRegistry.shared.register(path: path, view: self) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { RowHitRegistry.shared.unregister(path: path, view: self) }
}

private struct RowHitTarget: NSViewRepresentable {
    let path: String
    func makeNSView(context: Context) -> NSView { RowHitView(path: path) }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? RowHitView else { return }
        if view.path != path {
            RowHitRegistry.shared.unregister(path: view.path, view: view)
            view.path = path
            if view.window != nil { RowHitRegistry.shared.register(path: path, view: view) }
        }
    }
}

private struct RightClickObserver: NSViewRepresentable {
    let onSelect: (String) -> Void
    let onSingleClick: (String) -> Void
    let onOpen: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        context.coordinator.install()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.parent = self }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.uninstall() }

    final class Coordinator {
        var parent: RightClickObserver
        private var rightMonitor: Any?
        private var leftMonitor: Any?
        private var lastLeftPath: String?
        private var lastLeftTime: TimeInterval = 0
        init(parent: RightClickObserver) { self.parent = parent }

        private func path(for event: NSEvent) -> String? {
            guard let window = event.window else { return nil }
            let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
            return RowHitRegistry.shared.path(at: screenPoint)
        }

        func install() {
            if rightMonitor == nil {
                rightMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                    if let self, let path = self.path(for: event) { self.parent.onSelect(path) }
                    return event
                }
            }
            if leftMonitor == nil {
                leftMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    guard let self else { return event }
                    let now = ProcessInfo.processInfo.systemUptime
                    let path = self.path(for: event)
                    if event.clickCount == 1 {
                        self.lastLeftPath = path
                        self.lastLeftTime = now
                        let modifiers = event.modifierFlags.intersection([.command, .shift])
                        if modifiers.isEmpty, let path {
                            self.parent.onSingleClick(path)
                        }
                    } else if event.clickCount == 2,
                              let path,
                              path == self.lastLeftPath,
                              now - self.lastLeftTime < 0.8 {
                        self.parent.onOpen(path)
                        self.lastLeftPath = nil
                    }
                    return event
                }
            }
        }

        func uninstall() {
            if let rightMonitor { NSEvent.removeMonitor(rightMonitor); self.rightMonitor = nil }
            if let leftMonitor { NSEvent.removeMonitor(leftMonitor); self.leftMonitor = nil }
        }
        deinit { uninstall() }
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
