import Foundation

/// 右上区域的三段显示方式。
///
/// - grid：全部照片列表（网格缩略图 + 简要 EXIF）
/// - single：单张大图（程序原有默认视图）
/// - compare：左右并排两张照片
enum ViewMode: String, CaseIterable {
    case grid
    case single
    case compare

    static let storageKey = "PhotoScope.viewMode"

    /// 记住用户上次选择的视图；未设置或损坏时回退到单张。
    static var current: ViewMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: storageKey),
                  let mode = ViewMode(rawValue: raw) else { return .single }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }

    var title: String {
        switch self {
        case .grid: return "全部照片列表"
        case .single: return "单张查看"
        case .compare: return "双张对比"
        }
    }

    var toolTip: String {
        switch self {
        case .grid: return "全部照片列表：网格显示当前目录的所有照片与简要 EXIF"
        case .single: return "单张查看：大图 + 底部缩略图条"
        case .compare: return "双张对比：左右并排显示两张照片，可分别选图"
        }
    }

    var shortcut: String {
        switch self {
        case .grid: return "1"
        case .single: return "2"
        case .compare: return "3"
        }
    }
}
