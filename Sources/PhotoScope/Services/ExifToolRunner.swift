import Foundation

/// exiftool 是可选的运行时外部工具：PhotoScope 自身不链接任何第三方库，
/// 但「原地写入 GPS 到 RAW / HEIC / JPG」需要能修改原始文件元数据，
/// ImageIO 的原地改写会重编码像素且不支持多数 RAW，因此统一交给 exiftool。
///
/// 未安装时 GUI 会明确提示，功能优雅降级（可解析轨迹、可预览，但提交被阻止）。
enum ExifTool {

    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    struct MediaInfo {
        /// EXIF 里的本地墙钟时间（按 UTC 日历构造，用于减去照片时区得到真 UTC）。
        let localWallTime: Date?
        /// exiftool 返回带数字偏移时换算出的真 UTC（视频 QuickTimeUTC）。
        let utcTime: Date?
        let rawTimeString: String?
        let hasGPS: Bool
        let latitude: Double?
        let longitude: Double?
        let altitude: Double?
        let error: String?
    }

    private static let candidatePaths = [
        "/opt/homebrew/bin/exiftool",
        "/usr/local/bin/exiftool",
        "/opt/local/bin/exiftool",
        "/usr/bin/exiftool",
        "/Applications/exiftool/exiftool",
        NSHomeDirectory() + "/bin/exiftool"
    ]

    private static var cachedExecutable: String?
    private static let lock = NSLock()

    /// 查找可执行文件：PATH → 常见安装位置 → 登录 shell 的 PATH。
    static func executablePath() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedExecutable { return cachedExecutable }

        let fm = FileManager.default
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                let path = String(dir) + "/exiftool"
                if fm.isExecutableFile(atPath: path) {
                    cachedExecutable = path
                    return path
                }
            }
        }
        for path in candidatePaths where fm.isExecutableFile(atPath: path) {
            cachedExecutable = path
            return path
        }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "command -v exiftool"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = Pipe()
        do {
            try probe.run()
            probe.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty && fm.isExecutableFile(atPath: path) {
                cachedExecutable = path
                return path
            }
        } catch { /* 保持 nil */ }
        return nil
    }

    static func isAvailable() -> Bool { executablePath() != nil }

    static func version() -> String? {
        let result = run(["-ver"], timeout: 6)
        guard result.exitCode == 0, !result.timedOut else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 同步执行一次 exiftool；调用方放在后台线程。带超时保护。
    static func run(_ arguments: [String], timeout: TimeInterval = 30) -> Result {
        guard let executable = executablePath() else {
            return Result(exitCode: -1, stdout: "", stderr: "找不到 exiftool", timedOut: false)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }
        var timedOut = false
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 1)
        }
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Result(exitCode: process.terminationStatus, stdout: out, stderr: err, timedOut: timedOut)
    }

    // MARK: - 读

    /// 读拍摄时间与已有 GPS。照片优先 DateTimeOriginal，视频加 `-api QuickTimeUTC`。
    static func readMediaInfo(_ url: URL, isVideo: Bool) -> MediaInfo {
        var args = ["-json", "-n",
                    "-DateTimeOriginal", "-CreateDate", "-SubSecDateTimeOriginal",
                    "-GPSLatitude", "-GPSLongitude", "-GPSAltitude"]
        if isVideo { args.insert(contentsOf: ["-api", "QuickTimeUTC"], at: 0) }
        args.append(url.path)
        let result = run(args, timeout: 20)
        guard result.exitCode == 0, !result.timedOut else {
            return MediaInfo(localWallTime: nil, utcTime: nil, rawTimeString: nil,
                             hasGPS: false, latitude: nil, longitude: nil, altitude: nil,
                             error: result.timedOut ? "exiftool 读取超时" : "exiftool 返回码 \(result.exitCode)")
        }
        guard let data = result.stdout.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let info = list.first else {
            return MediaInfo(localWallTime: nil, utcTime: nil, rawTimeString: nil,
                             hasGPS: false, latitude: nil, longitude: nil, altitude: nil,
                             error: "exiftool 输出无法解析")
        }
        if let message = info["Error"] as? String {
            return MediaInfo(localWallTime: nil, utcTime: nil, rawTimeString: nil,
                             hasGPS: false, latitude: nil, longitude: nil, altitude: nil,
                             error: message)
        }

        let raw = firstString(info, ["SubSecDateTimeOriginal", "DateTimeOriginal", "CreateDate"])
        let parsed = raw.flatMap { parseMediaTime($0) }
        let lat = number(info["GPSLatitude"])
        let lon = number(info["GPSLongitude"])
        let hasGPS = lat != nil && lon != nil && (abs(lat ?? 0) > 1e-7 || abs(lon ?? 0) > 1e-7)
        return MediaInfo(
            localWallTime: parsed?.wall,
            utcTime: parsed?.utc,
            rawTimeString: raw,
            hasGPS: hasGPS,
            latitude: lat,
            longitude: lon,
            altitude: number(info["GPSAltitude"]),
            error: nil
        )
    }

    private static func firstString(_ info: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = info[key] {
                let string = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
                if !string.isEmpty { return string }
            }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// 解析 exiftool 时间：`2026:07:28 09:12:45` 或带偏移 `2026:09:26 09:36:02+08:00`。
    /// - `wall`：按 UTC 日历构造的墙钟（供减去照片时区）。
    /// - `utc`：仅当原文带数字偏移时给出真 UTC。
    static func parseMediaTime(_ raw: String) -> (wall: Date, utc: Date?)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(\d{4})[:\-](\d{2})[:\-](\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:[.,]\d+)?\s*([+-]\d{2}:?\d{2}|Z)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 7 else { return nil }
        func intAt(_ i: Int) -> Int? {
            guard let range = Range(match.range(at: i), in: text) else { return nil }
            return Int(text[range])
        }
        guard let y = intAt(1), let mo = intAt(2), let d = intAt(3),
              let h = intAt(4), let mi = intAt(5), let s = intAt(6) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = y; components.month = mo; components.day = d
        components.hour = h; components.minute = mi; components.second = s
        guard let wall = calendar.date(from: components) else { return nil }

        var utc: Date?
        let tokenNSRange = match.range(at: 7)
        if tokenNSRange.location != NSNotFound,
           let range = Range(tokenNSRange, in: text) {
            let token = String(text[range])
            if token.first == "+" || token.first == "-" {
                let body = String(token.dropFirst()).replacingOccurrences(of: ":", with: "")
                let hours = Int(body.prefix(2)) ?? 0
                let minutes = body.count >= 4 ? (Int(body.dropFirst(2).prefix(2)) ?? 0) : 0
                let sign: Double = token.first == "-" ? -1 : 1
                utc = wall.addingTimeInterval(-sign * Double(hours * 3600 + minutes * 60))
            } else {
                utc = wall
            }
        }
        return (wall, utc)
    }

    // MARK: - 写

    /// 生成写入参数（纯函数，供自检断言）。
    /// 负海拔的 Ref 必须用字符串 "Above/Below Sea Level"，数字 1 会被 exiftool 静默忽略。
    /// 视频的 Keys:GPSCoordinates 只接受 "lat lon" 两段，不带海拔。
    static func gpsWriteArguments(point: TrackPoint, isVideo: Bool) -> [String] {
        if isVideo {
            return ["-overwrite_original",
                    String(format: "-Keys:GPSCoordinates=%.6f %.6f", point.latitude, point.longitude)]
        }
        var args = ["-overwrite_original",
                    String(format: "-GPSLatitude=%.6f", abs(point.latitude)),
                    "-GPSLatitudeRef=\(point.latitude >= 0 ? "N" : "S")",
                    String(format: "-GPSLongitude=%.6f", abs(point.longitude)),
                    "-GPSLongitudeRef=\(point.longitude >= 0 ? "E" : "W")"]
        if let altitude = point.altitude {
            args += [String(format: "-GPSAltitude=%.1f", abs(altitude)),
                     "-GPSAltitudeRef=\(altitude >= 0 ? "Above Sea Level" : "Below Sea Level")"]
        }
        return args
    }

    static func writeGPS(_ url: URL, point: TrackPoint, isVideo: Bool) -> (ok: Bool, message: String) {
        var args = gpsWriteArguments(point: point, isVideo: isVideo)
        args.append(url.path)
        let result = run(args, timeout: 60)
        if result.timedOut { return (false, "exiftool 写入超时") }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 0 && !output.lowercased().contains("error") {
            if output.lowercased().contains("nothing to do") {
                return (false, "exiftool 无改动（\(output)）")
            }
            return (true, output.isEmpty ? "已写入" : output)
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return (false, detail.isEmpty ? (output.isEmpty ? "返回码 \(result.exitCode)" : output) : detail)
    }
}
