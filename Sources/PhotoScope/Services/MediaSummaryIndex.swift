import AVFoundation
import Foundation
import ImageIO

/// 网格单元格下方显示的简要拍摄信息（不超过 4 行）。
struct MediaSummary {
    var date: String?
    var model: String?
    var lens: String?
    var exposure: String?

    static let empty = MediaSummary(date: nil, model: nil, lens: nil, exposure: nil)

    var lines: [String] {
        [date, model, lens, exposure].compactMap { $0 }.filter { !$0.isEmpty }
    }
}

private final class SummaryBox: NSObject {
    let summary: MediaSummary
    init(_ summary: MediaSummary) { self.summary = summary }
}

/// 网格视图专用的轻量元数据索引：只读需要的几个 EXIF 字段并缓存。
/// 与 MetadataReader 的完整 EXIF 面板互不干扰，避免为整目录生成大量字典行。
final class MediaSummaryIndex: @unchecked Sendable {

    static let shared = MediaSummaryIndex()

    private let cache = NSCache<NSString, SummaryBox>()
    private let queue = DispatchQueue(label: "com.local.photoscope.grid-summary",
                                      qos: .userInitiated, attributes: .concurrent)

    private init() { cache.countLimit = 3000 }

    private func key(_ url: URL) -> NSString {
        url.standardizedFileURL.path as NSString
    }

    func invalidate(_ url: URL) {
        cache.removeObject(forKey: key(url))
    }

    func cached(_ item: MediaItem) -> MediaSummary? {
        cache.object(forKey: key(item.url))?.summary
    }

    /// 同步读取，务必在后台线程调用。
    func summary(for item: MediaItem) -> MediaSummary {
        let cacheKey = key(item.url)
        if let box = cache.object(forKey: cacheKey) { return box.summary }
        let value = item.isVideo ? readVideo(item) : readImage(item)
        cache.setObject(SummaryBox(value), forKey: cacheKey)
        return value
    }

    /// 异步读取，completion 在主线程执行。
    func summary(for item: MediaItem, completion: @escaping (MediaSummary) -> Void) {
        if let cached = cached(item) {
            DispatchQueue.main.async { completion(cached) }
            return
        }
        queue.async { [weak self] in
            let value = self?.summary(for: item) ?? .empty
            DispatchQueue.main.async { completion(value) }
        }
    }

    // MARK: - 纯格式化函数（自检覆盖）

    static func formatDate(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        // EXIF 形如 "2024:01:02 03:04:05"；也兼容 "2024-01-02 03:04:05"
        let normalized = raw.replacingOccurrences(
            of: #"^(\d{4})[:.-](\d{2})[:.-](\d{2})"#,
            with: "$1-$2-$3", options: .regularExpression)
        return normalized.count > 16 ? String(normalized.prefix(16)) : normalized
    }

    static func formatExposure(iso: Any?, aperture: Any?, shutter: Any?, focal: Any?) -> String? {
        var parts: [String] = []
        if let value = ImageDecoder.numberValue(shutter), value > 0 {
            parts.append(value < 1 ? "1/\(max(1, Int((1 / value).rounded())))s"
                                   : String(format: "%.1fs", value))
        }
        if let value = ImageDecoder.numberValue(aperture), value > 0 {
            parts.append("F\(String(format: "%.1f", value))")
        }
        if let iso = isoValue(iso) { parts.append("ISO\(iso)") }
        if let value = ImageDecoder.numberValue(focal), value > 0 {
            parts.append("\(Int(value.rounded()))mm")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private static func isoValue(_ value: Any?) -> Int? {
        if let array = value as? [Any], let first = array.first,
           let number = ImageDecoder.numberValue(first) { return Int(number) }
        guard let number = ImageDecoder.numberValue(value) else { return nil }
        return Int(number)
    }

    private static func firstString(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return string }
        }
        return nil
    }

    // MARK: - 读取

    private func readImage(_ item: MediaItem) -> MediaSummary {
        let props = ImageDecoder.imageProperties(for: item.url) ?? [:]
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]

        return MediaSummary(
            date: MediaSummaryIndex.formatDate(
                Self.firstString(exif["DateTimeOriginal"], exif["DateTimeDigitized"], tiff["DateTime"]))
                ?? formattedModifiedDate(item),
            model: Self.firstString(tiff["Model"], exif["Model"]),
            lens: Self.firstString(exif["LensModel"], aux["LensModel"], tiff["LensModel"]),
            exposure: MediaSummaryIndex.formatExposure(
                iso: exif[kCGImagePropertyExifISOSpeedRatings as String],
                aperture: exif[kCGImagePropertyExifFNumber as String],
                shutter: exif[kCGImagePropertyExifExposureTime as String],
                focal: exif[kCGImagePropertyExifFocalLength as String])
        )
    }

    private func readVideo(_ item: MediaItem) -> MediaSummary {
        let asset = AVURLAsset(url: item.url)
        let seconds = CMTimeGetSeconds(asset.duration)
        let duration = seconds.isFinite && seconds > 0
            ? String(format: "视频  %02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
            : "视频"
        return MediaSummary(date: formatted(asset.creationDate?.dateValue) ?? formattedModifiedDate(item),
                            model: nil, lens: nil, exposure: duration)
    }

    private func formattedModifiedDate(_ item: MediaItem) -> String? {
        formatted(item.modifiedAt).map { "文件  \($0)" }
    }

    private func formatted(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
