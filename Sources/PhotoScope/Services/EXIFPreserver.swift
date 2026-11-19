import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 导出 JPG 时迁移源文件的原始元数据（EXIF / TIFF / GPS / IPTC / 厂商扩展）。
///
/// `CGImageDestinationAddImage` 默认只写像素，必须把 properties 一起传进去才会保留 EXIF。
/// 迁移时有几处必须修正，否则元数据会「说谎」：
///  - 像素已经烘焙了 EXIF 方向和用户在缩略图菜单追加的旋转，所以 Orientation 必须重置为 1，
///    否则看图软件会再转一次；
///  - PixelWidth / PixelHeight / PixelXDimension / PixelYDimension 要按导出后的真实像素重写
///    （旋转 90° 后宽高是交换的）；
///  - Compression / CompressedBitsPerPixel / FileSize / Depth / ColorModel / ProfileName 由
///    JPEG 编码器按新的压缩质量与色彩空间决定，沿用源值会自相矛盾；
///  - EXIF APP1 段上限约 64 KB，厂商 MakerNote 等大二进制字段需要裁剪。
///
/// 视频没有 EXIF：用素材的创建时间合成 DateTimeOriginal，并把 ISO 6709 坐标写成标准 GPS 字典。
enum EXIFPreserver {

    /// 单个二进制字段上限（避免 MakerNote 撑爆 APP1 段）。
    private static let maxDataBytes = 16 * 1024
    /// 整份元数据的保守上限，超过时按优先级裁剪。
    private static let maxPropertyBytes = 48 * 1024

    private static let exifKey = kCGImagePropertyExifDictionary as String
    private static let tiffKey = kCGImagePropertyTIFFDictionary as String
    private static let gpsKey = kCGImagePropertyGPSDictionary as String

    /// 与源容器绑定、对 JPEG 无意义的字典组，直接丢弃。
    private static let containerOnlyGroups: Set<String> = [
        "{HEIF}", "{HEICS}", "{PNG}", "{GIF}", "{Raw}", "{DNG}", "{CIFF}",
        "{WebP}", "{TGA}", "{AVIS}", "{OpenEXR}", "{8BIM}", "{FileContents}"
    ]

    /// 由编码器 / 本次导出决定的顶层键，不能沿用源文件的值。
    private static let derivedTopLevelKeys: Set<String> = [
        kCGImagePropertyFileSize as String,
        kCGImagePropertyPixelWidth as String,
        kCGImagePropertyPixelHeight as String,
        kCGImagePropertyOrientation as String,
        kCGImagePropertyProfileName as String,
        "Depth", "ColorModel", "IsIndexed", "HasAlpha"
    ]

    /// 顶层保留的标量（DPI 信息，JPEG 编码器不一定会自己写）。
    private static let preservedTopLevelKeys: Set<String> = ["DPIWidth", "DPIHeight"]

    // MARK: - 主入口

    /// 生成传给 `CGImageDestinationAddImage` 的完整 properties（含压缩质量）。
    static func properties(for item: MediaItem, image: CGImage, quality: Double) -> [String: Any] {
        var props: [String: Any] = item.isVideo
            ? videoProperties(for: item)
            : sourceImageProperties(for: item.url)

        for key in derivedTopLevelKeys { props.removeValue(forKey: key) }

        // 像素已烘焙方向：顶层 + TIFF 两处都要归一化为 1。
        props[kCGImagePropertyOrientation as String] = 1
        props[kCGImagePropertyPixelWidth as String] = image.width
        props[kCGImagePropertyPixelHeight as String] = image.height

        var tiff = (props[tiffKey] as? [String: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        tiff.removeValue(forKey: kCGImagePropertyTIFFCompression as String)
        if !tiff.isEmpty { props[tiffKey] = tiff }

        var exif = (props[exifKey] as? [String: Any]) ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = image.width
        exif[kCGImagePropertyExifPixelYDimension as String] = image.height
        exif.removeValue(forKey: kCGImagePropertyExifCompressedBitsPerPixel as String)
        if !exif.isEmpty { props[exifKey] = exif }

        // GPS：完整的源 EXIF GPS 字典优先；源文件只有 XMP(DJI) 坐标时合成标准 GPS 字典。
        let existingGPS = (props[gpsKey] as? [String: Any]) ?? [:]
        if !hasUsableGPS(existingGPS), let location = MetadataReader.gpsLocation(for: item) {
            props[gpsKey] = gpsDictionary(location)
        }

        props[kCGImageDestinationLossyCompressionQuality as String] = quality
        return limited(props)
    }

    /// 写入失败时的降级方案：只保留 EXIF / TIFF / GPS 三个核心组。
    static func coreProperties(_ props: [String: Any]) -> [String: Any] {
        let keep: Set<String> = [
            exifKey, tiffKey, gpsKey,
            kCGImagePropertyOrientation as String,
            kCGImagePropertyPixelWidth as String,
            kCGImagePropertyPixelHeight as String,
            kCGImageDestinationLossyCompressionQuality as String
        ]
        return props.filter { keep.contains($0.key) }
    }

    /// 最终兜底：仅质量参数，保证导出不会因异常元数据而失败。
    static func minimalProperties(quality: Double) -> [String: Any] {
        [kCGImageDestinationLossyCompressionQuality as String: quality]
    }

    // MARK: - 照片元数据

    private static func sourceImageProperties(for url: URL) -> [String: Any] {
        guard let raw = ImageDecoder.imageProperties(for: url) else { return [:] }
        var result: [String: Any] = [:]
        for (key, value) in raw {
            if let dict = value as? [String: Any] {
                if containerOnlyGroups.contains(key) { continue }
                if let cleaned = sanitize(dict) as? [String: Any], !cleaned.isEmpty {
                    result[key] = cleaned
                }
            } else if preservedTopLevelKeys.contains(key), let scalar = sanitize(value) {
                result[key] = scalar
            }
        }
        return result
    }

    // MARK: - 视频元数据

    private static func videoProperties(for item: MediaItem) -> [String: Any] {
        var props: [String: Any] = [:]
        var exif: [String: Any] = [:]
        var tiff: [String: Any] = [:]

        if let date = MetadataReader.videoCaptureDate(for: item.url) {
            let text = exifDateString(date)
            exif[kCGImagePropertyExifDateTimeOriginal as String] = text
            exif[kCGImagePropertyExifDateTimeDigitized as String] = text
            exif[kCGImagePropertyExifOffsetTimeOriginal as String] = offsetString(for: date)
            tiff[kCGImagePropertyTIFFDateTime as String] = text
        }
        if let location = MetadataReader.gpsLocation(for: item) {
            props[gpsKey] = gpsDictionary(location)
        }
        if !exif.isEmpty { props[exifKey] = exif }
        if !tiff.isEmpty { props[tiffKey] = tiff }
        return props
    }

    // MARK: - GPS 字典

    private static func hasUsableGPS(_ dict: [String: Any]) -> Bool {
        ImageDecoder.numberValue(dict[kCGImagePropertyGPSLatitude as String]) != nil
            && ImageDecoder.numberValue(dict[kCGImagePropertyGPSLongitude as String]) != nil
    }

    /// 把 WGS-84 十进制度写成 EXIF GPS 字典（度 + N/S/E/W 参考方向）。
    static func gpsDictionary(_ location: GPSLocation) -> [String: Any] {
        var dict: [String: Any] = [
            kCGImagePropertyGPSVersion as String: [2, 3, 0, 0],
            kCGImagePropertyGPSMapDatum as String: "WGS-84",
            kCGImagePropertyGPSLatitude as String: abs(location.latitude),
            kCGImagePropertyGPSLatitudeRef as String: location.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(location.longitude),
            kCGImagePropertyGPSLongitudeRef as String: location.longitude >= 0 ? "E" : "W"
        ]
        if let altitude = location.altitude {
            dict[kCGImagePropertyGPSAltitude as String] = abs(altitude)
            dict[kCGImagePropertyGPSAltitudeRef as String] = altitude < 0 ? 1 : 0
        }
        return dict
    }

    // MARK: - 时间格式

    private static func exifDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func offsetString(for date: Date) -> String {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        return String(format: "%@%02d:%02d", sign, absolute / 3600, (absolute % 3600) / 60)
    }

    // MARK: - 清洗与体积控制

    /// 只保留 ImageIO 能序列化的类型，并剔除超大二进制 / 超长字符串。
    private static func sanitize(_ value: Any, depth: Int = 0) -> Any? {
        guard depth < 6 else { return nil }
        switch value {
        case let data as Data:
            return data.count <= maxDataBytes ? data : nil
        case let string as String:
            return string.utf8.count <= 8192 ? string : nil
        case let number as NSNumber:
            return number
        case let date as Date:
            return date
        case let array as [Any]:
            guard array.count <= 256 else { return nil }
            return array.compactMap { sanitize($0, depth: depth + 1) }
        case let dict as [String: Any]:
            var cleaned: [String: Any] = [:]
            for (key, nested) in dict where key.utf8.count <= 128 {
                if let item = sanitize(nested, depth: depth + 1) { cleaned[key] = item }
            }
            return cleaned.isEmpty ? nil : cleaned
        default:
            return nil
        }
    }

    /// 元数据过大时，先丢非核心组，再丢核心组里的二进制 / 数组字段。
    private static func limited(_ props: [String: Any]) -> [String: Any] {
        guard approximateSize(props) > maxPropertyBytes else { return props }
        var trimmed = coreProperties(props)
        guard approximateSize(trimmed) > maxPropertyBytes else { return trimmed }
        for key in [exifKey, tiffKey, gpsKey] {
            guard let dict = trimmed[key] as? [String: Any] else { continue }
            trimmed[key] = dict.filter { _, value in
                !(value is Data) && !(value is [Any]) && !(value is [String: Any])
            }
        }
        return trimmed
    }

    private static func approximateSize(_ value: Any, depth: Int = 0) -> Int {
        guard depth < 6 else { return 0 }
        switch value {
        case let data as Data: return data.count
        case let string as String: return string.utf8.count
        case let array as [Any]: return array.reduce(0) { $0 + approximateSize($1, depth: depth + 1) }
        case let dict as [String: Any]:
            return dict.reduce(0) { $0 + $1.key.utf8.count + approximateSize($1.value, depth: depth + 1) }
        default: return 8
        }
    }
}
