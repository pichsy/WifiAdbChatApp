import XCTest

/// 媒体预览 UI 测试（需要真实电脑先发好图片 / 视频，作为可选联调测试单独运行）：
/// 1. 打开与 pichs 的聊天；
/// 2. 点击图片缩略图 → 全屏查看 → 关闭；
/// 3. 点击视频缩略图 → AVKit 播放器 → 关闭。
final class MediaPreviewUITests: XCTestCase {
    func testImageAndVideoPreview() throws {
        let app = XCUIApplication()
        app.launch()

        let deviceLabel = app.staticTexts["pichs"].firstMatch
        XCTAssertTrue(deviceLabel.waitForExistence(timeout: 20), "设备列表应出现已配对的 pichs")
        deviceLabel.tap()

        let imageThumbnail = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "图片消息"))
            .firstMatch
        if !imageThumbnail.waitForExistence(timeout: 6) {
            // SwiftUI List 行有时需要点 cell 才能进入聊天
            let cell = app.cells.containing(.staticText, identifier: "pichs").firstMatch
            if cell.exists { cell.tap() }
        }
        XCTAssertTrue(imageThumbnail.waitForExistence(timeout: 20), "图片消息应显示缩略图")
        XCTAssertEqual(imageThumbnail.frame.width, 120, accuracy: 5, "缩略图固定约 120pt 宽")
        XCTAssertEqual(imageThumbnail.frame.height, 90, accuracy: 5, "缩略图固定约 90pt 高")
        attachScreenshot(name: "01-chat-thumbnails")

        imageThumbnail.tap()
        let imageClose = app.buttons["image-viewer-close"]
        XCTAssertTrue(imageClose.waitForExistence(timeout: 10), "点击图片应全屏显示可缩放图片")
        sleep(1)
        attachScreenshot(name: "02-image-viewer")

        // 双击放大，验证缩放交互不崩溃
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        sleep(1)
        attachScreenshot(name: "03-image-zoomed")
        imageClose.tap()

        let videoThumbnail = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "视频消息"))
            .firstMatch
        XCTAssertTrue(videoThumbnail.waitForExistence(timeout: 20), "视频消息应显示带播放图标的缩略图")
        XCTAssertEqual(videoThumbnail.frame.width, 120, accuracy: 5, "视频缩略图固定约 120pt 宽")
        XCTAssertEqual(videoThumbnail.frame.height, 90, accuracy: 5, "视频缩略图固定约 90pt 高")
        videoThumbnail.tap()

        let videoClose = app.buttons["video-player-close"]
        XCTAssertTrue(videoClose.waitForExistence(timeout: 10), "点击视频应进入 AVKit 播放器")
        sleep(2)
        // 点一下画面让 AVPlayerViewController 的播放 / 暂停 / 进度条显示出来
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        attachScreenshot(name: "04-video-player")
        videoClose.tap()
    }

    private func attachScreenshot(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
