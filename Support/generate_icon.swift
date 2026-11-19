// PhotoScope 应用图标生成脚本（矢量绘制，可重复生成、可改配色）
// 用法：swift Support/generate_icon.swift Support/AppIcon.png
// 意象：蓝色圆角底 + 叠放的照片卡片（山景与日出）+ 放大镜（检视 / EXIF / GPS）。
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "Support/AppIcon.png"

// 下面所有坐标按「左上原点」书写，转换到 CGContext 的左下原点坐标系。
func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: S - y - h, width: w, height: h)
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: S - y) }
func C(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}
func roundPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("无法创建绘图上下文")
}
ctx.interpolationQuality = .high
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

func shadow(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat) {
    ctx.setShadow(offset: CGSize(width: 0, height: dy), blur: blur, color: C(0, 0, 0, alpha))
}
func clearShadow() {
    ctx.setShadow(offset: .zero, blur: 0, color: C(0, 0, 0, 0))
}

// MARK: 1. 主体：蓝色渐变圆角方块
let body = R(72, 72, 880, 880)
let bodyPath = roundPath(body, 196)
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let blue = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [C(0.05, 0.16, 0.42), C(0.10, 0.36, 0.78), C(0.24, 0.72, 0.95)] as CFArray,
                      locations: [0, 0.52, 1])!
ctx.drawLinearGradient(blue, start: P(130, 96), end: P(910, 936), options: [])
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [C(1, 1, 1, 0.24), C(1, 1, 1, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(glow, start: P(512, 72), end: P(512, 640), options: [])
ctx.restoreGState()

ctx.saveGState()
ctx.setStrokeColor(C(1, 1, 1, 0.30))
ctx.setLineWidth(3)
ctx.addPath(bodyPath)
ctx.strokePath()
ctx.restoreGState()

// MARK: 2. 叠放的照片卡片
let back = R(206, 282, 500, 386)
ctx.saveGState()
ctx.translateBy(x: back.midX, y: back.midY)
ctx.rotate(by: -0.15)
ctx.translateBy(x: -back.midX, y: -back.midY)
shadow(34, -22, 0.30)
ctx.setFillColor(C(1, 1, 1, 0.80))
ctx.addPath(roundPath(back, 30))
ctx.fillPath()
clearShadow()
ctx.restoreGState()

let front = R(292, 234, 520, 404)
ctx.saveGState()
ctx.translateBy(x: front.midX, y: front.midY)
ctx.rotate(by: 0.07)
ctx.translateBy(x: -front.midX, y: -front.midY)
shadow(42, -26, 0.34)
ctx.setFillColor(C(1, 1, 1, 1))
ctx.addPath(roundPath(front, 32))
ctx.fillPath()
clearShadow()

// 相纸留白：下方边略宽，像一张冲印照片
let inner = CGRect(x: front.minX + 20, y: front.minY + 56,
                   width: front.width - 40, height: front.height - 76)
let innerPath = roundPath(inner, 16)
ctx.saveGState()
ctx.addPath(innerPath)
ctx.clip()
let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                     colors: [C(0.62, 0.86, 0.99), C(0.95, 0.98, 1.0)] as CFArray,
                     locations: [0, 1])!
ctx.drawLinearGradient(sky,
                       start: CGPoint(x: inner.minX, y: inner.maxY),
                       end: CGPoint(x: inner.minX, y: inner.minY), options: [])

// 日出
ctx.setFillColor(C(1.0, 0.78, 0.32, 0.96))
ctx.fillEllipse(in: CGRect(x: inner.minX + inner.width * 0.66,
                           y: inner.minY + inner.height * 0.65,
                           width: 78, height: 78))

// 远山
ctx.setFillColor(C(0.36, 0.62, 0.80))
ctx.beginPath()
ctx.move(to: CGPoint(x: inner.minX, y: inner.minY + inner.height * 0.38))
ctx.addLine(to: CGPoint(x: inner.minX + inner.width * 0.24, y: inner.minY + inner.height * 0.74))
ctx.addLine(to: CGPoint(x: inner.minX + inner.width * 0.46, y: inner.minY + inner.height * 0.50))
ctx.addLine(to: CGPoint(x: inner.minX + inner.width * 0.70, y: inner.minY + inner.height * 0.80))
ctx.addLine(to: CGPoint(x: inner.maxX, y: inner.minY + inner.height * 0.42))
ctx.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
ctx.addLine(to: CGPoint(x: inner.minX, y: inner.minY))
ctx.closePath()
ctx.fillPath()

// 近山
ctx.setFillColor(C(0.14, 0.38, 0.62))
ctx.beginPath()
ctx.move(to: CGPoint(x: inner.minX, y: inner.minY + inner.height * 0.20))
ctx.addLine(to: CGPoint(x: inner.minX + inner.width * 0.30, y: inner.minY + inner.height * 0.52))
ctx.addLine(to: CGPoint(x: inner.minX + inner.width * 0.58, y: inner.minY + inner.height * 0.26))
ctx.addLine(to: CGPoint(x: inner.minX + inner.width * 0.82, y: inner.minY + inner.height * 0.48))
ctx.addLine(to: CGPoint(x: inner.maxX, y: inner.minY + inner.height * 0.22))
ctx.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
ctx.addLine(to: CGPoint(x: inner.minX, y: inner.minY))
ctx.closePath()
ctx.fillPath()
ctx.restoreGState()

ctx.setStrokeColor(C(0.76, 0.83, 0.91, 0.9))
ctx.setLineWidth(2)
ctx.addPath(innerPath)
ctx.strokePath()
ctx.restoreGState()

// MARK: 3. 放大镜：检视 / EXIF / GPS 的意象
let lens = R(596, 566, 232, 232)
ctx.saveGState()
shadow(30, -16, 0.30)
// 镜片用较实的浅蓝白，避免下层卡片边角透过镜片形成杂色块
ctx.setFillColor(C(0.90, 0.96, 1.0, 0.62))
ctx.fillEllipse(in: lens)
ctx.setStrokeColor(C(1, 1, 1, 1))
ctx.setLineWidth(30)
ctx.strokeEllipse(in: lens.insetBy(dx: 15, dy: 15))
ctx.setLineCap(.round)
ctx.setLineWidth(40)
ctx.move(to: P(778, 764))
ctx.addLine(to: P(858, 844))
ctx.strokePath()
clearShadow()
ctx.setStrokeColor(C(1, 1, 1, 0.34))
ctx.setLineWidth(8)
ctx.addArc(center: CGPoint(x: lens.midX, y: lens.midY), radius: 86,
           startAngle: 2.35, endAngle: 3.05, clockwise: false)
ctx.strokePath()
ctx.restoreGState()

guard let image = ctx.makeImage() else { fatalError("无法生成图像") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("无法编码 PNG") }
try png.write(to: URL(fileURLWithPath: output), options: .atomic)
print("已生成图标: \(output) (\(Int(S))×\(Int(S)))")
