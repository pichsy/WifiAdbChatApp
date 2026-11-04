import SwiftUI
import UIKit

/// 全屏图片查看：双指缩放 / 双击放大缩小 / 右上角关闭。
struct ImageViewerScreen: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                ZoomableImageView(image: image)
                    .ignoresSafeArea()
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 40))
                    Text("图片无法加载")
                        .font(.callout)
                }
                .foregroundStyle(.white.opacity(0.8))
            } else {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .accessibilityLabel("关闭")
                    .accessibilityIdentifier("image-viewer-close")
                }
                .padding(16)
                Spacer()
            }
        }
        .statusBarHidden(true)
        .task {
            let loaded = await Task.detached(priority: .userInitiated) {
                FullImageLoader.load(url)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}

/// UIScrollView 实现的可缩放图片视图（支持捏合与双击）。
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        ZoomableImageScrollView(image: image)
    }

    func updateUIView(_ scrollView: ZoomableImageScrollView, context: Context) {
        scrollView.setImage(image)
    }
}

final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var lastBoundsSize = CGSize.zero

    init(image: UIImage) {
        super.init(frame: .zero)
        backgroundColor = .black
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bouncesZoom = true
        delegate = self
        imageView.contentMode = .scaleAspectFit
        imageView.image = image
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: UIImage) {
        imageView.image = image
        contentSize = image.size
        lastBoundsSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != .zero else { return }
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            configureZoom()
        }
    }

    private func configureZoom() {
        guard let image = imageView.image else { return }
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size

        let widthScale = bounds.width / image.size.width
        let heightScale = bounds.height / image.size.height
        minimumZoomScale = min(widthScale, heightScale)
        maximumZoomScale = max(minimumZoomScale * 4, 3)
        zoomScale = minimumZoomScale
        updateCentering()
    }

    private func updateCentering() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateCentering()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let targetScale = min(maximumZoomScale, max(minimumZoomScale * 2.5, minimumZoomScale + 0.5))
        let point = recognizer.location(in: imageView)
        let width = bounds.width / targetScale
        let height = bounds.height / targetScale
        zoom(to: CGRect(x: point.x - width / 2,
                        y: point.y - height / 2,
                        width: width,
                        height: height),
             animated: true)
    }
}
