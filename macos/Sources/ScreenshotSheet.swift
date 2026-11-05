import SwiftUI
import AppKit

/// 手机截屏弹窗：预览、刷新、保存、选择保存目录。
struct ScreenshotSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            preview
            Divider()
            footer
        }
        .frame(width: 900, height: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("手机截屏", systemImage: "camera")
                .font(.headline)
            if let date = model.screenshotAt {
                Text(date.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.captureScreenshot()
            } label: {
                Label("刷新截屏", systemImage: "arrow.clockwise")
            }
            .disabled(model.devices.isEmpty || model.screenshotBusy)
            .help("重新截取手机当前屏幕")

            Button {
                model.saveScreenshot()
            } label: {
                Label("保存截屏", systemImage: "square.and.arrow.down")
            }
            .disabled(model.screenshotData == nil)
            .help("保存到下方目录")

            Button {
                model.chooseScreenshotDirectory()
            } label: {
                Label("保存位置…", systemImage: "folder")
            }
            .help("选择截屏保存目录")

            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var preview: some View {
        ZStack {
            Color.black
            if let image = model.screenshotImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(12)
                if model.screenshotBusy {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("正在刷新截屏…")
                            .font(.caption)
                            .foregroundStyle(.white)
                    }
                    .padding(16)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                }
            } else if model.screenshotBusy {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在截取手机屏幕…")
                        .font(.callout)
                        .foregroundStyle(.white)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(model.screenshotError ?? "还没有截屏")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text("保存到：\(model.screenshotSaveDir)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.screenshotSaveDir)
                Spacer()
                if model.screenshotSavedURL != nil {
                    Button("在访达中显示") { model.revealSavedScreenshot() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if let error = model.screenshotError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if model.screenshotSavedURL == nil {
                Text("默认保存到系统「下载」；可点「保存位置…」修改。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
