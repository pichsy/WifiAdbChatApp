import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 「移动设备」页：上半部分发送文字到手机，下半部分把文件推到手机
struct MobileDeviceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var fileModel: FileTransferModel
    @FocusState private var inputFocused: Bool
    @State private var didFocusOnLaunch = false
    @State private var isFileDropTarget = false

    private let ticker = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                deviceCard
                sectionTitle("发送文字", detail: "输入后按 Enter 直接发送")
                inputCard
                optionsRow
                sendButton
                textStatusLine
                if !model.history.isEmpty { historySection }

                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)
                    Text("文件传输")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)
                }
                .padding(.vertical, 6)

                destinationCard
                dropZone
                actionRow
                if !fileModel.items.isEmpty {
                    fileList
                    fileSendRow
                }
                fileStatusLine
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            guard !didFocusOnLaunch else { return }
            didFocusOnLaunch = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                inputFocused = true
            }
        }
        .onReceive(ticker) { _ in
            model.autoTick()
        }
    }

    // MARK: - 卡片外观

    private var cardFill: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
    }

    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.07))
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    // MARK: - 设备

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("设备")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.scanning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.captureScreenshot()
                    ScreenshotWindowController.present(model: model)
                } label: {
                    Label("截屏", systemImage: "camera")
                }
                .controlSize(.small)
                .disabled(model.devices.isEmpty || model.screenshotBusy)
                .help("截取手机当前屏幕")
                Button {
                    model.refreshDevices(silent: false)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新设备列表")
            }

            if model.devices.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "iphone.slash")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("未检测到设备")
                            .font(.subheadline.weight(.medium))
                        Text(model.deviceError ?? "连接手机，并在开发者选项中开启 USB 调试")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(height: 34, alignment: .leading)
            } else {
                Picker("", selection: $model.selectedSerial) {
                    ForEach(model.devices) { device in
                        Text(device.displayName).tag(device.serial)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(cardFill)
        .overlay(cardStroke)
    }

    // MARK: - 文字输入

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("发送内容")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空输入") {
                    model.input = ""
                    inputFocused = true
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(model.input.isEmpty)
            }

            TextField("输入要发送的文字，中文也可以", text: $model.input)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .focused($inputFocused)
                .onSubmit { model.send() }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(inputFocused ? Color.accentColor : Color.primary.opacity(0.12),
                                      lineWidth: inputFocused ? 2 : 1)
                )

            HStack(spacing: 4) {
                Image(systemName: model.needsClipboard ? "doc.on.clipboard" : "bolt.fill")
                    .font(.caption)
                if model.needsClipboard {
                    Text("含中文或表情：复制到手机剪贴板，再到手机上长按输入框点「粘贴」")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("纯英文 / 数字：直接输入，秒发")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(cardFill)
        .overlay(cardStroke)
    }

    private var optionsRow: some View {
        HStack(spacing: 20) {
            Toggle("先清空设备输入框", isOn: $model.clearFirst)
                .toggleStyle(.checkbox)
                .disabled(model.needsClipboard)
                .help(model.needsClipboard ? "剪贴板模式下不会改动手机上的内容" : "")
            Toggle("发送后按回车键", isOn: $model.pressEnter)
                .toggleStyle(.checkbox)
                .disabled(model.needsClipboard)
                .help(model.needsClipboard ? "剪贴板模式下需要你在手机上粘贴完再按回车" : "")
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal, 2)
    }

    private var canSendText: Bool {
        !model.busy && !model.selectedSerial.isEmpty
    }

    private var sendButton: some View {
        Button {
            model.send()
        } label: {
            HStack(spacing: 8) {
                if model.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.needsClipboard ? "doc.on.clipboard" : "paperplane.fill")
                }
                Text(model.busy
                     ? (model.needsClipboard ? "正在复制…" : "发送中…")
                     : (model.needsClipboard ? "发送到设备剪贴板" : "发送到输入框"))
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
                Text("⌘ ↩")
                    .font(.caption.monospaced())
                    .opacity(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canSendText)
    }

    private var textStatusLine: some View {
        statusLine(kind: model.statusKind, text: model.statusText)
    }

    private func statusLine(kind: StatusKind, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: statusSymbol(kind))
                .foregroundStyle(statusColor(kind))
            Text(text)
                .font(.callout)
                .foregroundStyle(kind == .failure ? Color.red : Color.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    private func statusSymbol(_ kind: StatusKind) -> String {
        switch kind {
        case .idle: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ kind: StatusKind) -> Color {
        switch kind {
        case .idle: return .secondary
        case .success: return .green
        case .failure: return .red
        }
    }

    // MARK: - 历史

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("最近发送")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清除记录") { model.clearHistory() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.history, id: \.self) { item in
                        Button {
                            model.input = item
                            inputFocused = true
                        } label: {
                            Text(item)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                        .help("点击填入输入框")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 34)
        }
    }

    // MARK: - 文件目标目录

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("保存到手机")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") { fileModel.resetTargetDir() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                TextField("/sdcard/Download", text: $fileModel.targetDir)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                Text("手机目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("目标设备：\(model.selectedDevice?.displayName ?? "未连接手机")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(cardFill)
        .overlay(cardStroke)
    }

    // MARK: - 拖拽区

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: isFileDropTarget ? "arrow.down.doc.fill" : "arrow.up.doc")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(isFileDropTarget ? Color.accentColor : Color.secondary)
            Text("把文件拖到这里")
                .font(.headline)
            Text("也可以点这里选择文件，或用下方「从剪贴板粘贴」")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFileDropTarget ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(isFileDropTarget ? Color.accentColor : Color.primary.opacity(0.18))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { chooseFiles() }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isFileDropTarget) { providers in
            handleDrop(providers)
        }
        .disabled(fileModel.busy)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                chooseFiles()
            } label: {
                Label("选择文件…", systemImage: "folder.badge.plus")
            }
            .disabled(fileModel.busy)

            Button {
                fileModel.pasteFromClipboard()
            } label: {
                Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
            }
            .disabled(fileModel.busy)

            Spacer()

            if !fileModel.items.isEmpty {
                Button("清空列表") { fileModel.clearAll() }
                    .disabled(fileModel.busy)
            }
        }
        .controlSize(.regular)
    }

    // MARK: - 文件列表

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("待传文件（\(fileModel.items.count)）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: fileModel.totalBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(fileModel.items) { item in
                        fileRow(item)
                    }
                }
            }
            .frame(maxHeight: 170)
        }
    }

    private func fileRow(_ item: TransferItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if item.status == .sending, item.size > 0 {
                    ProgressView(value: item.progress)
                        .controlSize(.small)
                } else if let message = item.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if item.status == .done {
                    Text("已传输")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text(item.sizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            statusBadge(for: item)

            Button {
                fileModel.remove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .disabled(fileModel.busy)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    @ViewBuilder
    private func statusBadge(for item: TransferItem) -> some View {
        switch item.status {
        case .pending:
            Text("待传")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .sending:
            Text("\(Int(item.progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private var fileSendRow: some View {
        VStack(spacing: 6) {
            if fileModel.busy, fileModel.totalBytes > 0 {
                ProgressView(value: fileModel.overallProgress)
                    .controlSize(.small)
            }

            HStack(spacing: 10) {
                if fileModel.busy {
                    ProgressView().controlSize(.small)
                }
                Text(fileModel.busy ? "传输中…" : "共 \(fileModel.pendingCount) 个文件待传")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    fileModel.start(adb: model.adbPath, serial: model.selectedSerial)
                } label: {
                    Label("传到手机", systemImage: "arrow.up.circle.fill")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(fileModel.busy || fileModel.pendingCount == 0 || model.selectedSerial.isEmpty)
            }
        }
    }

    private var fileStatusLine: some View {
        statusLine(kind: fileModel.statusKind, text: fileModel.statusText)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: model.adbAvailable ? "terminal" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(model.adbAvailable ? Color.secondary : Color.orange)
            Text(model.adbPath.isEmpty ? "未找到 adb（platform-tools）" : model.adbPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Menu {
                Button("选择 adb 路径…") { model.chooseADB() }
                Button("重新自动检测") { model.redetectADB() }
                Button("在访达中显示") { model.revealADB() }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("adb 设置")
        }
    }

    // MARK: - 选择 / 拖拽

    private func chooseFiles() {
        guard !fileModel.busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要传到手机的文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK {
            fileModel.add(panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !fileModel.busy else { return false }
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else if let direct = item as? URL {
                    url = direct
                }
                if let url {
                    DispatchQueue.main.async {
                        fileModel.add([url])
                    }
                }
            }
        }
        return accepted
    }
}
