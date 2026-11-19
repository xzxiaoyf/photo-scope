import Foundation
import UniformTypeIdentifiers

enum MediaKind: String {
    case image
    case video
}

/// 目录中的一个可浏览媒体文件（照片或视频）。
struct MediaItem: Hashable {
    let url: URL
    let kind: MediaKind
    let byteCount: Int64
    let modifiedAt: Date?

    var name: String { url.lastPathComponent }
    var isVideo: Bool { kind == .video }
}

/// 支持格式清单。
///
/// 判定顺序：显式扩展名白名单 → UTType 一致性判定。
/// 显式清单是为了保证各家相机 RAW 扩展名（ImageIO 能解码但 UTType 未必注册）都能被识别；
/// UTType 兜底则覆盖未来系统新增的格式。
enum MediaSupport {

    static let imageExtensions: Set<String> = [
        // 常规格式
        "jpg", "jpeg", "jpe", "jfif", "png", "tif", "tiff", "gif", "bmp", "webp", "psd", "ico",
        // HEIF / AVIF 家族
        "heic", "heif", "hif", "avif", "avifs",
        // 相机 RAW
        "arw", "srf", "sr2", "nef", "nrw", "cr2", "cr3", "crw", "dng", "raw",
        "rw2", "raf", "orf", "pef", "ptx", "srw", "3fr", "fff", "iiq", "rwz",
        "mos", "mrw", "x3f", "erf", "mef", "dcr", "k25", "kdc", "bay", "rwl",
        "rw1", "r3d", "sti", "nks", "mfw", "dcs", "drf", "eip", "cap", "dsc"
    ]

    /// 仅列出 AVFoundation 在 macOS 上可稳定解码的封装格式。
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mts", "m2ts", "ts", "avi", "mpg", "mpeg",
        "3gp", "3g2", "vob", "hevc", "h264", "qt", "m4p"
    ]

    /// 常见的非媒体旁路文件，避免被 UTType 兜底误判。
    private static let excludedExtensions: Set<String> = [
        "dop", "xmp", "aae", "json", "xml", "plist", "txt", "gpx", "tcx",
        "fit", "db", "lrv", "thm", "ths", "pdf", "zip", "dmg", "app",
        "mkv", "webm", "flv", "wmv", "rmvb"
    ]

    static func kind(of url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, !excludedExtensions.contains(ext) else { return nil }

        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }

        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .video }
        if type.conforms(to: .image) { return .image }
        return nil
    }
}
