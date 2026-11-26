import Foundation

enum GPSWriteScope: String {
    case selected
    case all
}

struct GPSWriteOptions {
    var scope: GPSWriteScope = .selected
    var tolerance: TimeInterval = 30
    var photoTimezoneHours: Double = 8
    var overwriteExistingGPS = false
    var backupBeforeWrite = true
    var includeVideo = false
    var xiaomiCorrection = false
    /// 只诊断匹配、不调用 exiftool 写入（自动化验证用）。
    var dryRun = false
}

struct GPSWriteStats {
    var total = 0
    var written = 0
    /// 「仅预览匹配」模式下成功匹配的数量（不计入 written）。
    var matched = 0
    var noMatch = 0
    var noTime = 0
    var skippedExisting = 0
    var errors = 0
    var cancelled = false
    var dryRun = false

    var notWritten: Int { total - (dryRun ? matched : written) }

    var summary: String {
        if dryRun {
            return "总计 \(total) | 可匹配 \(matched) | 不匹配 \(notWritten)"
                + "（无匹配 \(noMatch)、无拍摄时间 \(noTime)、保留原 GPS \(skippedExisting)、失败 \(errors)）"
                + "【仅预览，未写入】"
        }
        return "总计 \(total) | 写入 \(written) | 未写入 \(notWritten)"
            + "（无匹配 \(noMatch)、无拍摄时间 \(noTime)、保留原 GPS \(skippedExisting)、失败 \(errors)）"
    }
}

/// 按拍摄时间匹配轨迹点，把 GPS 原地写回媒体文件。
///
/// 与参考 Python 工具的规则一致：**没有匹配上就不写入**，宁可留空也不写错位置。
/// 这是 PhotoScope 中唯一会修改原始照片的功能，因此默认开启备份，且提交前需二次确认。
enum GPSWriter {

    static let backupDirectoryName = "exif_backup"

    /// 日志文件名带时间戳；文件名与日志行时间统一用北京时间（UTC+8）便于本地查阅。
    static func logFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: Int(GPSTrack.beijingOffsetHours * 3600))
        return "GPS写入日志_\(formatter.string(from: date)).log"
    }

    /// 写入日志文件到媒体所在目录；返回文件 URL。
    @discardableResult
    static func writeLog(_ lines: [String], to directory: URL) -> URL? {
        let url = uniqueLogURL(in: directory)
        let text = lines.joined(separator: "\n") + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func uniqueLogURL(in directory: URL) -> URL {
        let base = logFileName()
        var candidate = directory.appendingPathComponent(base)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = (base as NSString).deletingPathExtension
            candidate = directory.appendingPathComponent("\(name)_\(index).log")
            index += 1
        }
        return candidate
    }

    /// 同步执行整个处理流程；调用方放到后台线程，日志回调自行切主线程。
    /// - Returns: 统计与全部日志行（日志行同时用于落盘 .log）。
    static func process(items: [MediaItem],
                        directory: URL,
                        points: [TrackPoint],
                        options: GPSWriteOptions,
                        log: (String) -> Void,
                        cancelled: () -> Bool) -> (stats: GPSWriteStats, lines: [(Date, String)]) {

        var stats = GPSWriteStats()
        stats.dryRun = options.dryRun
        var lines: [(Date, String)] = []
        func emit(_ message: String) {
            lines.append((Date(), message))
            log(message)
        }

        let targets = items.filter { options.includeVideo || !$0.isVideo }
        stats.total = targets.count

        emit("=== 开始处理 ===")
        emit("目录：\(directory.path)")
        emit("处理范围：\(options.scope == .selected ? "选中的照片" : "当前目录全部照片")"
             + "（\(targets.count) 个文件）")
        emit("轨迹点：\(points.count) 个")
        emit("小米时间修正：\(options.xiaomiCorrection ? "开启（-8 小时）" : "关闭")")
        emit("匹配容差：\(Int(options.tolerance)) 秒    照片时区：UTC+\(String(format: "%g", options.photoTimezoneHours))")
        emit("覆盖已有 GPS：\(options.overwriteExistingGPS ? "是" : "否")"
             + "    写入前备份：\(options.backupBeforeWrite ? "是" : "否")"
             + "    \(options.dryRun ? "【仅诊断，不写入】" : "实际写入")")
        if let version = ExifTool.version() {
            emit("exiftool：\(version)")
        } else {
            emit("⚠ 未检测到 exiftool，无法写入 GPS（请安装 https://exiftool.org/）")
        }

        guard stats.total > 0 else {
            emit("目录里没有可处理的照片文件。")
            return (stats, lines)
        }

        for (offset, item) in targets.enumerated() {
            if cancelled() {
                stats.cancelled = true
                emit("—— 已取消 ——")
                break
            }
            let kind = item.isVideo ? "视频" : "照片"
            emit("[\(offset + 1)/\(targets.count)] \(item.name)（\(kind)）")
            let outcome = processOne(item: item, points: points, options: options, emit: emit)
            switch outcome {
            case .written: stats.written += 1
            case .matched: stats.matched += 1
            case .noMatch: stats.noMatch += 1
            case .noTime: stats.noTime += 1
            case .skippedExisting: stats.skippedExisting += 1
            case .error: stats.errors += 1
            }
        }

        emit(String(repeating: "-", count: 60))
        emit("处理完成：" + stats.summary)
        return (stats, lines)
    }

    private enum Outcome {
        case written, matched, noMatch, noTime, skippedExisting, error
    }

    private static func processOne(item: MediaItem,
                                   points: [TrackPoint],
                                   options: GPSWriteOptions,
                                   emit: (String) -> Void) -> Outcome {
        let info = ExifTool.readMediaInfo(item.url, isVideo: item.isVideo)
        if let error = info.error {
            emit("    ✗ 读取失败：\(error)")
            return .error
        }
        guard let wall = info.localWallTime else {
            emit("    ✗ 未写入（无拍摄时间）")
            return .noTime
        }
        // 照片里的 DateTimeOriginal 是本地墙钟；视频 QuickTimeUTC 已带偏移，直接给出真 UTC。
        let photoUTC = info.utcTime
            ?? wall.addingTimeInterval(-options.photoTimezoneHours * 3600)
        emit("    拍摄时间：\(GPSTrack.string(wall, offset: 0))"
             + "（本地） → \(GPSTrack.utcString(photoUTC))（UTC）")

        guard let match = GPSTrack.nearest(to: photoUTC, in: points) else {
            emit("    ✗ 未写入（轨迹点全部没有时间戳）")
            return .noMatch
        }
        guard match.difference <= options.tolerance else {
            emit("    ✗ 未写入（无匹配：最近轨迹点相差 \(String(format: "%.1f", match.difference))s，"
                 + "超过容差 \(Int(options.tolerance))s）")
            return .noMatch
        }
        let point = match.point
        let coordinate = String(format: "%.6f, %.6f", point.latitude, point.longitude)
        let altitude = point.altitude.map { String(format: "%.1fm", $0) } ?? "无海拔"
        emit("    轨迹(Δ\(String(format: "%.1f", match.difference))s)：\(coordinate)  海拔:\(altitude)")

        if info.hasGPS && !options.overwriteExistingGPS {
            emit("    ⊘ 未写入（已有 GPS，不覆盖模式）")
            if let lat = info.latitude, let lon = info.longitude {
                emit(String(format: "      原 GPS：%.6f, %.6f", lat, lon))
            }
            return .skippedExisting
        }

        if options.dryRun {
            statsDryRunNote(info: info, emit: emit)
            return .matched
        }
        if options.backupBeforeWrite {
            if let backup = makeBackup(for: item.url) {
                emit("      已备份 → \(backup.lastPathComponent)")
            } else {
                emit("      ⚠ 备份失败（仍继续写入）")
            }
        }
        let result = ExifTool.writeGPS(item.url, point: point, isVideo: item.isVideo)
        if result.ok {
            emit("    ✓ 已写入 GPS  \(coordinate)  海拔:\(altitude)")
            if info.hasGPS, let lat = info.latitude, let lon = info.longitude {
                emit(String(format: "      （覆盖原 GPS：%.6f, %.6f）", lat, lon))
            }
            return .written
        }
        emit("    ✗ 写入失败：\(result.message)")
        return .error
    }

    private static func statsDryRunNote(info: ExifTool.MediaInfo, emit: (String) -> Void) {
        _ = info
        emit("    ✓ 匹配成功（诊断模式，未改动文件）")
    }

    /// 备份到媒体文件所在目录下的 `exif_backup/`，绝不覆盖已有备份。
    static func makeBackup(for url: URL) -> URL? {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent().appendingPathComponent(backupDirectoryName)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch { return nil }
        var candidate = folder.appendingPathComponent(url.lastPathComponent)
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            let name = (url.lastPathComponent as NSString).deletingPathExtension
            let ext = url.pathExtension
            candidate = folder.appendingPathComponent(ext.isEmpty
                                                      ? "\(name)_\(index)"
                                                      : "\(name)_\(index).\(ext)")
            index += 1
        }
        do {
            try fm.copyItem(at: url, to: candidate)
            return candidate
        } catch { return nil }
    }
}
