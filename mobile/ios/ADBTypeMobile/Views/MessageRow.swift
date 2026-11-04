import SwiftUI

/// 一条消息：左收右发气泡 + 时间。
/// 图片 / 视频显示固定尺寸缩略图（点击全屏查看 / 播放），其他文件保持文件卡片。
struct MessageRow: View {
    @ObservedObject var model: LANModel
    let message: LANMessage
    let onOpenFile: (URL) -> Void
    let onOpenMedia: (URL, MediaKind) -> Void

    private var outgoing: Bool { message.direction == .outgoing }
    private var fileURL: URL? { model.resolvedFileURL(for: message) }
    private var mediaKind: MediaKind? {
        guard message.kind == .file, let fileURL else { return nil }
        return MediaKind(url: fileURL)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if outgoing {
                Spacer(minLength: 48)
            }

            VStack(alignment: outgoing ? .trailing : .leading, spacing: 3) {
                content
                Text(Formatting.bubbleTime(message.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            if !outgoing {
                Spacer(minLength: 48)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .text:
            textBubble
        case .file:
            if let mediaKind, let fileURL {
                mediaBubble(url: fileURL, kind: mediaKind)
            } else {
                fileBubble
            }
        }
    }

    private var textBubble: some View {
        Text(message.text ?? "")
            .font(.body)
            .foregroundStyle(outgoing ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(outgoing ? Color.accentColor : Color(.secondarySystemBackground))
            )
            .textSelection(.enabled)
            .contextMenu {
                Button {
                    model.copyText(message.text ?? "")
                } label: {
                    Label("复制文字", systemImage: "doc.on.doc")
                }
            }
    }

    private func mediaBubble(url: URL, kind: MediaKind) -> some View {
        VStack(alignment: outgoing ? .trailing : .leading, spacing: 3) {
            MediaThumbnailView(url: url,
                               kind: kind,
                               accessibilityText: "\(kind.accessibilityPrefix)：\(message.fileName ?? "")") { tapped in
                onOpenMedia(tapped, kind)
            }
            .contextMenu {
                Button {
                    onOpenMedia(url, kind)
                } label: {
                    Label(kind == .video ? "播放视频" : "查看大图",
                          systemImage: kind == .video ? "play.rectangle" : "arrow.up.left.and.arrow.down.right")
                }
                ShareLink(item: url) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            }

            Text(message.fileName ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: ThumbnailCache.displaySize.width,
                       alignment: outgoing ? .trailing : .leading)
        }
    }

    private var fileBubble: some View {
        Button {
            if !outgoing, let fileURL {
                onOpenFile(fileURL)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(message.fileName ?? "文件")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Text(Formatting.fileSize(message.fileSize))
                        Text("·")
                        Text(fileStatusText)
                    }
                    .font(.caption2)
                    .opacity(0.85)
                }

                if !outgoing, fileURL != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .opacity(0.6)
                }
            }
            .foregroundStyle(outgoing ? Color.white : Color.primary)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(outgoing ? Color.accentColor : Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if outgoing {
                Button {
                    model.copyText(message.fileName ?? "")
                } label: {
                    Label("复制文件名", systemImage: "doc.on.doc")
                }
            } else if let fileURL {
                Button {
                    onOpenFile(fileURL)
                } label: {
                    Label("打开", systemImage: "doc.text.magnifyingglass")
                }
                ShareLink(item: fileURL) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            } else {
                Button("文件已不存在") {}
                    .disabled(true)
            }
        }
    }

    private var fileStatusText: String {
        if outgoing { return "已发送" }
        return fileURL == nil ? "文件已不存在" : "已保存"
    }
}
