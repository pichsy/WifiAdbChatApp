import AppKit

// 生成 macOS 应用图标（圆角方形 + 渐变 + "123" + 发送箭头），输出 iconset
// 用法: build/makeicon <输出目录>

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha)
}

/// 按精确像素尺寸绘制
func render(pixels: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels,
                                     pixelsHigh: pixels,
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0) else {
        fatalError("无法创建位图")
    }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext.current?.cgContext else { return rep }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let size = CGFloat(pixels)
    let margin = size * 0.098
    let content = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = content.width * 0.225
    let shape = NSBezierPath(roundedRect: content, xRadius: radius, yRadius: radius)

    // 外阴影
    let shadow = NSShadow()
    shadow.shadowBlurRadius = size * 0.045
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.set()

    let gradient = NSGradient(colors: [
        color(0x5B9BFF),
        color(0x2F6BFF),
        color(0x1E3FD8)
    ])!
    gradient.draw(in: shape, angle: -62)
    NSShadow().set()

    // 顶部高光
    let highlight = NSBezierPath(roundedRect: content, xRadius: radius, yRadius: radius)
    color(0xFFFFFF, alpha: 0.14).setStroke()
    highlight.lineWidth = max(1, size * 0.012)
    highlight.stroke()

    // "123"
    let fontScale: CGFloat = pixels <= 32 ? 0.44 : 0.31
    let font = NSFont.monospacedSystemFont(ofSize: content.width * fontScale, weight: .bold)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color(0xFFFFFF, alpha: 0.98),
        .paragraphStyle: paragraph
    ]
    let text = NSAttributedString(string: "123", attributes: attributes)
    let textSize = text.size()
    let textY: CGFloat = pixels <= 32
        ? content.midY - textSize.height / 2
        : content.minY + content.height * 0.60 - textSize.height / 2
    text.draw(in: CGRect(x: 0, y: textY, width: size, height: textSize.height))

    // 发送箭头（一次描边，避免叠加色差）
    if pixels > 32 {
        let white = NSColor.white
        white.setStroke()

        let arrowY = content.minY + content.height * 0.255
        let startX = content.minX + content.width * 0.315
        let tipX = content.maxX - content.width * 0.315
        let thickness = content.width * 0.046
        let headLength = content.width * 0.098
        let headHalf = headLength * 0.92
        let shaftEnd = tipX - headLength + thickness * 0.5

        let path = NSBezierPath()
        path.move(to: NSPoint(x: startX, y: arrowY))
        path.line(to: NSPoint(x: shaftEnd, y: arrowY))
        path.move(to: NSPoint(x: tipX - headLength, y: arrowY + headHalf))
        path.line(to: NSPoint(x: tipX, y: arrowY))
        path.line(to: NSPoint(x: tipX - headLength, y: arrowY - headHalf))
        path.lineWidth = thickness
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    return rep
}

func save(pixels: Int, to path: String) {
    let rep = render(pixels: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

let outputs: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (pixels, name) in outputs {
    save(pixels: pixels, to: "\(outDir)/\(name)")
    print("生成 \(name) (\(pixels)px)")
}
