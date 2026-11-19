import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum JPEGExportError: LocalizedError {
    case decodeFailed(String)
    case destinationFailed(URL)
    case finalizeFailed(URL)
    case overwriteSource

    var errorDescription: String? {
        switch self {
        case .decodeFailed(let name): return "无法解码「\(name)」，系统可能不支持该 RAW/图像编码。"
        case .destinationFailed(let url): return "无法创建输出文件：\(url.path)"
        case .finalizeFailed(let url): return "写入 JPEG 失败：\(url.path)"
        case .overwriteSource: return "输出文件与原文件相同，请选择另一个文件名。"
        }
    }
}

struct JPEGExportResult {
    let url: URL
    /// 是否成功把原始 EXIF / TIFF / GPS 写入目标 JPG。
    let metadataPreserved: Bool
    /// 实际写入的元数据组数（EXIF / TIFF / GPS / IPTC …）。
    let metadataGroupCount: Int
}

/// 把任意可解码的照片（JPG / HEIC / RAW / PNG / TIFF …）转换为 JPG。
/// 视频文件则提取代表帧另存为 JPG。
///
/// 导出时会把原始 EXIF / TIFF / GPS / IPTC / 厂商扩展一并迁移到目标文件，
/// 由 `EXIFPreserver` 负责修正方向、尺寸与压缩相关字段。
enum JPEGExporter {

    /// 出厂默认质量；使用者可在保存面板或「文件 → JPG 导出质量…」中修改。
    static let defaultQuality: Double = 0.90
    static let minimumQuality: Double = 0.10

    private static let qualityDefaultsKey = "PhotoScope.jpegQuality"

    /// 记住的质量偏好（UserDefaults），下次导出时作为滑杆初值。
    static var preferredQuality: Double {
        get {
            guard let stored = UserDefaults.standard.object(forKey: qualityDefaultsKey) as? Double else {
                return defaultQuality
            }
            return clamped(stored)
        }
        set {
            UserDefaults.standard.set(clamped(newValue), forKey: qualityDefaultsKey)
        }
    }

    static func clamped(_ quality: Double) -> Double {
        let value = quality.isFinite ? quality : defaultQuality
        return min(max(value, minimumQuality), 1.0)
    }

    static func percent(_ quality: Double) -> Int {
        Int((clamped(quality) * 100).rounded())
    }

    static func suggestedName(for item: MediaItem) -> String {
        item.url.deletingPathExtension().lastPathComponent + ".jpg"
    }

    /// 自动补全 / 修正扩展名为 .jpg
    static func normalized(_ url: URL) -> URL {
        let ext = url.pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg" { return url }
        if ext.isEmpty { return url.appendingPathExtension("jpg") }
        return url.deletingPathExtension().appendingPathExtension("jpg")
    }

    /// - Parameter quality: 传入 nil 时使用记住的偏好质量
    /// - Returns: 实际写入的文件 URL
    @discardableResult
    static func export(_ item: MediaItem, to destination: URL,
                       quality: Double? = nil) throws -> URL {
        try exportDetailed(item, to: destination, quality: quality).url
    }

    /// 与 `export` 相同，但额外返回元数据是否保留成功，供状态栏提示。
    @discardableResult
    static func exportDetailed(_ item: MediaItem, to destination: URL,
                               quality: Double? = nil) throws -> JPEGExportResult {
        let output = normalized(destination)
        guard output.standardizedFileURL != item.url.standardizedFileURL else {
            throw JPEGExportError.overwriteSource
        }

        let q = clamped(quality ?? preferredQuality)
        let cgImage: CGImage
        switch item.kind {
        case .image:
            guard let decoded = ImageDecoder.fullSize(url: item.url) else {
                throw JPEGExportError.decodeFailed(item.name)
            }
            cgImage = decoded.orientationApplied
                ? decoded.cgImage
                : ImageDecoder.withUserRotation(
                    ImageDecoder.oriented(decoded.cgImage,
                                          orientation: ImageDecoder.orientation(for: item.url)),
                    url: item.url)
        case .video:
            guard let frame = ImageDecoder.videoFrame(url: item.url, maxPixel: Int.max) else {
                throw JPEGExportError.decodeFailed(item.name)
            }
            cgImage = frame
        }

        let full = EXIFPreserver.properties(for: item, image: cgImage, quality: q)
        if write(cgImage, to: output, properties: full) {
            return JPEGExportResult(url: output,
                                    metadataPreserved: metadataGroupCount(full) > 0,
                                    metadataGroupCount: metadataGroupCount(full))
        }

        // 某些厂商私有字段可能导致写入失败：先降级到核心三组，再降级到纯像素，
        // 保证「另存为 JPG」永远不会因为元数据而整个失败。
        let core = EXIFPreserver.coreProperties(full)
        if write(cgImage, to: output, properties: core) {
            return JPEGExportResult(url: output,
                                    metadataPreserved: metadataGroupCount(core) > 0,
                                    metadataGroupCount: metadataGroupCount(core))
        }
        if write(cgImage, to: output, properties: EXIFPreserver.minimalProperties(quality: q)) {
            return JPEGExportResult(url: output, metadataPreserved: false, metadataGroupCount: 0)
        }
        try? FileManager.default.removeItem(at: output)
        throw JPEGExportError.finalizeFailed(output)
    }

    private static func write(_ image: CGImage, to url: URL, properties: [String: Any]) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return false }
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        return CGImageDestinationFinalize(writer)
    }

    private static func metadataGroupCount(_ props: [String: Any]) -> Int {
        props.filter { $0.value is [String: Any] }.count
    }
}
