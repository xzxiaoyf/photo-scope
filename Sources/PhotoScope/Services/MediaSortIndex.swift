import AVFoundation
import Foundation
import ImageIO

/// 用于排序的少量元数据。视频没有 EXIF，拍摄时间用文件/素材创建时间兜底。
struct MediaSortFacts {
    var captureDate: Date?
    var model: String?
    var lens: String?
}

private final class FactsBox: NSObject {
    let facts: MediaSortFacts
    init(_ facts: MediaSortFacts) { self.facts = facts }
}

/// 排序元数据索引：按需读取 EXIF 的拍摄时间 / 相机型号 / 镜头型号并缓存。
///
/// 读取只发生在真正需要排序的字段上；文件名排序完全不需要磁盘 I/O。
/// 无拍摄时间 / 型号 / 镜头的文件始终排在末尾（不随升降序翻转），避免空值在降序时占满最前。
final class MediaSortIndex: @unchecked Sendable {

    static let shared = MediaSortIndex()

    private let cache = NSCache<NSString, FactsBox>()
    private let lock = NSLock()

    private init() { cache.countLimit = 3000 }

    private func key(_ url: URL) -> NSString {
        url.standardizedFileURL.path as NSString
    }

    func invalidate(_ url: URL) {
        cache.removeObject(forKey: key(url))
    }

    func facts(for item: MediaItem) -> MediaSortFacts {
        let cacheKey = key(item.url)
        if let box = cache.object(forKey: cacheKey) { return box.facts }
        let value = read(item)
        cache.setObject(FactsBox(value), forKey: cacheKey)
        return value
    }

    /// 同步排序（自检与真实排序共用同一套逻辑）。
    func sortedSync(_ items: [MediaItem], options: MediaSortOptions) -> [MediaItem] {
        guard items.count > 1 else { return items }
        var facts: [String: MediaSortFacts] = [:]
        if options.key != .fileName {
            let snapshot = items
            var buffer = [MediaSortFacts?](repeating: nil, count: snapshot.count)
            // 每个文件的 EXIF 读取相互独立，并发处理可明显缩短大目录的等待时间
            DispatchQueue.concurrentPerform(iterations: snapshot.count) { index in
                buffer[index] = self.facts(for: snapshot[index])
            }
            for (index, value) in buffer.enumerated() where value != nil {
                facts[snapshot[index].url.standardizedFileURL.path] = value
            }
        }
        let comparator = self.comparator(options: options, facts: facts)
        return items.enumerated().sorted { lhs, rhs in
            if comparator(lhs.element, rhs.element) { return true }
            if comparator(rhs.element, lhs.element) { return false }
            return lhs.offset < rhs.offset          // 稳定排序
        }.map(\.element)
    }

    /// 异步排序，completion 保证在主线程执行。
    func sorted(_ items: [MediaItem], options: MediaSortOptions,
                completion: @escaping ([MediaItem]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.sortedSync(items, options: options) ?? items
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func comparator(options: MediaSortOptions,
                            facts: [String: MediaSortFacts]) -> (MediaItem, MediaItem) -> Bool {
        { lhs, rhs in
            let l = facts[lhs.url.standardizedFileURL.path]
            let r = facts[rhs.url.standardizedFileURL.path]
            let result: ComparisonResult
            switch options.key {
            case .fileName:
                result = MediaSortIndex.compareNames(lhs.name, rhs.name, order: options.order)
            case .captureDate:
                result = MediaSortIndex.compareDate(l?.captureDate, r?.captureDate, order: options.order)
            case .model:
                result = MediaSortIndex.compareString(l?.model, r?.model, order: options.order)
            case .lens:
                result = MediaSortIndex.compareString(l?.lens, r?.lens, order: options.order)
            }
            if result != .orderedSame { return result == .orderedAscending }
            // 同值时用文件名升序做稳定的次级排序
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - 纯比较函数（供自检与排序共用）

    static func compareNames(_ lhs: String, _ rhs: String, order: MediaSortOrder) -> ComparisonResult {
        flip(lhs.localizedStandardCompare(rhs), order: order)
    }

    static func compareString(_ lhs: String?, _ rhs: String?, order: MediaSortOrder) -> ComparisonResult {
        let l = clean(lhs), r = clean(rhs)
        switch (l, r) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending      // 空值恒在末尾
        case (_, nil): return .orderedAscending
        case let (a?, b?): return flip(a.localizedStandardCompare(b), order: order)
        }
    }

    static func compareDate(_ lhs: Date?, _ rhs: Date?, order: MediaSortOrder) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (a?, b?): return flip(a.compare(b), order: order)
        }
    }

    private static func flip(_ result: ComparisonResult, order: MediaSortOrder) -> ComparisonResult {
        guard order == .descending else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - 元数据提取

    private func read(_ item: MediaItem) -> MediaSortFacts {
        switch item.kind {
        case .image: return readImage(item)
        case .video: return readVideo(item)
        }
    }

    private func readImage(_ item: MediaItem) -> MediaSortFacts {
        let props = ImageDecoder.imageProperties(for: item.url) ?? [:]
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]

        let date = parseDate(exif["DateTimeOriginal"])
            ?? parseDate(exif["DateTimeDigitized"])
            ?? parseDate(tiff["DateTime"])
            ?? item.modifiedAt

        let model = firstString(tiff["Model"], exif["Model"], props["Model"])
        let lens = firstString(exif["LensModel"], aux["LensModel"], tiff["LensModel"],
                               aux["LensID"], exif["LensSpecification"])
        return MediaSortFacts(captureDate: date, model: model, lens: lens)
    }

    private func readVideo(_ item: MediaItem) -> MediaSortFacts {
        let asset = AVURLAsset(url: item.url)
        let date = asset.creationDate?.dateValue ?? item.modifiedAt
        var model: String?
        for metadata in asset.commonMetadata {
            guard let identifier = metadata.identifier?.rawValue.lowercased(),
                  let value = metadata.stringValue,
                  (identifier.contains("make") || identifier.contains("model")) else { continue }
            if identifier.contains("model") { model = value } else if model == nil { model = value }
        }
        return MediaSortFacts(captureDate: date, model: model, lens: nil)
    }

    private func firstString(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string
            }
        }
        return nil
    }

    /// EXIF 日期为 "yyyy:MM:dd HH:mm:ss"，部分文件写 ISO 形式；无时区信息时按本机时区解释。
    private func parseDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        let string = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        for format in ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy:MM:dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            formatter.timeZone = TimeZone.current
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
