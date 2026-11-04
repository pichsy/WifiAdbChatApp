import Foundation
import Photos
import UniformTypeIdentifiers

/// 收到的图片 / 视频额外存一份到系统相册。
/// 仅在用户授权「仅添加照片」后执行；任何失败都不影响 Documents/Downloads 里的文件。
enum PhotoLibrarySaver {
    enum Outcome: Equatable {
        /// 不是图片 / 视频，不需要保存
        case notMedia
        case saved
        /// 用户拒绝相册权限（或权限受限）
        case denied
        case failed
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie)
    }

    static func isMediaFile(_ url: URL) -> Bool {
        isImage(url) || isVideo(url)
    }

    /// 异步保存到系统相册；completion 可能在任意队列回调。
    static func saveToPhotoLibrary(_ url: URL, completion: @escaping (Outcome) -> Void = { _ in }) {
        let image = isImage(url)
        let video = isVideo(url)
        guard image || video else {
            completion(.notMedia)
            return
        }

        let handleStatus: (PHAuthorizationStatus) -> Void = { status in
            switch status {
            case .authorized, .limited:
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = url.lastPathComponent
                    request.addResource(with: image ? .photo : .video, fileURL: url, options: options)
                } completionHandler: { success, _ in
                    completion(success ? .saved : .failed)
                }
            case .denied, .restricted:
                completion(.denied)
            case .notDetermined:
                completion(.failed)
            @unknown default:
                completion(.failed)
            }
        }

        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                handleStatus(status)
            }
        } else {
            handleStatus(current)
        }
    }
}
