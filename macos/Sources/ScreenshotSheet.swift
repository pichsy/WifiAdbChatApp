import SwiftUI
import AppKit

/// 手机截屏弹窗：预览、刷新、保存、选择保存目录。
struct ScreenshotSheet: View {
    @ObservedObject var model: AppModel
    var onClose: () -> Void = {}
    @State private var toastMessage: String?
    @State private var toastDismissWork: DispatchWorkItem?

    @State private var zoomScale: CGFloat = 1
    @State private var pinchBase: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragBase: CGSize = .zero
    @State private var previewSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            preview
            Divider()
            footer
        }
        .frame(minWidth: 780, minHeight: 500)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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
                .padding(.bottom, 58)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: toastMessage)
    }

    private func showSavedToast() {
        toastDismissWork?.cancel()
        toastMessage = "截屏已保存"
        let work = DispatchWorkItem {
            toastMessage = nil
        }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
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

            VStack(spacing: 1) {
                Text("\(Int(zoomScale * 100))%")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("1:1") { resetZoom() }
                    .disabled(model.screenshotImage == nil)
                    .help("恢复适应窗口大小")
            }

            Button {
                model.saveScreenshot()
                if model.screenshotError == nil, model.screenshotSavedURL != nil {
                    showSavedToast()
                }
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

            Button("关闭") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image = model.screenshotImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(12)
                        .scaleEffect(zoomScale)
                        .offset(offset)
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
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(previewGesture)
            .onTapGesture(count: 2) {
                if zoomScale > 1.01 {
                    resetZoom()
                } else {
                    zoomTo(2.5)
                }
            }
            .onAppear { previewSize = geo.size }
            .onChange(of: geo.size) { newSize in
                previewSize = newSize
                clampOffset()
            }
            .onChange(of: model.screenshotAt) { _ in
                resetZoom()
            }
        }
    }

    private var previewGesture: some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    guard model.screenshotImage != nil else { return }
                    zoomScale = min(max(pinchBase * value, 1), 5)
                    clampOffset()
                }
                .onEnded { _ in
                    pinchBase = zoomScale
                    if zoomScale <= 1.01 {
                        resetZoom()
                    } else {
                        clampOffset()
                    }
                },
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard zoomScale > 1.01 else { return }
                    offset = CGSize(width: dragBase.width + value.translation.width,
                                    height: dragBase.height + value.translation.height)
                    clampOffset()
                }
                .onEnded { _ in dragBase = offset }
        )
    }

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomScale = 1
            pinchBase = 1
            offset = .zero
            dragBase = .zero
        }
    }

    private func zoomTo(_ scale: CGFloat) {
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomScale = scale
            pinchBase = scale
            clampOffset()
        }
    }

    private func clampOffset() {
        guard zoomScale > 1.001 else {
            offset = .zero
            dragBase = .zero
            return
        }
        let fitted = fittedImageSize()
        let maxX = max(0, (fitted.width * zoomScale - previewSize.width) / 2)
        let maxY = max(0, (fitted.height * zoomScale - previewSize.height) / 2)
        offset.width = min(max(offset.width, -maxX), maxX)
        offset.height = min(max(offset.height, -maxY), maxY)
        dragBase = offset
    }

    private func fittedImageSize() -> CGSize {
        guard let image = model.screenshotImage,
              image.size.width > 0, image.size.height > 0 else {
            return previewSize
        }
        let availableWidth = max(previewSize.width - 24, 1)
        let availableHeight = max(previewSize.height - 24, 1)
        let ratio = min(availableWidth / image.size.width, availableHeight / image.size.height)
        return CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
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
