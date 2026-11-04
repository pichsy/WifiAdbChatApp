import Foundation
import UIKit
import ImageIO
import AVFoundation

/// 消息里可预览的媒体类型。
enum MediaKind: Equatable {
    case image
    case video

    init?(url: URL) {
        if PhotoLibrarySaver.isImage(url) {
            self = .image
        } else if PhotoLibrarySaver.isVideo(url) {
            self = .video
        } else {
            return nil
        }
    }

    var accessibilityPrefix: String {
        switch self {
        case .image: return "图片消息"
        case .video: return "视频消息"
        }
    }
}

/// 图片 / 视频缩略图缓存。
/// - 图片：ImageIO（CGImageSource）按最大 360 px 生成，避免解码整张图；
/// - 视频：AVAssetImageGenerator 取首帧（失败再取 0.2 秒处）；
/// - 内存 NSCache 缓存，生成全部在后台队列 / async，不阻塞主线程。
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// 气泡里固定展示的缩略图尺寸。
    static let displaySize = CGSize(width: 120, height: 90)
    /// 生成的缩略图最大像素（@3x 约 120pt）。
    static let maxPixelSize: CGFloat = 360

    private let cache = NSCache<NSString, UIImage>()
    private static let generationQueue = DispatchQueue(label: "dev.local.adbtype.mobile.thumbnail",
                                                       qos: .userInitiated,
                                                       attributes: .concurrent)

    private init() {
        cache.countLimit = 240
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cachedThumbnail(for url: URL) -> UIImage? {
        cache.object(forKey: Self.cacheKey(for: url))
    }

    func thumbnail(for url: URL) async -> UIImage? {
        let key = Self.cacheKey(for: url)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image: UIImage?
        switch MediaKind(url: url) {
        case .image:
            image = await imageThumbnail(for: url)
        case .video:
            image = await videoThumbnail(for: url)
        case nil:
            image = nil
        }
        if let image {
            cache.setObject(image, forKey: key, cost: Self.cost(of: image))
        }
        return image
    }

    /// 测试 / 内存警告时可清空。
    func removeAll() {
        cache.removeAllObjects()
    }

    // MARK: - 图片

    private func imageThumbnail(for url: URL) async -> UIImage? {
        await withCheckedContinuation { continuation in
            Self.generationQueue.async {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(Self.maxPixelSize)
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: UIImage(cgImage: cgImage))
            }
        }
    }

    // MARK: - 视频

    private func videoThumbnail(for url: URL) async -> UIImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Self.maxPixelSize, height: Self.maxPixelSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        if let result = try? await generator.image(at: .zero) {
            return UIImage(cgImage: result.image)
        }
        // 有些视频首帧是纯黑，退到 0.2 秒再看一次。
        let fallback = CMTime(seconds: 0.2, preferredTimescale: 600)
        if let result = try? await generator.image(at: fallback) {
            return UIImage(cgImage: result.image)
        }
        return nil
    }

    // MARK: - 工具

    private static func cacheKey(for url: URL) -> NSString {
        url.standardizedFileURL.path as NSString
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
}

/// 全屏查看时按最大边 4096 px 解码，避免超大照片占用过多内存。
enum FullImageLoader {
    static func load(_ url: URL, maxPixelSize: CGFloat = 4096) -> UIImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: cgImage)
            }
        }
        return UIImage(contentsOfFile: url.path)
    }
}
