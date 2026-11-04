import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 与一台电脑的聊天窗口：消息列表 + 连接状态 + 底部输入框 / 附件 / 发送。
struct ChatView: View {
    @ObservedObject var model: LANModel
    let initialPeer: LANPeer

    @State private var draft = ""
    @State private var stagedFiles: [URL] = []
    @State private var showFileImporter = false
    @State private var previewItem: FilePreviewItem?
    @State private var mediaViewer: MediaViewerItem?
    @State private var showClearConfirm = false
    @State private var showUnpairConfirm = false
    @State private var alertMessage = ""
    @State private var showAlert = false

    private var peer: LANPeer { model.peer(for: initialPeer.id) ?? initialPeer }
    private var peerID: String { initialPeer.id }
    private var messages: [LANMessage] { model.messages(for: peerID) }
    private var paired: Bool { model.isPaired(peerID) }
    private var online: Bool { model.isOnline(peerID) }
    private var canSend: Bool { peer.hasAddress && !model.busy }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        messageList
            .background(Color(.systemGroupedBackground))
            .navigationTitle(peer.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { chatHeader }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .toolbar { toolbarContent }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    let files = urls.filter { !$0.hasDirectoryPath }
                    if files.isEmpty {
                        showAlertMessage("这里只能发送文件，暂不支持整个文件夹。")
                    } else {
                        stagedFiles = files
                    }
                case .failure(let error):
                    showAlertMessage("选择文件失败：\(error.localizedDescription)")
                }
            }
            .sheet(item: $previewItem) { item in
                QuickLookPreview(url: item.url)
                    .ignoresSafeArea()
            }
            .fullScreenCover(item: $mediaViewer) { item in
                switch item.kind {
                case .image:
                    ImageViewerScreen(url: item.url)
                case .video:
                    VideoPlayerScreen(url: item.url)
                }
            }
            .confirmationDialog("清空与「\(peer.displayName)」的聊天记录？",
                                isPresented: $showClearConfirm,
                                titleVisibility: .visible) {
                Button("清空聊天记录", role: .destructive) {
                    model.clearMessages(for: peerID)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只清空这台电脑的会话，已经收到的文件不会被删除。")
            }
            .confirmationDialog("取消与「\(peer.displayName)」的配对？",
                                isPresented: $showUnpairConfirm,
                                titleVisibility: .visible) {
                Button("取消配对", role: .destructive) {
                    model.unpair(peerID)
                }
                Button("再想想", role: .cancel) {}
            } message: {
                Text("取消后，下次发送需要重新输入配对码。聊天记录会保留。")
            }
            .alert("提示", isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if model.pendingPairPeerID == peerID, let pendingName = model.pendingPairName {
                        incomingPairCallout(pendingName)
                    } else if !paired {
                        pairingCallout
                    }

                    if messages.isEmpty {
                        emptyState
                    }

                    ForEach(messages) { message in
                        MessageRow(model: model,
                                   message: message,
                                   onOpenFile: { url in
                                       previewItem = FilePreviewItem(url: url)
                                   },
                                   onOpenMedia: { url, kind in
                                       mediaViewer = MediaViewerItem(url: url, kind: kind)
                                   })
                        .id(message.id)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("还没有消息")
                .font(.headline)
            Text(paired
                 ? "收到的文字和文件会像聊天一样显示在这里，发出去的内容也会留在上面。"
                 : "首次发送需要输入对方屏幕上显示的 6 位配对码，配对成功后就能互发文字和文件。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 36)
    }

    // MARK: - 配对提示

    private var pairingCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("和「\(peer.displayName)」还没配对", systemImage: "number.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("点「输入配对码」，输入对方电脑屏幕上显示的 6 位数字；配对一次以后直接发送即可。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("输入配对码") {
                model.beginPairing(with: peer)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.orange.opacity(0.12)))
    }

    private func incomingPairCallout(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("「\(name)」正在请求配对", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            HStack(spacing: 8) {
                Text("本机配对码")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.pairingCode)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .tracking(2)
                Spacer()
                Button("复制") {
                    model.copyPairingCode()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
            Text("把本机配对码告诉对方；或者输入对方屏幕上显示的配对码，点下面按钮配对。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("输入对方配对码") {
                model.beginPairing(with: peer)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.orange.opacity(0.12)))
    }

    // MARK: - 头部

    private var chatHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(online ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(headerStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if !online, peer.hasAddress {
                Button("重连") {
                    model.ping(peer: peer)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
            if !paired {
                Button("配对") {
                    model.beginPairing(with: peer)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var headerStatus: String {
        if online {
            return paired ? "在线 · 已配对" : "在线 · 未配对"
        }
        if peer.hasAddress {
            return paired
                ? "离线 · 上次 \(Formatting.relativeTime(peer.lastSeen))"
                : "离线"
        }
        return "离线"
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(spacing: 0) {
            if model.statusKind == .failure, !model.statusText.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(model.statusText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(.red)
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }

            if model.busy {
                progressBar
            }

            if !stagedFiles.isEmpty {
                stagedFileBar
            }

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    showFileImporter = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .disabled(!canSend)
                .accessibilityLabel("选择文件")

                TextField(inputPlaceholder, text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.secondarySystemBackground)))
                    .disabled(!canSend)
                    .submitLabel(.send)

                Button {
                    sendText()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend && !trimmedDraft.isEmpty
                                         ? Color.accentColor
                                         : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.borderless)
                .disabled(!canSend || trimmedDraft.isEmpty)
                .accessibilityLabel("发送文字")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var inputPlaceholder: String {
        if model.busy { return "正在发送…" }
        if !canSend { return "「\(peer.displayName)」当前离线，等它上线后再发送" }
        if !paired { return "发消息给 \(peer.displayName)（首次需要配对）" }
        return "发消息给 \(peer.displayName)…"
    }

    private var progressBar: some View {
        VStack(spacing: 4) {
            ProgressView(value: model.sendProgress)
            HStack(spacing: 6) {
                Text(model.sendProgress > 0
                     ? "正在发送 \(model.activeSendLabel)…"
                     : "正在发送…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(model.sendProgress * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var stagedFileBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(stagedFiles, id: \.self) { url in
                        HStack(spacing: 4) {
                            Image(systemName: "doc")
                                .font(.caption)
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .lineLimit(1)
                            Button {
                                stagedFiles.removeAll { $0 == url }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
                .padding(.horizontal, 14)
            }

            HStack(spacing: 10) {
                Button {
                    sendStagedFiles()
                } label: {
                    Label("发送 \(stagedFiles.count) 个文件", systemImage: "paperplane.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canSend)

                Button("清除") {
                    stagedFiles = []
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Spacer()

                if !canSend {
                    Text("等电脑上线后再发送")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    model.copyPairingCode()
                } label: {
                    Label("复制本机配对码", systemImage: "doc.on.doc")
                }

                if !paired {
                    Button {
                        model.beginPairing(with: peer)
                    } label: {
                        Label("配对…", systemImage: "number")
                    }
                }

                if peer.hasAddress {
                    Button {
                        model.ping(peer: peer)
                    } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                }

                Button {
                    showClearConfirm = true
                } label: {
                    Label("清空聊天记录", systemImage: "trash")
                }

                if paired {
                    Button(role: .destructive) {
                        showUnpairConfirm = true
                    } label: {
                        Label("取消配对", systemImage: "link.badge.plus")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("更多操作")
        }
    }

    // MARK: - 动作

    private func sendText() {
        guard canSend else { return }
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        model.sendText(text, to: peer)
    }

    private func sendStagedFiles() {
        guard canSend, !stagedFiles.isEmpty else { return }
        let files = stagedFiles
        stagedFiles = []
        model.sendFiles(files, to: peer)
    }

    private func showAlertMessage(_ text: String) {
        alertMessage = text
        showAlert = true
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

/// 全屏媒体查看的目标（图片 / 视频）。
struct MediaViewerItem: Identifiable {
    let id = UUID()
    let url: URL
    let kind: MediaKind
}
