import Foundation

/// 缩略图列表的排序字段。
enum MediaSortKey: String, CaseIterable {
    case fileName
    case captureDate
    case model
    case lens

    var title: String {
        switch self {
        case .fileName: return "文件名"
        case .captureDate: return "拍摄日期及时间"
        case .model: return "相机型号"
        case .lens: return "镜头型号"
        }
    }

    var menuTitle: String {
        switch self {
        case .fileName: return "按文件名"
        case .captureDate: return "按拍摄日期及时间"
        case .model: return "按型号名"
        case .lens: return "按镜头名"
        }
    }
}

enum MediaSortOrder: String, CaseIterable {
    case ascending
    case descending

    var title: String { self == .ascending ? "升序" : "降序" }
    var symbol: String { self == .ascending ? "↑" : "↓" }
}

/// 排序偏好（本机持久化）。右键菜单与主菜单共用同一份设置。
struct MediaSortOptions {

    var key: MediaSortKey
    var order: MediaSortOrder

    static let `default` = MediaSortOptions(key: .fileName, order: .ascending)

    private static let keyDefaults = "PhotoScope.sortKey"
    private static let orderDefaults = "PhotoScope.sortOrder"

    static var current: MediaSortOptions {
        get {
            let key = UserDefaults.standard.string(forKey: keyDefaults)
                .flatMap { MediaSortKey(rawValue: $0) } ?? MediaSortOptions.default.key
            let order = UserDefaults.standard.string(forKey: orderDefaults)
                .flatMap { MediaSortOrder(rawValue: $0) } ?? MediaSortOptions.default.order
            return MediaSortOptions(key: key, order: order)
        }
        set {
            UserDefaults.standard.set(newValue.key.rawValue, forKey: keyDefaults)
            UserDefaults.standard.set(newValue.order.rawValue, forKey: orderDefaults)
        }
    }

    var summary: String { "\(key.title)\(order.symbol)" }
}
