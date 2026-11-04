import XCTest
import UIKit
@testable import ADBTypeMobile

final class ThumbnailCacheTests: XCTestCase {
    func testMediaKindClassification() {
        XCTAssertEqual(MediaKind(url: URL(fileURLWithPath: "/tmp/a.jpg")), .image)
        XCTAssertEqual(MediaKind(url: URL(fileURLWithPath: "/tmp/a.PNG")), .image)
        XCTAssertEqual(MediaKind(url: URL(fileURLWithPath: "/tmp/a.heic")), .image)
        XCTAssertEqual(MediaKind(url: URL(fileURLWithPath: "/tmp/a.mp4")), .video)
        XCTAssertEqual(MediaKind(url: URL(fileURLWithPath: "/tmp/a.MOV")), .video)
        XCTAssertNil(MediaKind(url: URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertNil(MediaKind(url: URL(fileURLWithPath: "/tmp/a.pdf")))
    }

    func testGeneratesAndCachesImageThumbnail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTypeMobileThumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("sample.png")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            UIColor.systemYellow.setFill()
            context.fill(CGRect(x: 400, y: 250, width: 400, height: 300))
        }
        let pngData = try XCTUnwrap(image.pngData())
        try pngData.write(to: url)

        let first = await ThumbnailCache.shared.thumbnail(for: url)
        let thumbnail = try XCTUnwrap(first, "应能从图片生成缩略图")
        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), 360)
        XCTAssertGreaterThan(thumbnail.size.width, 0)
        XCTAssertEqual(thumbnail.size.width / thumbnail.size.height, 1.5, accuracy: 0.02)

        let second = await ThumbnailCache.shared.thumbnail(for: url)
        XCTAssertTrue(thumbnail === second, "第二次应命中 NSCache 并返回同一 UIImage 实例")
    }

    func testVideoThumbnailFromFixture() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "mp4"),
                                "测试资源 sample.mp4 应打包进测试 Bundle")
        let thumbnail = await ThumbnailCache.shared.thumbnail(for: url)
        XCTAssertNotNil(thumbnail, "AVAssetImageGenerator 应能取到视频首帧")
        if let thumbnail {
            XCTAssertGreaterThan(thumbnail.size.width, 0)
            XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), 360)
        }
    }

    func testNonMediaAndMissingFilesReturnNil() async {
        let textURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("note.txt")
        let nonMedia = await ThumbnailCache.shared.thumbnail(for: textURL)
        XCTAssertNil(nonMedia)

        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".png")
        let missingResult = await ThumbnailCache.shared.thumbnail(for: missing)
        XCTAssertNil(missingResult)
    }

    func testFullImageLoaderResizesLargeImage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTypeMobileFullImage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("large.jpg")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000))
        let image = renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.8)).write(to: url)

        let loaded = try XCTUnwrap(FullImageLoader.load(url, maxPixelSize: 1024))
        XCTAssertLessThanOrEqual(max(loaded.size.width, loaded.size.height), 1024)
        XCTAssertEqual(loaded.size.width / loaded.size.height, 1.5, accuracy: 0.02)
    }
}
