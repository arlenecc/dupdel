// 生成 App 图标：用 CoreGraphics 绘制「两份重叠文件 + 减号」的去重意象，
// 输出标准 .iconset 目录（再由 iconutil 合成 .icns）。
// 用法： swiftc -O scripts/make_icon.swift -o /tmp/make_icon && /tmp/make_icon <输出目录>

import CoreGraphics
import Foundation
import ImageIO

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "dist/AppIcon.iconset"

// MARK: - 绘图工具

func squirclePath(_ rect: CGRect, cornerRatio: CGFloat) -> CGPath {
    CGPath(
        roundedRect: rect,
        cornerWidth: rect.width * cornerRatio,
        cornerHeight: rect.width * cornerRatio,
        transform: nil
    )
}

func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = Swift.min(radius, rect.width / 2, rect.height / 2)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
    path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                startAngle: -CGFloat.pi / 2, endAngle: 0, clockwise: false)
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
    path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                startAngle: 0, endAngle: CGFloat.pi / 2, clockwise: false)
    path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
    path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                startAngle: CGFloat.pi / 2, endAngle: CGFloat.pi, clockwise: false)
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
    path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                startAngle: CGFloat.pi, endAngle: -CGFloat.pi / 2, clockwise: false)
    path.closeSubpath()
    return path
}

// MARK: - 图标主体（坐标系：左上角原点，y 向下）

func drawIcon(size s: CGFloat) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: Int(s),
        height: Int(s),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("无法创建图形上下文")
    }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    // 转换为左上角原点坐标
    context.translateBy(x: 0, y: s)
    context.scaleBy(x: 1, y: -1)
    context.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // 1) 背景圆角方块 + 渐变
    let inset = s * 0.055
    let backgroundRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    context.saveGState()
    context.addPath(squirclePath(backgroundRect, cornerRatio: 0.225))
    context.clip()
    let gradientColors = [
        CGColor(red: 0.38, green: 0.63, blue: 1.00, alpha: 1),   // 上方亮蓝
        CGColor(red: 0.10, green: 0.36, blue: 0.88, alpha: 1),   // 下方深蓝
    ]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors as CFArray, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: backgroundRect.midX, y: backgroundRect.minY),
            end: CGPoint(x: backgroundRect.midX, y: backgroundRect.maxY),
            options: []
        )
    }
    // 顶部高光（用渐变过渡，避免出现硬边）
    let highlightColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ]
    if let highlight = CGGradient(colorsSpace: colorSpace, colors: highlightColors as CFArray, locations: [0, 1]) {
        context.drawLinearGradient(
            highlight,
            start: CGPoint(x: backgroundRect.midX, y: backgroundRect.minY),
            end: CGPoint(x: backgroundRect.midX, y: backgroundRect.minY + (s - inset * 2) * 0.55),
            options: []
        )
    }
    context.restoreGState()

    // 背景描边，让小尺寸下轮廓更清晰
    context.setStrokeColor(CGColor(red: 0.06, green: 0.24, blue: 0.62, alpha: 0.55))
    context.setLineWidth(Swift.max(1, s * 0.012))
    context.addPath(squirclePath(backgroundRect, cornerRatio: 0.225))
    context.strokePath()

    // 2) 两份重叠文件：左前（保留）+ 右后（待清理）
    let cardWidth = s * 0.40
    let cardHeight = s * 0.50
    let cardRadius = s * 0.075

    let backCard = CGRect(x: s * 0.335, y: s * 0.215, width: cardWidth, height: cardHeight)
    let frontCard = CGRect(x: s * 0.235, y: s * 0.345, width: cardWidth, height: cardHeight)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: s * 0.022), blur: s * 0.035,
                      color: CGColor(gray: 0, alpha: 0.32))

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
    context.addPath(roundedRectPath(backCard, radius: cardRadius))
    context.fillPath()

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.98))
    context.addPath(roundedRectPath(frontCard, radius: cardRadius))
    context.fillPath()
    context.restoreGState()

    // 3) 前面文件里的“内容行”
    context.setFillColor(CGColor(red: 0.62, green: 0.68, blue: 0.80, alpha: 1))
    let lineHeight = s * 0.032
    for index in 0..<3 {
        let y = frontCard.minY + s * 0.16 + CGFloat(index) * s * 0.105
        let line = CGRect(x: frontCard.minX + s * 0.075, y: y,
                          width: cardWidth - s * 0.15, height: lineHeight)
        context.addPath(roundedRectPath(line, radius: lineHeight / 2))
        context.fillPath()
    }

    // 4) 右下角减号徽标：删除重复
    let badgeCenter = CGPoint(x: s * 0.665, y: s * 0.70)
    let badgeRadius = s * 0.155
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: s * 0.018), blur: s * 0.03,
                      color: CGColor(gray: 0, alpha: 0.35))
    context.setFillColor(CGColor(red: 1.0, green: 0.35, blue: 0.34, alpha: 1))
    context.addEllipse(in: CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                                  width: badgeRadius * 2, height: badgeRadius * 2))
    context.fillPath()
    context.restoreGState()

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    let minusWidth = badgeRadius * 1.05
    let minusHeight = badgeRadius * 0.24
    let minusRect = CGRect(x: badgeCenter.x - minusWidth / 2, y: badgeCenter.y - minusHeight / 2,
                           width: minusWidth, height: minusHeight)
    context.addPath(roundedRectPath(minusRect, radius: minusHeight / 2))
    context.fillPath()

    guard let image = context.makeImage() else { fatalError("无法生成图像") }
    return image
}

// MARK: - 输出

func writePNG(_ image: CGImage, to url: URL) throws {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        fatalError("无法创建 PNG 输出")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("PNG 写入失败") }
    try (data as Data).write(to: url)
}

let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

// macOS 图标需要的尺寸组合
let sizes: [(base: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

for item in sizes {
    let pixelSize = CGFloat(item.base * item.scale)
    let image = drawIcon(size: pixelSize)
    let name = item.scale == 1
        ? "icon_\(item.base)x\(item.base).png"
        : "icon_\(item.base)x\(item.base)@2x.png"
    try writePNG(image, to: directory.appendingPathComponent(name))
    print("已生成 \(name)")
}
