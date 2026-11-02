import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct PairingRequest: Identifiable {
    enum Action {
        case pair
        case text(String)
        case files([URL])
    }

    let id = UUID()
    let peer: LANPeer
    let peerName: String
    let action: Action
}

struct LANTransferView: View {
    @EnvironmentObject private var model: LANModel

    @State private var textDraft = ""
    @State private var stagedFiles: [URL] = []
    @State private var isFileDropTarget = false
    @State private var pairing: PairingRequest?
    @State private var codeInput = ""
    @State private var pairingError: String?
    @State private var showClearConfirm = false
    @FocusState private var codeFocused: Bool

    private var cardFill: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
    }

    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.07))
    }

    private var selectedPeer: LANPeer? {
        guard let id = model.selectedPeerID else { return nil }
        return model.peers.first { $0.id == id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                thisDeviceCard
                peersCard
                messagesCard
                sendTextCard
                sendFileCard
                if model.busy { sendProgressRow }
                statusLine
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $pairing) { request in
            pairingSheet(request)
        }
    }

    // MARK: - 本机

    private var thisDeviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("本机")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("已配对 \(model.pairedCount) 台")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.pairedCount > 0 {
                    Button("清除配对") { model.forgetPairs() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.deviceName)
                        .font(.headline)
                    Text("对方第一次连接你时，输入下面这个配对码；输过一次后会自动记住")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("你的配对码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.pairingCode.map(String.init).joined(separator: " "))
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Button("换一个配对码") { model.regenerateCode() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            if let name = model.pendingPairName {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("「\(name)」正在请求配对")
                            .font(.callout.weight(.medium))
                        Text("把本机配对码 \(model.pairingCode) 告诉对方，对方输入后即可互传")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Button("知道了") { model.clearPendingPair() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.1))
                )
            }

            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down")
                    .foregroundStyle(.secondary)
                Text(model.receiveDir)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(model.receiveDir)
                Spacer(minLength: 6)
                Button("修改接收目录") { model.chooseReceiveDir() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.receiveDir)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("在访达中打开接收目录")
            }
        }
        .padding(12)
        .background(cardFill)
        .overlay(cardStroke)
    }

    // MARK: - 附近设备

    private var peersCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("附近设备")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if model.peers.isEmpty {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("同一 Wi-Fi / 局域网")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if model.peers.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在搜索…")
                            .font(.subheadline.weight(.medium))
                        Text("在另一台 Mac 的「跨设备」页，或 Windows 电脑上打开 ADBType 传输端，并连同一个局域网")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minHeight: 34, alignment: .leading)
            } else {
                VStack(spacing: 4) {
                    ForEach(model.peers) { peer in
                        peerRow(peer)
                    }
                }
            }
        }
        .padding(12)
        .background(cardFill)
        .overlay(cardStroke)
    }

    private func peerRow(_ peer: LANPeer) -> some View {
        let selected = model.selectedPeerID == peer.id
        let paired = model.isPaired(peer.id)
        return HStack(spacing: 8) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
            Text(peer.name)
                .font(.callout.weight(selected ? .semibold : .regular))
                .lineLimit(1)
            if paired {
                Text("已配对")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
                    .foregroundStyle(.green)
            } else {
                Text("未配对")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 6)
            Text("在线")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !paired {
                Button("配对…") { beginPairing(peer) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.busy)
                    .help("输入对方屏幕上显示的 6 位配对码")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedPeerID = peer.id }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .contextMenu {
            Button("选中这台设备") { model.selectedPeerID = peer.id }
            if paired {
                Button("取消与「\(peer.name)」的配对") { model.forget(peer) }
            }
        }
    }

    // MARK: - 发送

    private var targetDetail: some View {
        Group {
            if let peer = selectedPeer {
                HStack(spacing: 4) {
                    Text("发给 \(peer.name)")
                    if !model.isPaired(peer.id) {
                        Text("· 首次发送需输入对方配对码")
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Text("先选择上面的设备")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var sendTextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("发送文字")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                targetDetail
            }

            HStack(spacing: 8) {
                TextField("输入要发给对方的文字", text: $textDraft)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .onSubmit { sendText() }

                Button {
                    sendText()
                } label: {
                    Label("发送文字", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || selectedPeer == nil
                          || textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(cardFill)
        .overlay(cardStroke)
    }

    private var sendFileCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("发送文件")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                targetDetail
            }

            fileDropZone

            if !stagedFiles.isEmpty {
                VStack(spacing: 3) {
                    ForEach(stagedFiles, id: \.self) { url in
                        stagedFileRow(url)
                    }
                }

                HStack(spacing: 8) {
                    Text(stagedFiles.count == 1
                         ? "1 个文件待发送"
                         : "\(stagedFiles.count) 个文件待发送")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清空") { stagedFiles.removeAll() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(model.busy)
                    Button {
                        sendStagedFiles()
                    } label: {
                        Label(stagedFiles.count == 1
                              ? "发送文件"
                              : "发送 \(stagedFiles.count) 个文件",
                              systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || selectedPeer == nil)
                }
            }
        }
        .padding(12)
        .background(cardFill)
        .overlay(cardStroke)
    }

    private func stagedFileRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(url.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(fileSizeText(url))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Button {
                removeStaged([url])
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("从待发送列表移除")
            .disabled(model.busy)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private var sendProgressRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: model.sendProgress)
                .controlSize(.small)
            Text("正在发送 \(model.activeSendLabel)…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    private var fileDropZone: some View {
        HStack(spacing: 10) {
            Image(systemName: isFileDropTarget ? "arrow.down.doc.fill" : "arrow.up.doc")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(isFileDropTarget ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(isFileDropTarget ? "松开后加入待发送列表" : "把文件拖到这里，选好后再点发送")
                    .font(.callout)
                Text("也可以点这里选择文件，支持一次多个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("选择文件…") { chooseFiles() }
                .disabled(model.busy)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isFileDropTarget ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.4, dash: [6, 5]))
                .foregroundStyle(isFileDropTarget ? Color.accentColor : Color.primary.opacity(0.18))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { chooseFiles() }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isFileDropTarget) { providers in
            handleDrop(providers)
        }
        .disabled(model.busy)
    }

    // MARK: - 消息记录（聊天式）

    private var messagesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("消息")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !model.messages.isEmpty {
                    Text("\(model.messages.count) 条")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !model.messages.isEmpty {
                    Button("清空记录") { showClearConfirm = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            if model.messages.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("还没有消息")
                            .font(.callout)
                        Text("收到的文字和文件会像聊天一样显示在这里，发出去的内容也会留在上面")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(model.messages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 2)
                    }
                    .frame(height: 230)
                    .onAppear {
                        if let last = model.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: model.messages.count) { _ in
                        if let last = model.messages.last {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(cardFill)
        .overlay(cardStroke)
        .alert("清空全部消息记录？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { model.clearMessages() }
        } message: {
            Text("只清空这里的聊天列表，已经收到的文件不会被删除。")
        }
    }

    private func messageRow(_ message: LANMessage) -> some View {
        let outgoing = message.direction == .outgoing
        return HStack(alignment: .top, spacing: 8) {
            if outgoing { Spacer(minLength: 48) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(outgoing ? "我 → \(message.peerName)" : message.peerName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if message.kind == .text {
                        Button {
                            model.copyText(message)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                        .help("复制这段文字")
                    }
                }
                bubble(for: message)
            }
            if !outgoing { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func bubble(for message: LANMessage) -> some View {
        let outgoing = message.direction == .outgoing
        let fill = outgoing
            ? Color.accentColor.opacity(0.14)
            : Color.primary.opacity(0.06)

        if message.kind == .text {
            Text(message.text ?? "")
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(fill)
                )
                .contextMenu {
                    Button("复制文字") { model.copyText(message) }
                }
        } else {
            HStack(spacing: 9) {
                Image(systemName: "doc.fill")
                    .font(.title3)
                    .foregroundStyle(outgoing ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.fileName ?? "文件")
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        if let size = message.fileSize, size > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size),
                                                           countStyle: .file))
                        }
                        Text(outgoing ? "已发送" : "已保存")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button(outgoing ? "打开" : "显示") {
                    model.revealFile(message)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help(message.filePath ?? "")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(fill)
            )
            .contextMenu {
                Button("在访达中显示") { model.revealFile(message) }
            }
        }
    }

    private func fileSizeText(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    // MARK: - 状态 / 底部

    private var statusLine: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(model.statusKind == .failure ? Color.red : Color.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(model.statusText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    private var statusSymbol: String {
        switch model.statusKind {
        case .idle: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch model.statusKind {
        case .idle: return .secondary
        case .success: return .green
        case .failure: return .red
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.caption)
            Text("文字和文件在两台设备之间直连传输，不经过服务器；点设备旁的「配对…」输入对方配对码即可")
                .font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 发送操作

    private func beginPairing(_ peer: LANPeer) {
        guard !model.busy else { return }
        pairingError = nil
        codeInput = ""
        pairing = PairingRequest(peer: peer, peerName: peer.name, action: .pair)
    }

    private func sendText() {
        guard let peer = selectedPeer else {
            model.statusKind = .failure
            model.statusText = "先在「附近设备」里选中对方"
            return
        }
        let value = textDraft
        model.sendText(value, to: peer, code: nil) { outcome in
            switch outcome {
            case .ok:
                textDraft = ""
            case .needsPairing(let name):
                pairingError = nil
                codeInput = ""
                pairing = PairingRequest(peer: peer, peerName: name, action: .text(value))
            case .failure:
                break
            }
        }
    }

    private func sendStagedFiles() {
        guard !stagedFiles.isEmpty else { return }
        sendFiles(stagedFiles)
    }

    private func sendFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let peer = selectedPeer else {
            model.statusKind = .failure
            model.statusText = "先在「附近设备」里选中对方"
            return
        }
        model.sendFiles(urls, to: peer, code: nil) { outcome in
            switch outcome {
            case .ok:
                removeStaged(urls)
            case .needsPairing(let name):
                pairingError = nil
                codeInput = ""
                pairing = PairingRequest(peer: peer, peerName: name, action: .files(urls))
            case .failure:
                break
            }
        }
    }

    private func addStagedFiles(_ urls: [URL]) {
        guard !model.busy else { return }
        var seen = Set(stagedFiles.map { $0.standardizedFileURL.path })
        for url in urls where url.isFileURL {
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                stagedFiles.append(standardized)
            }
        }
    }

    private func removeStaged(_ urls: [URL]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        stagedFiles.removeAll { paths.contains($0.standardizedFileURL.path) }
    }

    private func confirmPairing() {
        guard let request = pairing else { return }
        let code = codeInput.trimmingCharacters(in: .whitespaces)
        guard code.count == 6 else {
            pairingError = "请输入对方屏幕上的 6 位数字"
            return
        }
        pairingError = nil

        let retry: (LANOutcome) -> Void = { outcome in
            switch outcome {
            case .ok:
                pairing = nil
                pairingError = nil
                switch request.action {
                case .pair:
                    break
                case .text:
                    textDraft = ""
                case .files(let urls):
                    removeStaged(urls)
                }
            case .needsPairing:
                pairingError = "配对码不对，看看对方屏幕上显示的数字再试一次"
            case .failure(let message):
                pairingError = message
            }
        }

        switch request.action {
        case .pair:
            model.pair(with: request.peer, code: code, completion: retry)
        case .text(let value):
            model.sendText(value, to: request.peer, code: code, completion: retry)
        case .files(let urls):
            model.sendFiles(urls, to: request.peer, code: code, completion: retry)
        }
    }

    // MARK: - 配对面板

    private func pairingSheet(_ request: PairingRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "key.horizontal.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("与「\(request.peerName)」配对")
                    .font(.title3.weight(.semibold))
            }

            Text(pairingHelp(for: request))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("6 位配对码", text: $codeInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .focused($codeFocused)
                    .onChange(of: codeInput) { newValue in
                        let digits = String(newValue.filter { $0.isNumber }.prefix(6))
                        if digits != newValue { codeInput = digits }
                    }
                    .onSubmit { confirmPairing() }

                Button("粘贴") { pastePairingCode() }
                    .controlSize(.large)
                    .help("从剪贴板粘贴配对码")
            }

            if let pairingError {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(pairingError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.red)
            }

            HStack {
                Button("取消") {
                    pairing = nil
                    pairingError = nil
                }
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small)
                }
                Button(pairingConfirmTitle(for: request.action)) { confirmPairing() }
                    .buttonStyle(.borderedProminent)
                    .disabled(codeInput.count != 6 || model.busy)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                codeFocused = true
            }
        }
        .onDisappear { codeFocused = false }
    }

    private func pairingHelp(for request: PairingRequest) -> String {
        switch request.action {
        case .pair:
            return "在对方电脑的 ADBType「电脑设备」页顶部，可以看到 6 位配对码。输入一次后两台设备会互相信任，以后直接发送；也可以直接粘贴。"
        case .text, .files:
            return "这是第一次和「\(request.peerName)」互传。在对方电脑的「电脑设备」页顶部找到 6 位配对码，输入后会把这次内容发过去，并记住对方。"
        }
    }

    private func pairingConfirmTitle(for action: PairingRequest.Action) -> String {
        if case .pair = action { return "配对" }
        return "配对并发送"
    }

    private func pastePairingCode() {
        let raw = NSPasteboard.general.string(forType: .string) ?? ""
        let digits = String(raw.filter { $0.isNumber }.prefix(6))
        if !digits.isEmpty {
            codeInput = digits
        }
    }

    // MARK: - 选择 / 拖拽

    private func chooseFiles() {
        guard !model.busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要发送的文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK {
            addStagedFiles(panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.busy else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        var accepted = false

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            group.enter()
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
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        guard accepted else { return false }
        group.notify(queue: .main) {
            addStagedFiles(urls)
        }
        return true
    }
}
