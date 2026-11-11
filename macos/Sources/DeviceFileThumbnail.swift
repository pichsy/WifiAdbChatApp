import SwiftUI
import AppKit
import AVFoundation
import ImageIO

/// 网格模式下的图片 / GIF / 视频缩略图。
/// 文件先拉到临时目录，再用 ImageIO / AVFoundation 生成小图；内存和磁盘都做缓存。
struct DeviceThumbnailView: View {
    let entry: DeviceFileEntry
    let adbPath: String
    let serial: String

    @State private var image: NSImage?
    @State private var requested = false
    @State private var failed = false

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff",
        "heic", "heif", "avif", "ico"
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "3gp", "3g2", "mkv", "avi", "webm",
        "flv", "wmv", "ts", "m2ts"
    ]

    static func supports(_ entry: DeviceFileEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if requested && !failed {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: failed ? "photo" : entry.iconName)
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)
        .onAppear(perform: load)
    }

    private func load() {
        guard !requested else { return }
        requested = true
        DeviceThumbnailStore.shared.thumbnail(adbPath: adbPath, serial: serial, entry: entry) { result in
            DispatchQueue.main.async {
                image = result
                failed = result == nil
            }
        }
    }
}

final class DeviceThumbnailStore {
    static let shared = DeviceThumbnailStore()

    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let lock = NSLock()
    private var inFlight: [String: [(NSImage?) -> Void]] = [:]

    private var cacheDirectory: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WifiAdbChatAppThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func thumbnail(adbPath: String,
                   serial: String,
                   entry: DeviceFileEntry,
                   completion: @escaping (NSImage?) -> Void) {
        let key = Self.cacheKey(serial: serial, path: entry.path)
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return
        }

        lock.lock()
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[key] = [completion]
        lock.unlock()

        let remotePath = entry.path
        let name = entry.name
        queue.addOperation { [weak self] in
            guard let self else { return }
            let image = self.loadImage(adbPath: adbPath,
                                       serial: serial,
                                       remotePath: remotePath,
                                       name: name,
                                       key: key)
            if let image {
                self.cache.setObject(image, forKey: key as NSString)
            }

            self.lock.lock()
            let waiters = self.inFlight.removeValue(forKey: key) ?? []
            self.lock.unlock()
            DispatchQueue.main.async {
                waiters.forEach { $0(image) }
            }
        }
    }

    private func loadImage(adbPath: String,
                           serial: String,
                           remotePath: String,
                           name: String,
                           key: String) -> NSImage? {
        let ext = (name as NSString).pathExtension.lowercased()
        let fileURL = cacheDirectory.appendingPathComponent(key + "." + (ext.isEmpty ? "dat" : ext))

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let isVideo = Self.videoExtensions.contains(ext)
            let timeout: TimeInterval = isVideo ? 300 : 90
            let result = ADB.pull(adb: adbPath,
                                  serial: serial,
                                  remotePath: remotePath,
                                  localPath: fileURL.path,
                                  timeout: timeout)
            guard result.ok else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
        }

        if Self.imageExtensions.contains(ext) {
            return imageFromImageFile(fileURL)
        }
        return imageFromVideoFile(fileURL)
    }

    private func imageFromImageFile(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func imageFromVideoFile(_ url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 240)

        let times = [CMTime(seconds: 0.1, preferredTimescale: 600),
                     CMTime(seconds: 0, preferredTimescale: 600)]
        for time in times {
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }
        return nil
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff",
        "heic", "heif", "avif", "ico"
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "3gp", "3g2", "mkv", "avi", "webm",
        "flv", "wmv", "ts", "m2ts"
    ]

    private static func cacheKey(serial: String, path: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in (serial + "|" + path).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(hash, radix: 16)
    }
}
