import SwiftUI

/// 图片 / 视频消息气泡里的固定尺寸缩略图（120 × 90pt）。
/// 视频叠加播放图标；加载失败显示占位；文件不存在时显示提示且不可点。
struct MediaThumbnailView: View {
    let url: URL?
    let kind: MediaKind
    let accessibilityText: String
    let onTap: (URL) -> Void

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Button {
            if let url {
                onTap(url)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if failed || url == nil {
                    VStack(spacing: 4) {
                        Image(systemName: url == nil
                              ? "exclamationmark.triangle"
                              : (kind == .video ? "video" : "photo"))
                            .font(.title3)
                        Text(url == nil ? "文件已不存在" : "无法预览")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }

                if kind == .video {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 34, height: 34)
                        Image(systemName: "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 1)
                    }
                }
            }
            .frame(width: ThumbnailCache.displaySize.width,
                   height: ThumbnailCache.displaySize.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("media-thumbnail")
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else {
            image = nil
            failed = true
            return
        }
        if let cached = ThumbnailCache.shared.cachedThumbnail(for: url) {
            image = cached
            failed = false
            return
        }
        image = nil
        failed = false
        let thumbnail = await ThumbnailCache.shared.thumbnail(for: url)
        guard !Task.isCancelled else { return }
        image = thumbnail
        failed = thumbnail == nil
    }
}
