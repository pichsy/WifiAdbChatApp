import XCTest
@testable import ADBTypeMobile

final class PhotoLibrarySaverTests: XCTestCase {
    func testRecognizesCommonImageAndVideoFiles() {
        let media = ["photo.jpg", "PHOTO.JPEG", "image.png", "live.heic", "anim.gif",
                     "pic.webp", "clip.mp4", "clip.MOV", "clip.m4v"]
        for name in media {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertTrue(PhotoLibrarySaver.isMediaFile(url), "\(name) 应识别为图片/视频")
        }
    }

    func testNonMediaFilesAreSkipped() {
        let others = ["note.txt", "doc.pdf", "archive.zip", "data.bin",
                      "app.json", "no-extension", "script.sh"]
        for name in others {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertFalse(PhotoLibrarySaver.isMediaFile(url), "\(name) 不应识别为图片/视频")
        }
    }

    func testImageAndVideoClassification() {
        XCTAssertTrue(PhotoLibrarySaver.isImage(URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertFalse(PhotoLibrarySaver.isVideo(URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertTrue(PhotoLibrarySaver.isVideo(URL(fileURLWithPath: "/tmp/a.mp4")))
        XCTAssertFalse(PhotoLibrarySaver.isImage(URL(fileURLWithPath: "/tmp/a.mp4")))
    }
}
