import AppKit
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 解码结果。`orientationApplied` 表示得到的 CGImage 已经烘焙了 EXIF 方向
/// 与用户在右键菜单追加的旋转，导出 JPEG 时不需要再二次旋转。
struct DecodedImage {
    let cgImage: CGImage
    let orientationApplied: Bool
}

/// 统一的图像解码层。
///
/// - 常规格式（JPG / HEIC / PNG / TIFF / AVIF / 大部分 RAW）：走 ImageIO。
/// - ImageIO 解不了的 RAW（部分 CR3 / 新机型）：回退 Core Image 的 CIRAWFilter。
/// - 大图显示按最长边限幅解码，避免 6000 万像素 RAW 直接占用数百 MB；
///   「另存为 JPG」使用全尺寸解码，保证输出质量。
enum ImageDecoder {

    /// 显示用解码上限（像素）。覆盖 4K/5K 屏幕，且不会明显损失观看细节。
    static let displayMaxPixel = 4096
    static let thumbnailMaxPixel = 260

    private static let ciContext: CIContext = CIContext()
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    // MARK: - 公开接口

    static func imageSource(for url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, nil)
    }

    static func imageProperties(for url: URL) -> [String: Any]? {
        guard let source = imageSource(for: url),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) else { return nil }
        return props as? [String: Any]
    }

    static func containerProperties(for url: URL) -> [String: Any]? {
        guard let source = imageSource(for: url),
              let props = CGImageSourceCopyProperties(source, nil) else { return nil }
        return props as? [String: Any]
    }

    static func orientation(for url: URL) -> UInt32 {
        guard let props = imageProperties(for: url),
              let number = numberValue(props[kCGImagePropertyOrientation as String]) else { return 1 }
        return UInt32(truncatingIfNeeded: max(1, min(8, Int(number))))
    }

    static func pixelSize(for url: URL) -> CGSize? {
        if let props = imageProperties(for: url),
           let w = numberValue(props[kCGImagePropertyPixelWidth as String]),
           let h = numberValue(props[kCGImagePropertyPixelHeight as String]) {
            return CGSize(width: w, height: h)
        }
        guard let source = imageSource(for: url),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CGSize(width: cg.width, height: cg.height)
    }

    /// 限幅解码（显示 / 缩略图），自动应用 EXIF 方向与用户追加的旋转。
    static func bounded(url: URL, maxPixel: Int) -> DecodedImage? {
        if let source = imageSource(for: url), CGImageSourceGetCount(source) > 0 {
            let options: [String: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: maxPixel,
                kCGImageSourceShouldCacheImmediately as String: true
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return DecodedImage(cgImage: withUserRotation(cg, url: url), orientationApplied: true)
            }
        }
        // 部分 RAW / 特殊格式：用 Core Image 的 RAW 解码器兜底
        if let cg = rawFallback(url: url, maxPixel: maxPixel) {
            return DecodedImage(cgImage: withUserRotation(cg, url: url), orientationApplied: true)
        }
        return nil
    }

    static func displayNSImage(url: URL, maxPixel: Int = displayMaxPixel) -> NSImage? {
        guard let decoded = bounded(url: url, maxPixel: maxPixel) else { return nil }
        return nsImage(from: decoded.cgImage)
    }

    static func thumbnailNSImage(url: URL, maxPixel: Int = thumbnailMaxPixel) -> NSImage? {
        displayNSImage(url: url, maxPixel: maxPixel)
    }

    /// 全尺寸解码（导出用）。此处统一烘焙 EXIF 方向与用户旋转，保证导出的 JPG 与屏幕一致。
    static func fullSize(url: URL) -> DecodedImage? {
        if let source = imageSource(for: url), CGImageSourceGetCount(source) > 0,
           let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let orientedCG = oriented(cg, orientation: orientation(for: url))
            return DecodedImage(cgImage: withUserRotation(orientedCG, url: url), orientationApplied: true)
        }
        if let cg = rawFallback(url: url, maxPixel: Int.max) {
            return DecodedImage(cgImage: withUserRotation(cg, url: url), orientationApplied: true)
        }
        return nil
    }

    /// 叠加用户在缩略图右键菜单追加的旋转（非破坏性，不改原文件）。
    static func withUserRotation(_ cg: CGImage, url: URL) -> CGImage {
        rotated(cg, quarterTurns: RotationStore.quarterTurns(for: url))
    }

    /// 按 quarterTurns（顺时针 90° 为单位）旋转 CGImage，奇数次会交换宽高。
    static func rotated(_ cg: CGImage, quarterTurns: Int) -> CGImage {
        let turns = RotationStore.normalized(quarterTurns)
        guard turns != 0 else { return cg }

        let swapped = turns % 2 == 1
        let width = swapped ? cg.height : cg.width
        let height = swapped ? cg.width : cg.height
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cg }

        // CGContext 正角度为逆时针，顺时针需要取负；先把两张图中心对齐再旋转。
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.translateBy(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return context.makeImage() ?? cg
    }

    /// 按 EXIF 方向把 CGImage 旋转成正向图像。
    static func oriented(_ cg: CGImage, orientation: UInt32) -> CGImage {
        guard orientation >= 1, orientation <= 8, orientation != 1,
              let value = CGImagePropertyOrientation(rawValue: orientation) else { return cg }
        let ci = CIImage(cgImage: cg).oriented(value)
        return ciContext.createCGImage(
            ci,
            from: ci.extent.integral,
            format: .RGBA8,
            colorSpace: sRGB ?? CGColorSpaceCreateDeviceRGB()
        ) ?? cg
    }

    static func nsImage(from cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - 视频取帧

    /// 从视频中提取一帧（同步封装，调用方必须在后台线程调用）。
    static func videoFrame(url: URL, at time: CMTime = CMTime(seconds: 0.6, preferredTimescale: 600),
                           maxPixel: Int = 4096) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        if maxPixel < Int.max / 2 {
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        }

        let frame = generateFrame(generator: generator, time: time)
            // 某些短视频在 0.6s 处已结束，退回第 0 帧
            ?? generateFrame(generator: generator, time: .zero)
        return frame.map { withUserRotation($0, url: url) }
    }

    static func videoPoster(url: URL, maxPixel: Int = 1200) -> NSImage? {
        guard let cg = videoFrame(url: url, maxPixel: maxPixel) else { return nil }
        return nsImage(from: cg)
    }

    private static func generateFrame(generator: AVAssetImageGenerator, time: CMTime) -> CGImage? {
        let box = ResultBox<CGImage>()
        let semaphore = DispatchSemaphore(value: 0)
        generator.generateCGImageAsynchronously(for: time) { image, _, _ in
            box.value = image
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else { return nil }
        return box.value
    }

    // MARK: - RAW 兜底

    private static func rawFallback(url: URL, maxPixel: Int) -> CGImage? {
        guard let filter = CIRAWFilter(imageURL: url), let base = filter.outputImage else { return nil }
        let extent = base.extent.integral
        guard extent.width > 1, extent.height > 1 else { return nil }

        var image = base
        if maxPixel > 0 && maxPixel < Int.max / 2 {
            let longest = max(extent.width, extent.height)
            if longest > CGFloat(maxPixel) {
                let scale = CGFloat(maxPixel) / longest
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        return ciContext.createCGImage(
            image,
            from: image.extent.integral,
            format: .RGBA8,
            colorSpace: sRGB ?? CGColorSpaceCreateDeviceRGB()
        )
    }

    // MARK: - 工具

    static func numberValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string.trimmingCharacters(in: .whitespaces))
        case let int as Int: return Double(int)
        case let double as Double: return double
        default: return nil
        }
    }
}

/// 跨线程传递异步结果的容器。
final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
