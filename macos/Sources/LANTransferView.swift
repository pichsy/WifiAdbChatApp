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

/// 电脑端：微信式聊天界面。左侧设备列表，右侧聊天记录，输入框固定在底部。
struct LANTransferView: View {
    @EnvironmentObject private var model: LANModel

    @State private var textDraft = ""
    @State private var stagedFiles: [URL] = []
    @State private var isFileDropTarget = false
    @State private var pairing: PairingRequest?
    @State private var codeInput = ""
    @State private var pairingError: String?
    @State private var showClearConfirm = false
    @State private var aliasTarget: LANPeer?
    @State private var aliasDraft = ""
    @FocusState private var codeFocused: Bool
    @FocusState private var composerFocused: Bool

    private let sidebarWidth: CGFloat = 252

    private static let sidebarBackground = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor(calibratedWhite: 0.95, alpha: 1)
    })

    private var selectedPeer: LANPeer? {
        guard let id = model.selectedPeerID else { return nil }
        return model.peer(for: id)
    }

    private var selectedPeerPaired: Bool {
        guard let peer = selectedPeer else { return false }
        return model.isPaired(peer.id)
    }

    private var selectedMessages: [LANMessage] {
        model.messages(for: model.selectedPeerID)
    }

    private var selectedPeerDisplayName: String {
        guard let peer = selectedPeer else { return "对方" }
        return model.displayName(peer)
    }

    private var hasKnownDevices: Bool {
        !model.friends.isEmpty || !model.peers.isEmpty
    }

    private var peerSummary: String {
        if model.reconnecting { return "正在重新连接…" }
        if !hasKnownDevices { return "正在搜索局域网…" }
        let online = model.peers.filter { $0.online }.count
        if model.friends.isEmpty {
            return "发现 \(model.peers.count) 台设备 · \(online) 台在线"
        }
        return "已配对 \(model.friends.count) 台 · 在线 \(online) 台"
    }

    // MARK: - 主体

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            chatPane
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $pairing) { request in
            pairingSheet(request)
        }
        .sheet(item: $aliasTarget) { peer in
            aliasEditorSheet(peer)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                composerFocused = true
            }
        }
    }

    // MARK: - 左侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("文件互传助手")
                        .font(.headline)
                    Text("局域网直连 · 不经过服务器")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            HStack(spacing: 6) {
                if model.reconnecting || !hasKnownDevices {
                    ProgressView().controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 9, height: 9)
                } else {
                    Circle()
                        .fill(model.peers.contains(where: { $0.online }) ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                }
                Text(peerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    model.reconnectAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(model.busy)
                .help("重新搜索并连接附近的设备")
                .accessibilityLabel("重新连接设备")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            Divider().padding(.horizontal, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if model.friends.isEmpty, model.nearbyPeers.isEmpty {
                        emptyPeersHint
                    } else {
                        if !model.friends.isEmpty {
                            sectionTitle("已配对", count: model.friends.count)
                            ForEach(model.sortedFriends) { friend in
                                peerRow(model.peer(for: friend.id) ?? friend)
                            }
                        }
                        if !model.nearbyPeers.isEmpty {
                            sectionTitle("附近设备", count: model.nearbyPeers.count)
                            ForEach(model.nearbyPeers) { peer in
                                peerRow(peer)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)

            Divider().padding(.horizontal, 10)

            localDeviceCard
            statusStrip
        }
        .frame(width: sidebarWidth)
        .background(Self.sidebarBackground)
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var emptyPeersHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13))
                Text("等对方上线")
                    .font(.callout.weight(.medium))
            }
            .foregroundStyle(.secondary)
            Text("在另一台 Mac 的「电脑设备」页，或 Windows 电脑上打开「文件互传助手」，并连同一个 Wi-Fi / 局域网。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
    }

    private func peerRow(_ peer: LANPeer) -> some View {
        let selected = model.selectedPeerID == peer.id
        let paired = model.isPaired(peer.id)
        let display = model.displayName(peer)
        return HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07))
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(display)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .help(peer.alias == nil ? peer.name : "设备名：(peer.name)")
                HStack(spacing: 4) {
                    Circle()
                        .fill(peer.online ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                    Text(peer.online ? "在线" : "离线 · 正在重连")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(paired ? "· 已配对" : "· 未配对")
                        .font(.caption2)
                        .foregroundStyle(paired ? Color.green : Color.orange)
                }
            }

            Spacer(minLength: 0)

            if paired, !peer.online {
                Button("重连") { model.reconnect(to: peer) { _ in } }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .disabled(model.busy)
                    .help("重新连接「\(display)」")
            } else if !paired {
                Button("配对") { beginPairing(peer) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .disabled(model.busy || !peer.online)
                    .help(peer.online ? "输入对方屏幕上显示的 6 位配对码" : "设备离线，配对前需要先重新连接")
            }
        }
        .opacity(peer.online ? 1 : 0.72)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { model.selectPeer(peer.id) }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .contextMenu {
            Button("选中这台设备") { model.selectPeer(peer.id) }
            Button("重新连接这台设备") { model.reconnect(to: peer) { _ in } }
            if !paired {
                Button("配对…") { beginPairing(peer) }
            }
            if paired {
                Button("设置别名…") { beginAliasEdit(peer) }
                if !(peer.alias ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("清除别名") { model.setAlias("", for: peer.id) }
                }
                Button("取消与「\(display)」的配对") { model.forget(peer) }
            }
        }
    }

    // MARK: - 别名

    private func beginAliasEdit(_ peer: LANPeer) {
        aliasDraft = peer.alias ?? ""
        aliasTarget = peer
    }

    private func saveAlias(_ peer: LANPeer) {
        model.setAlias(aliasDraft, for: peer.id)
        aliasTarget = nil
    }

    private func aliasEditorSheet(_ peer: LANPeer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "tag")
                    .foregroundStyle(Color.accentColor)
                Text("设置别名")
                    .font(.headline)
            }
            Text("给「\(peer.name)」起一个本地别名，只有这台 Mac 会用它显示；留空保存等于清除别名。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(peer.name, text: $aliasDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveAlias(peer) }
            HStack {
                Button("清除别名") {
                    aliasDraft = ""
                    saveAlias(peer)
                }
                .disabled((peer.alias ?? "").isEmpty && aliasDraft.isEmpty)
                Spacer(minLength: 12)
                Button("取消") { aliasTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { saveAlias(peer) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var localDeviceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("本机")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if model.pairedCount > 0 {
                    Button("清除配对") { model.forgetPairs() }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
            }

            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("你的配对码")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(model.pairingCode.map(String.init).joined(separator: " "))
                        .font(.system(size: 19, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button {
                    copyPairingCode()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("复制配对码")
                Button {
                    model.regenerateCode()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("换一个配对码")
            }

            HStack(spacing: 5) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(model.receiveDir)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(model.receiveDir)
                Spacer(minLength: 2)
                Button {
                    model.chooseReceiveDir()
                } label: {
                    Text("修改").font(.caption2)
                }
                .buttonStyle(.borderless)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.receiveDir)])
                } label: {
                    Image(systemName: "folder").font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("在访达中打开接收目录")
            }

            if let name = model.pendingPairName {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("「\(name)」请求配对")
                            .font(.caption.weight(.medium))
                        Text("把本机配对码 \(model.pairingCode) 告诉对方")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 2)
                    Button("知道了") { model.clearPendingPair() }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.orange.opacity(0.10))
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusStrip: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: statusSymbol)
                .font(.caption2)
                .foregroundStyle(statusColor)
            Text(model.statusText)
                .font(.caption2)
                .foregroundStyle(model.statusKind == .failure ? Color.red : Color.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
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

    // MARK: - 右侧聊天区

    private var chatPane: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider()
            messageList
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .center) {
            if isFileDropTarget {
                dropOverlay
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isFileDropTarget) { providers in
            handleDrop(providers)
        }
        .alert("清空当前设备的聊天记录？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { model.clearMessages(for: model.selectedPeerID) }
        } message: {
            Text("只清空当前选中设备的会话，已经收到的文件不会被删除；其他设备的聊天记录不受影响。")
        }
    }

    private var chatHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                Image(systemName: selectedPeer == nil ? "arrow.left.arrow.right" : "desktopcomputer")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedPeer.map { model.displayName($0) } ?? "文件传输")
                    .font(.headline)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let peer = selectedPeer, !peer.online {
                Button {
                    model.reconnect(to: peer) { _ in }
                } label: {
                    Label("重连", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(model.busy)
                .help("重新连接「\(model.displayName(peer))」")
                .accessibilityLabel("重连当前设备")
            }

            if let peer = selectedPeer, !selectedPeerPaired {
                Button {
                    beginPairing(peer)
                } label: {
                    Label("配对…", systemImage: "key.horizontal")
                }
                .controlSize(.small)
                .disabled(model.busy)
                .help("输入对方屏幕上显示的 6 位配对码")
            }

            Menu {
                Button("重新搜索附近设备") { model.reconnectAll() }
                if let peer = selectedPeer, !peer.online {
                    Button("重新连接「\(model.displayName(peer))」") {
                        model.reconnect(to: peer) { _ in }
                    }
                }
                if let peer = selectedPeer, selectedPeerPaired {
                    Button("设置别名…") { beginAliasEdit(peer) }
                    if model.alias(for: peer.id) != nil {
                        Button("清除「\(model.displayName(peer))」的别名") {
                            model.setAlias("", for: peer.id)
                        }
                    }
                }
                Button("清除全部别名缓存") { model.clearAliases() }
                    .disabled(!model.hasAliases)
                Divider()
                Button("清空当前会话记录…") { showClearConfirm = true }
                    .disabled(selectedMessages.isEmpty)
                Divider()
                Button("修改接收目录…") { model.chooseReceiveDir() }
                Button("在访达中打开接收目录") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.receiveDir)])
                }
                Divider()
                Button("复制本机配对码") { copyPairingCode() }
                Button("换一个配对码") { model.regenerateCode() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
            .help("更多")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerSubtitle: String {
        guard let peer = selectedPeer else {
            return model.totalMessageCount == 0
                ? "在左侧选择设备，查看和它各自的聊天记录"
                : "共 \(model.totalMessageCount) 条记录 · 选择设备查看各自会话"
        }
        if !peer.online {
            return "离线 · 正在自动重连，也可以点右侧「重连」"
        }
        if selectedPeerPaired {
            return "在线 · 已配对，可直接发送文字和文件"
        }
        return "在线 · 未配对，首次发送需要输入对方配对码"
    }

    private var dropOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 30, weight: .light))
            Text("松开，把文件加入待发送列表")
                .font(.headline)
            Text("选好后再点「发送文件」")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, dash: [7, 5]))
        )
        .shadow(radius: 12, y: 4)
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if selectedMessages.isEmpty {
                    emptyChatHint
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(selectedMessages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
            .onChange(of: selectedMessages.count) { _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: model.selectedPeerID) { _ in
                scrollToBottom(proxy, animated: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = selectedMessages.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var emptyChatHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(selectedPeer == nil ? "还没有消息" : "还没有和「\(selectedPeerDisplayName)」的消息")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(selectedPeer == nil
                 ? "在左侧选择设备后，各自的聊天记录会显示在这里。"
                 : "收到的文字和文件会显示在这里，发出去的内容也会留在上面。\n切换到其他设备会看到它们各自的会话。")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 110)
        .padding(.horizontal, 24)
    }

    private func messageRow(_ message: LANMessage) -> some View {
        let outgoing = message.direction == .outgoing
        return HStack(alignment: .top, spacing: 8) {
            if outgoing {
                Spacer(minLength: 30)
            } else {
                bubbleAvatar(systemName: "desktopcomputer", outgoing: false,
                             peerName: selectedPeerDisplayName)
            }

            VStack(alignment: outgoing ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if outgoing {
                        Text(message.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("我 → \(selectedPeerDisplayName)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(selectedPeerDisplayName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(message.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if message.kind == .text {
                            Button {
                                model.copyText(message)
                            } label: {
                                Image(systemName: "doc.on.doc").font(.caption2)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tertiary)
                            .help("复制这段文字")
                        }
                    }
                    if outgoing && message.kind == .text {
                        Button {
                            model.copyText(message)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                        .help("复制这段文字")
                    }
                }
                bubble(for: message)
            }

            if outgoing {
                bubbleAvatar(systemName: "person.fill", outgoing: true, peerName: nil)
            } else {
                Spacer(minLength: 30)
            }
        }
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
        .contextMenu { messageContextMenu(message) }
    }

    @ViewBuilder
    private func messageContextMenu(_ message: LANMessage) -> some View {
        let missing = model.fileMissing(message)
        if message.kind == .text {
            Button("复制文字") { model.copyText(message) }
        } else {
            Button("查看") { model.previewFile(message) }
                .disabled(missing)
            Button(missing ? "打开接收目录" : "打开文件位置") {
                model.openFileLocation(message)
            }
        }
    }

    private func bubbleAvatar(systemName: String, outgoing: Bool, peerName: String?) -> some View {
        ZStack {
            Circle()
                .fill(outgoing ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08))
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(outgoing ? Color.accentColor : Color.secondary)
        }
        .frame(width: 30, height: 30)
        .help(peerName ?? "我")
    }

    @ViewBuilder
    private func bubble(for message: LANMessage) -> some View {
        let outgoing = message.direction == .outgoing
        let fill = outgoing
            ? Color.accentColor.opacity(0.15)
            : Color.primary.opacity(0.055)
        let radius: CGFloat = 11
        let missing = message.kind == .file ? model.fileMissing(message) : false

        if message.kind == .text {
            Text(message.text ?? "")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
                )
                .contextMenu { messageContextMenu(message) }
        } else {
            HStack(spacing: 9) {
                Image(systemName: missing ? "doc.badge.xmark" : "doc.fill")
                    .font(.title3)
                    .foregroundStyle(missing ? Color.secondary : (outgoing ? Color.accentColor : Color.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.fileName ?? "文件")
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .strikethrough(missing)
                        .foregroundStyle(missing ? Color.secondary : Color.primary)
                    HStack(spacing: 6) {
                        if let size = message.fileSize, size > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        }
                        Text(missing ? "文件已不存在" : (outgoing ? "已发送" : "已保存"))
                    }
                    .font(.caption2)
                    .foregroundStyle(missing ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 4)
                Button(missing ? "打开目录" : (outgoing ? "打开" : "显示")) {
                    if missing {
                        model.openFileLocation(message)
                    } else {
                        model.revealFile(message)
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help(missing ? "文件已不存在，打开接收目录" : (message.filePath ?? ""))
            }
            .frame(maxWidth: 360, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
            )
        }
    }

    // MARK: - 底部输入区

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.busy {
                HStack(spacing: 8) {
                    if model.sendProgress > 0 {
                        ProgressView(value: model.sendProgress)
                            .controlSize(.small)
                        Text("\(Int(model.sendProgress * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("正在发送 \(model.activeSendLabel)…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if model.canCancelSend {
                        Button {
                            model.cancelSend()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("取消发送")
                        .accessibilityLabel("取消发送")
                    }
                }
                .padding(.horizontal, 2)
            }

            if !stagedFiles.isEmpty {
                stagedFileBar
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    chooseFiles()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(selectedPeer == nil || model.busy ? Color.secondary : Color.primary)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .help("选择要发送的文件")
                .disabled(selectedPeer == nil || model.busy)

                TextField(composerPlaceholder, text: $textDraft)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07))
                    )
                    .focused($composerFocused)
                    .onSubmit { sendText() }
                    .disabled(selectedPeer == nil)

                Button {
                    sendText()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canSendText ? Color.white : Color.secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle().fill(canSendText ? Color.accentColor : Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSendText)
                .help("发送文字（Enter）")
            }

            HStack(spacing: 5) {
                Text(targetHint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("Enter 发送 · 可拖拽文件")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var composerPlaceholder: String {
        guard let peer = selectedPeer else { return "先在左侧选择设备" }
        return "发送给 \(model.displayName(peer))…"
    }

    private var canSendText: Bool {
        selectedPeer != nil
            && !model.busy
            && !textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var targetHint: String {
        guard let peer = selectedPeer else {
            return "未选择设备"
        }
        if selectedPeerPaired {
            return "发给 \(model.displayName(peer)) · 已配对"
        }
        return "发给 \(model.displayName(peer)) · 首次发送需输入对方配对码"
    }

    private var stagedFileBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(stagedFiles, id: \.self) { url in
                        stagedFileChip(url)
                    }
                }
                .padding(.vertical, 1)
            }

            HStack(spacing: 8) {
                Text(stagedFiles.count == 1 ? "1 个文件待发送" : "\(stagedFiles.count) 个文件待发送")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("清空") { stagedFiles.removeAll() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .disabled(model.busy)
                Button {
                    sendStagedFiles()
                } label: {
                    Label(stagedFiles.count == 1 ? "发送文件" : "发送 \(stagedFiles.count) 个文件",
                          systemImage: "paperplane.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.busy || selectedPeer == nil)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private func stagedFileChip(_ url: URL) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
            Text(fileSizeText(url))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                removeStaged([url])
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("从待发送列表移除")
            .disabled(model.busy)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.055))
        )
    }

    private func fileSizeText(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
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
            model.statusText = "先在左侧选中对方设备"
            return
        }
        let value = textDraft
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
            model.statusText = "先在左侧选中对方设备"
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

    private func copyPairingCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.pairingCode, forType: .string)
        model.statusKind = .success
        model.statusText = "已复制本机配对码 \(model.pairingCode)"
    }

    private func chooseFiles() {
        guard !model.busy, selectedPeer != nil else { return }
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
        guard !model.busy, selectedPeer != nil else { return false }
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

    // MARK: - 配对面板

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
        .frame(width: 430)
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
            return "在对方电脑的「文件互传助手」→「电脑设备」页左侧，可以看到 6 位配对码。输入一次后两台设备会互相信任，以后直接发送；也可以直接粘贴。"
        case .text, .files:
            return "这是第一次和「\(request.peerName)」互传。在对方电脑的「电脑设备」页左侧找到 6 位配对码，输入后会把这次内容发过去，并记住对方。"
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
}
