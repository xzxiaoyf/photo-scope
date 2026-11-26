import Foundation

/// 轨迹中的一个定位点。`time` 统一是「真 UTC」的绝对时间点。
struct TrackPoint {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let time: Date?
    /// 文件中的原始时间文本，用于界面预览核对时间口径。
    /// FIT 没有文本时间，这里放由二进制时间戳还原出的 `yyyy-MM-ddTHH:mm:ssZ`。
    let rawTime: String?
    /// FIT 的时间是二进制 uint32（FIT epoch 1989-12-31 UTC），不是文本时间；
    /// 小米「伪 Z」修正只针对文本时间，对这类点必须跳过。
    let timeIsBinary: Bool

    init(latitude: Double, longitude: Double, altitude: Double?,
         time: Date?, rawTime: String?, timeIsBinary: Bool = false) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.time = time
        self.rawTime = rawTime
        self.timeIsBinary = timeIsBinary
    }
}

enum TrackFormat: String {
    case gpx
    case tcx
    case fit
    case unknown
}

struct TrackInfo {
    let format: TrackFormat
    let url: URL
    let total: Int
    let withTime: Int
    let withAltitude: Int
    let minTime: Date?
    let maxTime: Date?
    let duplicateTimes: Int
    /// 文件开头的若干点，用于界面预览。
    let samples: [TrackPoint]
}

enum TrackError: LocalizedError {
    case unsupported(String)
    case unreadable(String)
    case invalidFIT(String)
    case noPoints
    case noTimedPoints

    var errorDescription: String? {
        switch self {
        case .unsupported(let detail): return "不支持的轨迹格式：\(detail)"
        case .unreadable(let detail): return "无法读取轨迹文件：\(detail)"
        case .invalidFIT(let detail): return "FIT 文件无法解析：\(detail)"
        case .noPoints: return "文件里没有解析到有效 GPS 点"
        case .noTimedPoints: return "轨迹点全部没有时间戳，无法按拍摄时间匹配"
        }
    }
}

/// GPX / TCX / FIT 轨迹解析（纯 Foundation，无第三方依赖）。
///
/// 时间口径（与参考 Python 工具 `gps_write_photo_v2.py` 一致）：
/// - 带数字偏移（`+08:00` / `-0500`）→ 按偏移真换算成 UTC；
/// - `Z` 或无后缀 → 当作真 UTC 墙钟；
/// - 勾选「小米修正」时，仅对上述 `Z` / 无后缀的时间再减 8 小时
///   （小米导出的 `09:34:29Z` 其实是北京时间 09:34，真 UTC 应为 01:34）。
/// FIT 是二进制格式：时间戳为 uint32 秒（FIT epoch 1989-12-31 UTC，按规范即 UTC），
/// 不存在文本伪 Z 问题，因此**小米修正对 FIT 一律不生效**；坐标是 semicircles，
/// 需换算成度。解码器见本文件末尾 `FITTrackParser`。
enum GPSTrack {

    static let xiaomiCorrectionHours: Double = 8
    static let previewSampleCount = 3
    static let beijingOffsetHours: Double = 8

    // MARK: - 格式识别

    static func detectFormat(_ url: URL) -> TrackFormat {
        switch url.pathExtension.lowercased() {
        case "gpx": return .gpx
        case "tcx": return .tcx
        case "fit": return .fit
        default: break
        }
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 2048) else { return .unknown }
        try? handle.close()
        // FIT 是二进制：文件头第 8~11 字节固定为 ".FIT"，不依赖扩展名。
        if head.count >= 12 {
            let magic = [UInt8](head.prefix(12))
            if magic[8] == 0x2E && magic[9] == 0x46
                && magic[10] == 0x49 && magic[11] == 0x54 { return .fit }
        }
        let text = String(decoding: head, as: UTF8.self).lowercased()
        if text.contains("trainingcenterdatabase") || text.contains("<activity") { return .tcx }
        if text.contains("<gpx") { return .gpx }
        return .unknown
    }

    // MARK: - 时间解析

    /// 解析 ISO 8601 时间文本 → 真 UTC 的 `Date`。
    /// - Parameter xiaomiCorrection: 是否把伪 `Z` 的北京时间墙钟减 8 小时。
    static func parseTime(_ raw: String, xiaomiCorrection: Bool = false) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = timeRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 8,
              let y = intGroup(match, 1, in: text),
              let mo = intGroup(match, 2, in: text),
              let d = intGroup(match, 3, in: text),
              let h = intGroup(match, 4, in: text),
              let mi = intGroup(match, 5, in: text) else { return nil }

        let s = intGroup(match, 6, in: text) ?? 0
        var fraction = 0.0
        let fractionNSRange = match.range(at: 7)
        if fractionNSRange.location != NSNotFound,
           let fracRange = Range(fractionNSRange, in: text) {
            let digits = String(text[fracRange])
            fraction = Double("0." + digits) ?? 0
        }
        guard (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 61 else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = y
        components.month = mo
        components.day = d
        components.hour = h
        components.minute = mi
        components.second = s
        guard let wallUTC = calendar.date(from: components) else { return nil }

        var result = wallUTC.addingTimeInterval(fraction)
        let tokenNSRange = match.range(at: 8)
        if tokenNSRange.location != NSNotFound,
           let tokenRange = Range(tokenNSRange, in: text) {
            let token = String(text[tokenRange])
            if token.first == "+" || token.first == "-" {
                // 数字偏移：相信文件，按偏移真换算，不受小米修正影响。
                let body = String(token.dropFirst()).replacingOccurrences(of: ":", with: "")
                let hours = Int(body.prefix(2)) ?? 0
                let minutes = body.count >= 4 ? (Int(body.dropFirst(2).prefix(2)) ?? 0) : 0
                let sign: Double = token.first == "-" ? -1 : 1
                return result.addingTimeInterval(-sign * Double(hours * 3600 + minutes * 60))
            }
            // Z / z：真 UTC 墙钟；小米修正时减 8 小时。
        }
        if xiaomiCorrection {
            result = result.addingTimeInterval(-xiaomiCorrectionHours * 3600)
        }
        return result
    }

    private static let timeRegex: NSRegularExpression = {
        let pattern = #"^\s*(\d{4})-(\d{2})-(\d{2})[Tt ]+(\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?\s*(Z|z|[+-]\d{2}(?::?\d{2})?)?\s*$"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static func intGroup(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> Int? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return Int(text[range])
    }

    // MARK: - 格式化（统一 UTC / 北京口径）

    static func utcString(_ date: Date) -> String { string(date, offset: 0) }

    static func beijingString(_ date: Date) -> String { string(date, offset: beijingOffsetHours * 3600) }

    static func string(_ date: Date, offset: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: Int(offset))
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    // MARK: - 加载

    static func load(url: URL, xiaomiCorrection: Bool) throws -> (points: [TrackPoint], info: TrackInfo) {
        let format = detectFormat(url)
        guard format == .gpx || format == .tcx || format == .fit else {
            throw TrackError.unsupported(url.lastPathComponent)
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw TrackError.unreadable(error.localizedDescription)
        }
        if format == .fit && !FITTrackParser.hasValidHeader(data) {
            throw TrackError.invalidFIT("缺少 .FIT 文件头或数据长度异常：\(url.lastPathComponent)")
        }
        let points = parse(data: data, format: format, xiaomiCorrection: xiaomiCorrection)
        guard !points.isEmpty else { throw TrackError.noPoints }
        let info = self.info(for: points, url: url, format: format)
        guard info.withTime > 0 else { throw TrackError.noTimedPoints }
        return (points, info)
    }

    static func info(for points: [TrackPoint], url: URL, format: TrackFormat) -> TrackInfo {
        let timed = points.compactMap(\.time)
        return TrackInfo(
            format: format,
            url: url,
            total: points.count,
            withTime: timed.count,
            withAltitude: points.filter { $0.altitude != nil }.count,
            minTime: timed.min(),
            maxTime: timed.max(),
            duplicateTimes: timed.count - Set(timed).count,
            samples: Array(points.prefix(previewSampleCount))
        )
    }

    /// 同步解析轨迹；调用方负责放到后台线程。
    /// FIT 忽略 `xiaomiCorrection`（二进制时间戳按规范已是 UTC）。
    static func parse(data: Data, format: TrackFormat, xiaomiCorrection: Bool) -> [TrackPoint] {
        switch format {
        case .fit:
            return FITTrackParser.parse(data)
        case .gpx, .tcx:
            let delegate = TrackXMLParser(format: format, xiaomiCorrection: xiaomiCorrection)
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            parser.shouldReportNamespacePrefixes = false
            parser.parse()
            return delegate.points
        case .unknown:
            return []
        }
    }

    // MARK: - 匹配

    /// 返回与给定 UTC 时间最接近的轨迹点及差值秒数；不做容差判断。
    static func nearest(to date: Date, in points: [TrackPoint]) -> (point: TrackPoint, difference: TimeInterval)? {
        var best: TrackPoint?
        var bestDiff = Double.infinity
        for point in points {
            guard let time = point.time else { continue }
            let diff = abs(time.timeIntervalSince(date))
            if diff < bestDiff {
                bestDiff = diff
                best = point
            }
        }
        guard let best else { return nil }
        return (best, bestDiff)
    }

    /// 按时间升序排列，无时间戳的点排到末尾（供二分/日志展示）。
    static func sortedByTime(_ points: [TrackPoint]) -> [TrackPoint] {
        points.sorted { lhs, rhs in
            switch (lhs.time, rhs.time) {
            case (let l?, let r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }
    }
}

// MARK: - XMLParser delegate

private final class TrackXMLParser: NSObject, XMLParserDelegate {
    let format: TrackFormat
    let xiaomiCorrection: Bool
    var points: [TrackPoint] = []

    private var stack: [String] = []
    private var buffer = ""
    private var pendingLat: Double?
    private var pendingLon: Double?
    private var pendingAltitude: Double?
    private var pendingRawTime: String?
    private var hasPendingPoint = false

    init(format: TrackFormat, xiaomiCorrection: Bool) {
        self.format = format
        self.xiaomiCorrection = xiaomiCorrection
    }

    private func local(_ name: String) -> String {
        name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? name
    }

    private var pointElementNames: Set<String> {
        format == .gpx ? ["trkpt", "rtept", "wpt"] : ["Trackpoint"]
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = local(elementName)
        stack.append(name)
        buffer = ""
        guard pointElementNames.contains(name) else { return }
        hasPendingPoint = true
        pendingLat = nil
        pendingLon = nil
        pendingAltitude = nil
        pendingRawTime = nil
        if format == .gpx {
            pendingLat = Double(attributeDict["lat"] ?? "")
            pendingLon = Double(attributeDict["lon"] ?? "")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = local(elementName)
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        let parent = stack.count >= 2 ? stack[stack.count - 2] : ""

        if hasPendingPoint && !text.isEmpty {
            let directChild = pointElementNames.contains(parent)
            if (name == "time" || name == "Time") && (directChild || parent == "Trackpoint") {
                if pendingRawTime == nil { pendingRawTime = text }
            } else if name == "ele" && directChild {
                pendingAltitude = Double(text)
            } else if name == "AltitudeMeters" && (directChild || parent == "Position") {
                pendingAltitude = Double(text)
            } else if name == "LatitudeDegrees" {
                pendingLat = Double(text)
            } else if name == "LongitudeDegrees" {
                pendingLon = Double(text)
            }
        }

        if pointElementNames.contains(name) && hasPendingPoint {
            if let lat = pendingLat, let lon = pendingLon,
               abs(lat) <= 90, abs(lon) <= 180 {
                let raw = pendingRawTime
                points.append(TrackPoint(
                    latitude: lat,
                    longitude: lon,
                    altitude: pendingAltitude,
                    time: raw.flatMap { GPSTrack.parseTime($0, xiaomiCorrection: xiaomiCorrection) },
                    rawTime: raw
                ))
            }
            hasPendingPoint = false
            pendingRawTime = nil
        }
        if !stack.isEmpty { stack.removeLast() }
    }
}

// MARK: - FIT 二进制解码

/// Garmin FIT 轨迹最小解码器（纯 Foundation，零依赖）。
///
/// 只关心 `record` 消息（global message #20）中的字段：
/// - 253 timestamp：uint32 秒，FIT epoch = 1989-12-31 00:00:00 UTC（Unix 631065600）
/// - 0 / 1 position_lat / position_long：sint32 semicircles → 度（× 180 / 2^31）
/// - 2 altitude / 78 enhanced_altitude：scale 5、offset 500 → 米
/// 其余消息按 definition 声明的长度安全跳过；支持 12/14 字节头、大小端、
/// 压缩时间戳头、开发者字段与 FIT 的无效值（全 1 / 有符号最大值）。
/// 这是「够用且可验证」的实现，不是完整 FIT SDK：不解析其它消息类型，也不校验 CRC。
enum FITTrackParser {

    struct ParseResult {
        var validHeader = false
        var points: [TrackPoint] = []
        var definitionCount = 0
        var recordCount = 0
        var compressedTimestampHeaders = 0
        var developerMessages = 0
    }

    private struct Field {
        let number: UInt8
        let size: Int
        let baseType: UInt8
    }

    private struct Definition {
        let globalMessageNumber: UInt16
        let littleEndian: Bool
        let fields: [Field]
        let developerDataBytes: Int
    }

    private struct Message {
        var values: [UInt8: Double] = [:]
        var timestamp: UInt32?
        var hasDeveloperFields = false
    }

    /// 1989-12-31 00:00:00 UTC 的 Unix 时间戳。
    static let fitEpochUnix: TimeInterval = 631_065_600
    private static let semicircleToDegree = 180.0 / 2_147_483_648.0
    private static let recordMessage: UInt16 = 20

    private static func isoString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    static func hasValidHeader(_ data: Data) -> Bool {
        let b = [UInt8](data)
        guard b.count >= 14 else { return false }
        let headerSize = Int(b[0])
        guard headerSize == 12 || headerSize == 14, headerSize <= b.count else { return false }
        guard b[8] == 0x2E && b[9] == 0x46 && b[10] == 0x49 && b[11] == 0x54 else { return false }
        let dataSize = uint32(b, at: 4, little: true)
        return dataSize > 0 && dataSize <= UInt32(b.count - headerSize)
    }

    static func parse(_ data: Data) -> [TrackPoint] { parseDetailed(data).points }

    static func parseDetailed(_ data: Data) -> ParseResult {
        let b = [UInt8](data)
        var result = ParseResult()
        guard hasValidHeader(data) else { return result }
        result.validHeader = true
        let headerSize = Int(b[0])
        let end = headerSize + Int(uint32(b, at: 4, little: true))
        var position = headerSize
        var definitions: [Int: Definition] = [:]
        var lastTimestamp: UInt32?

        while position < end {
            let header = b[position]
            position += 1

            if header & 0x80 != 0 {
                // 压缩时间戳头：bit7=1，bit5~6 为本地消息类型，bit0~4 为时间戳低 5 位偏移。
                result.compressedTimestampHeaders += 1
                let local = Int((header >> 5) & 0x03)
                let offset = UInt32(header & 0x1F)
                var computed: UInt32?
                if let last = lastTimestamp {
                    var value = (last & ~UInt32(0x1F)) | offset
                    if offset < (last & 0x1F) { value &+= 0x20 }
                    computed = value
                }
                guard let definition = definitions[local] else { break }
                let developer = definition.developerDataBytes > 0
                guard var message = readMessage(b, position: &position, end: end,
                                                definition: definition,
                                                hasDeveloperFields: developer,
                                                timestampOverride: computed) else { break }
                if developer { result.developerMessages += 1 }
                if definition.globalMessageNumber == recordMessage { result.recordCount += 1 }
                if let ts = computed { lastTimestamp = ts }
                message.timestamp = computed ?? message.timestamp
                append(message, definition: definition, to: &result)
                continue
            }

            if header & 0x40 != 0 {
                // Definition：reserved(1) + architecture(1) + global msg(2)
                // + field count(1) + n×(number, size, base type) + 可选开发者字段表。
                guard let definition = readDefinition(b, position: &position, end: end,
                                                      hasDeveloperFields: header & 0x20 != 0) else { break }
                definitions[Int(header & 0x0F)] = definition
                result.definitionCount += 1
                continue
            }

            let local = Int(header & 0x0F)
            guard let definition = definitions[local] else { break }
            let developer = header & 0x20 != 0
            guard let message = readMessage(b, position: &position, end: end,
                                            definition: definition,
                                            hasDeveloperFields: developer,
                                            timestampOverride: nil) else { break }
            if developer { result.developerMessages += 1 }
            if definition.globalMessageNumber == recordMessage { result.recordCount += 1 }
            if let ts = message.timestamp { lastTimestamp = ts }
            append(message, definition: definition, to: &result)
        }
        return result
    }

    private static func append(_ message: Message, definition: Definition, to result: inout ParseResult) {
        guard definition.globalMessageNumber == recordMessage,
              let lat = message.values[0], let lon = message.values[1] else { return }
        let latitude = lat * semicircleToDegree
        let longitude = lon * semicircleToDegree
        guard abs(latitude) <= 90, abs(longitude) <= 180 else { return }

        var altitude: Double?
        if let enhanced = message.values[78] {
            altitude = enhanced / 5.0 - 500.0
        } else if let plain = message.values[2] {
            altitude = plain / 5.0 - 500.0
        }
        if let value = altitude, !value.isFinite || abs(value) > 20_000 { altitude = nil }

        let date = message.timestamp.map { Date(timeIntervalSince1970: Double($0) + fitEpochUnix) }
        result.points.append(TrackPoint(
            latitude: latitude, longitude: longitude, altitude: altitude,
            time: date, rawTime: date.map { isoString($0) },
            timeIsBinary: true
        ))
    }

    private static func readDefinition(_ b: [UInt8], position: inout Int, end: Int,
                                       hasDeveloperFields: Bool) -> Definition? {
        guard position + 5 <= end else { return nil }
        position += 1                                   // reserved
        let architecture = b[position]; position += 1   // 0 = little endian, 1 = big endian
        let littleEndian = architecture == 0
        let global = uint16(b, at: position, little: littleEndian); position += 2
        let count = Int(b[position]); position += 1
        guard position + count * 3 <= end else { return nil }
        var fields: [Field] = []
        fields.reserveCapacity(count)
        for _ in 0..<count {
            fields.append(Field(number: b[position], size: Int(b[position + 1]),
                                baseType: b[position + 2]))
            position += 3
        }
        var developerBytes = 0
        if hasDeveloperFields {
            guard position < end else { return nil }
            let devCount = Int(b[position]); position += 1
            guard position + devCount * 3 <= end else { return nil }
            for _ in 0..<devCount {
                developerBytes += Int(b[position + 1])
                position += 3
            }
        }
        return Definition(globalMessageNumber: global, littleEndian: littleEndian,
                          fields: fields, developerDataBytes: developerBytes)
    }

    private static func readMessage(_ b: [UInt8], position: inout Int, end: Int,
                                    definition: Definition,
                                    hasDeveloperFields: Bool,
                                    timestampOverride: UInt32?) -> Message? {
        var message = Message()
        message.hasDeveloperFields = hasDeveloperFields
        for field in definition.fields {
            guard position + field.size <= end else { return nil }
            if let value = numeric(b, start: position, size: field.size,
                                   baseType: field.baseType,
                                   architectureLittleEndian: definition.littleEndian) {
                message.values[field.number] = value
            }
            position += field.size
        }
        if hasDeveloperFields {
            guard position + definition.developerDataBytes <= end else { return nil }
            position += definition.developerDataBytes
        }
        if let override = timestampOverride {
            message.timestamp = override
        } else if let raw = message.values[253],
                  raw >= 0, raw <= Double(UInt32.max), raw.isFinite {
            message.timestamp = UInt32(raw)
        }
        return message
    }

    /// 把字段原始字节解成数值；无效值 / 非数值类型返回 nil（字节仍由调用方跳过）。
    /// 多字节字段一律按 definition 里的 architecture 字节序解读（与 FIT SDK 一致）。
    private static func numeric(_ b: [UInt8], start: Int, size: Int,
                                baseType: UInt8, architectureLittleEndian: Bool) -> Double? {
        guard size > 0, start + size <= b.count else { return nil }
        let raw = Array(b[start..<(start + size)])
        let type = baseType & 0x1F
        let little = architectureLittleEndian
        if raw.allSatisfy({ $0 == 0xFF }) { return nil }                 // 无符号 / 浮点无效值
        if [0x01, 0x03, 0x05, 0x0E].contains(type) && isSignedMax(raw, little: little) {
            return nil                                                    // 有符号无效值
        }
        switch type {
        case 0x00, 0x02, 0x0A, 0x0D:            // enum / uint8 / uint8z / byte
            guard size == 1 else { return nil }
            return Double(raw[0])
        case 0x01:                               // sint8
            guard size == 1 else { return nil }
            return Double(Int8(bitPattern: raw[0]))
        case 0x03:                               // sint16
            guard size == 2 else { return nil }
            return Double(Int16(bitPattern: uint16(raw, at: 0, little: little)))
        case 0x04, 0x0B:                        // uint16 / uint16z
            guard size == 2 else { return nil }
            return Double(uint16(raw, at: 0, little: little))
        case 0x05:                               // sint32
            guard size == 4 else { return nil }
            return Double(Int32(bitPattern: uint32(raw, at: 0, little: little)))
        case 0x06, 0x0C:                        // uint32 / uint32z
            guard size == 4 else { return nil }
            return Double(uint32(raw, at: 0, little: little))
        case 0x08:                               // float32
            guard size == 4 else { return nil }
            let value = Float(bitPattern: uint32(raw, at: 0, little: little))
            return value.isFinite ? Double(value) : nil
        case 0x09:                               // float64
            guard size == 8 else { return nil }
            let value = Double(bitPattern: uint64(raw, at: 0, little: little))
            return value.isFinite ? value : nil
        case 0x0E:                               // sint64
            guard size == 8 else { return nil }
            return Double(Int64(bitPattern: uint64(raw, at: 0, little: little)))
        case 0x0F, 0x10:                        // uint64 / uint64z
            guard size == 8 else { return nil }
            return Double(uint64(raw, at: 0, little: little))
        default:                                 // string / 字节数组等
            return nil
        }
    }

    private static func isSignedMax(_ raw: [UInt8], little: Bool) -> Bool {
        guard raw.count >= 2 else { return raw.first == 0x7F }
        let marker = little ? raw.count - 1 : 0
        for (index, byte) in raw.enumerated() {
            if index == marker {
                if byte != 0x7F { return false }
            } else if byte != 0xFF { return false }
        }
        return true
    }

    private static func uint16(_ b: [UInt8], at index: Int, little: Bool) -> UInt16 {
        guard index + 2 <= b.count else { return 0 }
        return little
            ? UInt16(b[index]) | (UInt16(b[index + 1]) << 8)
            : (UInt16(b[index]) << 8) | UInt16(b[index + 1])
    }

    private static func uint32(_ b: [UInt8], at index: Int, little: Bool) -> UInt32 {
        guard index + 4 <= b.count else { return 0 }
        var value: UInt32 = 0
        if little {
            for offset in (0..<4).reversed() { value = (value << 8) | UInt32(b[index + offset]) }
        } else {
            for offset in 0..<4 { value = (value << 8) | UInt32(b[index + offset]) }
        }
        return value
    }

    private static func uint64(_ b: [UInt8], at index: Int, little: Bool) -> UInt64 {
        guard index + 8 <= b.count else { return 0 }
        var value: UInt64 = 0
        if little {
            for offset in (0..<8).reversed() { value = (value << 8) | UInt64(b[index + offset]) }
        } else {
            for offset in 0..<8 { value = (value << 8) | UInt64(b[index + offset]) }
        }
        return value
    }
}
