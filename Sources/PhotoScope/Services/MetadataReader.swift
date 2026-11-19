import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GPSLocation {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let source: String
}

struct MetadataRow {
    let key: String
    let value: String
}

struct MetadataSection {
    let title: String
    let rows: [MetadataRow]
}

struct PhotoMetadata {
    let sections: [MetadataSection]
    let pixelSize: CGSize?
    let gps: GPSLocation?

    static let empty = PhotoMetadata(sections: [], pixelSize: nil, gps: nil)
}

/// EXIF / TIFF / GPS / IPTC 以及视频元数据读取。
///
/// GPS 有两级来源：
///  1. 标准 EXIF GPS 字典（含 N/S/E/W 参考方向修正）；
///  2. XMP 兜底，主要覆盖 DJI 等把坐标写进 drone-dji:GpsLatitude/GpsLongitude 的情况
///     （部分机型通过遥控器写入的坐标不落在 EXIF GPS 字典里）。
enum MetadataReader {

    static func read(_ item: MediaItem) -> PhotoMetadata {
        switch item.kind {
        case .image: return readImage(item)
        case .video: return readVideo(item)
        }
    }

    // MARK: - 照片

    private static func readImage(_ item: MediaItem) -> PhotoMetadata {
        let props = ImageDecoder.imageProperties(for: item.url) ?? [:]
        let container = ImageDecoder.containerProperties(for: item.url) ?? [:]
        let pixelSize = ImageDecoder.pixelSize(for: item.url)

        var sections: [MetadataSection] = [fileSection(item: item, pixelSize: pixelSize)]

        // 容器级标量（FileSize / UTI 等）
        var containerRows: [MetadataRow] = []
        for (key, value) in container.sorted(by: { $0.key < $1.key }) {
            guard !(value is [String: Any]) else { continue }
            containerRows.append(MetadataRow(key: label(for: key), value: formatted(key: key, value: value)))
        }
        if !containerRows.isEmpty {
            sections.append(MetadataSection(title: "容器信息", rows: containerRows))
        }

        // 分组字典（EXIF / TIFF / GPS / 厂商 MakerNote …）
        let dicts: [(String, [String: Any])] = props.compactMap { key, value in
            guard let dict = value as? [String: Any] else { return nil }
            return (key, dict)
        }.sorted { lhs, rhs in
            let l = groupRank(lhs.0), r = groupRank(rhs.0)
            return l == r ? lhs.0 < rhs.0 : l < r
        }
        for (group, dict) in dicts {
            let rows = dict.keys.sorted().map { key in
                MetadataRow(key: label(for: key), value: formatted(key: key, value: dict[key] as Any))
            }
            sections.append(MetadataSection(title: title(for: group), rows: rows))
        }

        // 顶层标量（像素尺寸、色彩模型等）
        var topRows: [MetadataRow] = []
        for (key, value) in props.sorted(by: { $0.key < $1.key }) where !(value is [String: Any]) {
            topRows.append(MetadataRow(key: label(for: key), value: formatted(key: key, value: value)))
        }
        if !topRows.isEmpty {
            sections.append(MetadataSection(title: "图像属性", rows: topRows))
        }

        let gps = gpsLocation(from: props, url: item.url)
        if gps == nil {
            sections.append(MetadataSection(title: "GPS 定位", rows: [
                MetadataRow(key: "状态", value: "未检测到有效坐标（地图按钮不可用）")
            ]))
        }

        return PhotoMetadata(sections: sections, pixelSize: pixelSize, gps: gps)
    }

    private static func fileSection(item: MediaItem, pixelSize: CGSize?) -> MetadataSection {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var rows: [MetadataRow] = [
            MetadataRow(key: "文件名", value: item.name),
            MetadataRow(key: "完整路径", value: item.url.path),
            MetadataRow(key: "文件大小", value: byteString(item.byteCount)),
            MetadataRow(key: "文件类型", value: UTType(filenameExtension: item.url.pathExtension)?.identifier ?? item.url.pathExtension.uppercased())
        ]
        if let date = item.modifiedAt {
            rows.append(MetadataRow(key: "修改时间", value: dateFormatter.string(from: date)))
        }
        if let size = pixelSize {
            rows.append(MetadataRow(key: "像素尺寸", value: "\(Int(size.width)) × \(Int(size.height))"))
        }
        return MetadataSection(title: "文件", rows: rows)
    }

    // MARK: - 视频

    private static func readVideo(_ item: MediaItem) -> PhotoMetadata {
        let asset = AVURLAsset(url: item.url)
        var rows: [MetadataRow] = [
            MetadataRow(key: "文件名", value: item.name),
            MetadataRow(key: "完整路径", value: item.url.path),
            MetadataRow(key: "文件大小", value: byteString(item.byteCount))
        ]
        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite, seconds > 0 {
            rows.append(MetadataRow(key: "时长", value: durationString(seconds)))
        }
        if let track = asset.tracks(withMediaType: .video).first {
            let size = track.naturalSize
            rows.append(MetadataRow(key: "分辨率", value: "\(Int(size.width)) × \(Int(size.height))"))
            if track.nominalFrameRate > 0 {
                rows.append(MetadataRow(key: "标称帧率", value: String(format: "%.2f fps", track.nominalFrameRate)))
            }
        }
        if asset.tracks(withMediaType: .audio).isEmpty == false {
            rows.append(MetadataRow(key: "音轨", value: "有"))
        }
        var sections: [MetadataSection] = [MetadataSection(title: "视频", rows: rows)]

        var common: [MetadataRow] = []
        for metadata in asset.commonMetadata {
            let key = metadata.identifier?.rawValue ?? metadata.commonKey?.rawValue ?? "未知"
            if let value = metadata.stringValue ?? metadata.numberValue?.stringValue ?? metadata.dateValue?.description {
                common.append(MetadataRow(key: label(for: key), value: value))
            }
        }
        if !common.isEmpty {
            sections.append(MetadataSection(title: "通用元数据", rows: common))
        }

        let gps = gpsFromVideo(asset)
        if let gps = gps {
            sections.append(MetadataSection(title: "GPS 定位", rows: [
                MetadataRow(key: "纬度", value: String(format: "%.6f°", gps.latitude)),
                MetadataRow(key: "经度", value: String(format: "%.6f°", gps.longitude)),
                MetadataRow(key: "来源", value: gps.source)
            ]))
        }
        return PhotoMetadata(sections: sections, pixelSize: nil, gps: gps)
    }

    // MARK: - GPS

    /// 供 JPG 导出复用：按「EXIF GPS → XMP(DJI) → 视频 ISO 6709」顺序取 WGS-84 坐标。
    /// 注意此处不做 GCJ-02 转换——EXIF 标准写的是 WGS-84，偏移只在地图显示时处理。
    static func gpsLocation(for item: MediaItem) -> GPSLocation? {
        switch item.kind {
        case .image:
            return gpsLocation(from: ImageDecoder.imageProperties(for: item.url) ?? [:], url: item.url)
        case .video:
            return gpsFromVideo(AVURLAsset(url: item.url))
        }
    }

    /// 视频素材里记录的创建时间，用于给导出的 JPG 补 DateTimeOriginal。
    /// 依次尝试 AVAsset.creationDate、通用元数据、以及 QuickTime 私有的 creationdate 项。
    static func videoCaptureDate(for url: URL) -> Date? {
        let asset = AVURLAsset(url: url)
        if let date = asset.creationDate?.dateValue { return date }
        for metadata in asset.commonMetadata + asset.metadata {
            let identifier = [
                metadata.identifier?.rawValue ?? "",
                metadata.commonKey?.rawValue ?? "",
                metadata.key.map { String(describing: $0) } ?? ""
            ].joined(separator: " ").lowercased()
            guard identifier.contains("creation") else { continue }
            if let date = metadata.dateValue { return date }
            if let string = metadata.stringValue,
               let date = ISO8601DateFormatter().date(from: string) { return date }
        }
        return nil
    }

    private static func gpsLocation(from props: [String: Any], url: URL) -> GPSLocation? {
        if let dict = props["{GPS}"] as? [String: Any], let location = parseGPS(dict) {
            return location
        }
        return gpsFromXMP(url: url)
    }

    private static func parseGPS(_ dict: [String: Any]) -> GPSLocation? {
        guard let lat0 = signedNumber(dict[kCGImagePropertyGPSLatitude as String]),
              let lon0 = signedNumber(dict[kCGImagePropertyGPSLongitude as String]) else { return nil }

        var latitude = lat0
        var longitude = lon0
        let latRef = (dict[kCGImagePropertyGPSLatitudeRef as String] as? String)?
            .trimmingCharacters(in: .whitespaces).uppercased()
        let lonRef = (dict[kCGImagePropertyGPSLongitudeRef as String] as? String)?
            .trimmingCharacters(in: .whitespaces).uppercased()

        if latRef == "S" && latitude > 0 { latitude = -latitude }
        if lonRef == "W" && longitude > 0 { longitude = -longitude }

        guard isValid(latitude: latitude, longitude: longitude) else { return nil }
        var altitude = ImageDecoder.numberValue(dict[kCGImagePropertyGPSAltitude as String])
        if let ref = ImageDecoder.numberValue(dict[kCGImagePropertyGPSAltitudeRef as String]), ref == 1 {
            altitude = altitude.map { -$0 }
        }
        return GPSLocation(latitude: latitude, longitude: longitude,
                           altitude: altitude, source: "EXIF GPS")
    }

    /// DJI XMP 兜底：仅匹配带小数点的十进制赋值形式，避免误读 EXIF 的度分秒字符串。
    private static func gpsFromXMP(url: URL) -> GPSLocation? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2_000_000) else { return nil }
        let text = String(decoding: data, as: UTF8.self)

        guard let latitude = decimalAfterLabels(["drone-dji:GpsLatitude", "GpsLatitude"], in: text),
              let longitude = decimalAfterLabels(["drone-dji:GpsLongitude", "GpsLongitude"], in: text),
              isValid(latitude: latitude, longitude: longitude) else { return nil }

        let altitude = decimalAfterLabels(["drone-dji:AbsoluteAltitude", "AbsoluteAltitude"], in: text)
        return GPSLocation(latitude: latitude, longitude: longitude,
                           altitude: altitude, source: "XMP (DJI)")
    }

    private static func decimalAfterLabels(_ labels: [String], in text: String) -> Double? {
        for label in labels {
            let escaped = NSRegularExpression.escapedPattern(for: label)
            let pattern = escaped + #"\s*=\s*"?([-+]?\d+\.\d+)"?"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: text),
                  let value = Double(text[swiftRange]) else { continue }
            return value
        }
        return nil
    }

    private static func gpsFromVideo(_ asset: AVURLAsset) -> GPSLocation? {
        for metadata in asset.commonMetadata {
            guard let string = metadata.stringValue, string.count >= 10 else { continue }
            // ISO 6709，例如 +39.1234+116.1234+045.000/
            let pattern = #"^\s*([-+]\d+(?:\.\d+)?)([-+]\d+(?:\.\d+)?)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
                  match.numberOfRanges > 2,
                  let latRange = Range(match.range(at: 1), in: string),
                  let lonRange = Range(match.range(at: 2), in: string),
                  let lat = Double(string[latRange]), let lon = Double(string[lonRange]),
                  isValid(latitude: lat, longitude: lon) else { continue }
            return GPSLocation(latitude: lat, longitude: lon, altitude: nil, source: "视频元数据 (ISO 6709)")
        }
        return nil
    }

    private static func isValid(latitude: Double, longitude: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180 else { return false }
        // 部分相机会写入 0/0 占位，视为无有效定位
        return !(abs(latitude) < 1e-7 && abs(longitude) < 1e-7)
    }

    private static func signedNumber(_ value: Any?) -> Double? {
        if let number = ImageDecoder.numberValue(value) { return number }
        guard var string = value as? String else { return nil }
        let suffix = string.trimmingCharacters(in: .whitespaces).last.flatMap { String($0).uppercased() }
        string = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let suffix = suffix, ["N", "S", "E", "W"].contains(suffix) {
            string = String(string.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard var number = Double(string) else { return nil }
        if suffix == "S" || suffix == "W", number > 0 { number = -number }
        return number
    }

    // MARK: - 显示名称与格式化

    private static let groupRank: [String: Int] = [
        "{Exif}": 0, "{TIFF}": 1, "{GPS}": 2, "{ExifAux}": 3, "{IPTC}": 4,
        "{HEIF}": 5, "{JFIF}": 6, "{PNG}": 7
    ]

    private static let groupTitles: [String: String] = [
        "{Exif}": "EXIF 拍摄参数",
        "{TIFF}": "TIFF / 相机信息",
        "{GPS}": "GPS 定位 (原始)",
        "{ExifAux}": "EXIF 辅助信息",
        "{IPTC}": "IPTC 描述信息",
        "{HEIF}": "HEIF / HEIC",
        "{JFIF}": "JPEG / JFIF",
        "{PNG}": "PNG"
    ]

    private static func groupRank(_ key: String) -> Int {
        groupRank[key] ?? 50
    }

    private static func title(for group: String) -> String {
        groupTitles[group] ?? "扩展信息 \(group.trimmingCharacters(in: CharacterSet(charactersIn: "{}")))"
    }

    private static let keyLabels: [String: String] = [
        "DateTimeOriginal": "拍摄时间", "DateTimeDigitized": "数字化时间", "DateTime": "修改时间",
        "OffsetTime": "时区偏移", "OffsetTimeOriginal": "拍摄时区", "SubsecTimeOriginal": "拍摄时间(亚秒)",
        "ExposureTime": "曝光时间", "FNumber": "光圈值", "ISOSpeedRatings": "ISO 感光度",
        "FocalLength": "焦距", "FocalLenIn35mmFilm": "等效 35mm 焦距", "FocalLengthIn35mmFilm": "等效 35mm 焦距",
        "LensModel": "镜头型号", "LensMake": "镜头厂商", "LensSpecification": "镜头规格",
        "Make": "相机厂商", "Model": "相机型号", "BodySerialNumber": "机身序列号",
        "LensSerialNumber": "镜头序列号", "CameraOwnerName": "机主", "Software": "处理软件",
        "ExposureProgram": "曝光程序", "ExposureMode": "曝光模式", "MeteringMode": "测光模式",
        "Flash": "闪光灯", "WhiteBalance": "白平衡", "SceneCaptureType": "场景类型",
        "ShutterSpeedValue": "快门速度(EV)", "ApertureValue": "光圈(EV)", "BrightnessValue": "亮度(EV)",
        "ExposureBiasValue": "曝光补偿", "MaxApertureValue": "最大光圈", "SubjectDistance": "对焦距离",
        "DigitalZoomRatio": "数字变焦", "SensitivityType": "感光度类型",
        "RecommendedExposureIndex": "推荐曝光指数", "LightSource": "光源",
        "PixelXDimension": "像素宽度", "PixelYDimension": "像素高度",
        "Orientation": "方向", "ColorSpace": "色彩空间", "Artist": "作者", "Copyright": "版权",
        "ImageDescription": "图像描述", "UserComment": "用户注释", "HostComputer": "主机",
        "Compression": "压缩方式", "XResolution": "水平分辨率", "YResolution": "垂直分辨率",
        "ResolutionUnit": "分辨率单位", "BitsPerSample": "每样本位数", "SamplesPerPixel": "样本数/像素",
        "PhotometricInterpretation": "光度解释", "PlanarConfiguration": "平面配置",
        "GPSLatitude": "纬度", "GPSLongitude": "经度", "GPSLatitudeRef": "纬度参考",
        "GPSLongitudeRef": "经度参考", "GPSAltitude": "海拔(米)", "GPSAltitudeRef": "海拔参考",
        "GPSTimeStamp": "GPS 时间", "GPSDateStamp": "GPS 日期", "GPSMapDatum": "大地基准",
        "GPSSatellites": "卫星数", "GPSImgDirection": "拍摄方向", "GPSImgDirectionRef": "方向参考",
        "GPSSpeed": "速度", "GPSSpeedRef": "速度单位", "GPSPositioningMethod": "定位方式",
        "GPSStatus": "定位状态", "GPSMeasureMode": "测量模式", "GPSDOP": "精度因子",
        "ProfileName": "色彩配置", "ColorModel": "色彩模型", "Depth": "位深",
        "PixelWidth": "像素宽度", "PixelHeight": "像素高度", "FileSize": "文件大小(字节)",
        "DPIHeight": "DPI 高度", "DPIWidth": "DPI 宽度", "NamedLocation": "地点名称",
        "Caption/Abstract": "标题", "Keywords": "关键词", "City": "城市", "Country": "国家",
        "DateCreated": "创建日期", "DigitalCreationDate": "数字化日期", "ObjectName": "对象名称"
    ]

    private static func label(for key: String) -> String {
        if let label = keyLabels[key] { return label }
        return key
    }

    private static func formatted(key: String, value: Any) -> String {
        if let data = value as? Data {
            return "<二进制数据 \(data.count) 字节>"
        }
        if let array = value as? [Any] {
            return array.map { formatted(key: "", value: $0) }.joined(separator: ", ")
        }
        if let dict = value as? [String: Any] {
            let preview = dict.keys.sorted().prefix(6).map { "\($0)=\(formatted(key: "", value: dict[$0] as Any))" }
            return "{\(preview.joined(separator: ", "))\(dict.count > 6 ? " …" : "")}"
        }
        if let number = ImageDecoder.numberValue(value) {
            return formattedNumber(key: key, number: number)
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "(空)" : trimmed
        }
        if let date = value as? Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: date)
        }
        return String(describing: value)
    }

    private static func formattedNumber(key: String, number: Double) -> String {
        switch key {
        case "ExposureTime":
            if number > 0 && number < 1 { return "1/\(Int((1.0 / number).rounded())) 秒" }
            return "\(clean(number)) 秒"
        case "FNumber", "MaxApertureValue":
            return "f/\(clean(number))"
        case "FocalLength", "FocalLenIn35mmFilm", "FocalLengthIn35mmFilm":
            return "\(clean(number)) mm"
        case "Orientation":
            let names = ["", "正常", "水平翻转", "旋转 180°", "垂直翻转",
                         "转置", "旋转 90°", "横转", "旋转 270°"]
            let index = Int(number)
            return index >= 1 && index <= 8 ? "\(index) (\(names[index]))" : clean(number)
        case "GPSAltitude":
            return "\(clean(number)) m"
        default:
            return clean(number)
        }
    }

    private static func clean(_ number: Double) -> String {
        if number.rounded() == number && abs(number) < 1e15 { return String(Int(number)) }
        return String(format: "%.6g", number)
    }

    static func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func durationString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
