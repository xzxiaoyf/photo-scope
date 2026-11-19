import AppKit

/// 缩略图右键菜单里可执行的动作。
enum ThumbnailContextAction {
    case rotateClockwise
    case rotateCounterClockwise
    case resetRotation
    case revealInFinder
    case delete
    case saveAsJPEG
    case copyPath
    /// key / order 传 nil 表示保持原值不变
    case sort(key: MediaSortKey?, order: MediaSortOrder?)
    case resetSort
}

/// NSMenuItem.representedObject 需要对象类型，用盒子承载动作与受影响的缩略图下标。
final class ThumbnailContextActionBox: NSObject {
    let action: ThumbnailContextAction
    let indexes: [Int]

    init(action: ThumbnailContextAction, indexes: [Int]) {
        self.action = action
        self.indexes = indexes
    }
}

/// 右键菜单构建（纯函数，便于命令行自检逐项核对结构）。
enum ThumbnailContextMenu {

    static func build(target: AnyObject,
                      action: Selector,
                      indexes: [Int],
                      hasRotation: Bool,
                      containsVideo: Bool) -> NSMenu {
        let menu = NSMenu(title: "照片操作")
        let options = MediaSortOptions.current
        let count = max(1, indexes.count)
        let plural = indexes.count > 1 ? "（\(count) 项）" : ""

        func box(_ value: ThumbnailContextAction) -> ThumbnailContextActionBox {
            ThumbnailContextActionBox(action: value, indexes: indexes)
        }
        func add(_ title: String, _ symbol: String?, _ value: ThumbnailContextAction,
                 enabled: Bool = true, state: NSControl.StateValue = .off) {
            menu.addItem(makeItem(title: title, symbol: symbol, box: box(value),
                                  target: target, action: action,
                                  enabled: enabled, state: state))
        }

        add("顺时针旋转 90°", "rotate.right", .rotateClockwise, enabled: !containsVideo)
        add("逆时针旋转 90°", "rotate.left", .rotateCounterClockwise, enabled: !containsVideo)
        add("恢复原始方向", "arrow.counterclockwise", .resetRotation, enabled: hasRotation)
        menu.addItem(.separator())

        add("在 Finder 中显示", "folder", .revealInFinder)
        add("复制文件路径", "doc.on.clipboard", .copyPath)
        add("移到废纸篓" + plural, "trash", .delete)
        add("另存为 JPG…", "square.and.arrow.down", .saveAsJPEG, enabled: indexes.count == 1)
        menu.addItem(.separator())

        let sortItem = makeItem(title: "排序方式（\(options.summary)）", symbol: "arrow.up.arrow.down",
                                box: nil, target: nil, action: nil, enabled: true, state: .off)
        let sortMenu = NSMenu(title: "排序方式")
        for key in MediaSortKey.allCases {
            sortMenu.addItem(makeItem(title: key.menuTitle,
                                      symbol: symbol(for: key),
                                      box: box(.sort(key: key, order: nil)),
                                      target: target, action: action,
                                      enabled: true,
                                      state: options.key == key ? .on : .off))
        }
        sortMenu.addItem(.separator())
        for order in MediaSortOrder.allCases {
            sortMenu.addItem(makeItem(title: order == .ascending ? "升序排序" : "降序排序",
                                      symbol: order == .ascending ? "arrow.up" : "arrow.down",
                                      box: box(.sort(key: nil, order: order)),
                                      target: target, action: action,
                                      enabled: true,
                                      state: options.order == order ? .on : .off))
        }
        sortMenu.addItem(.separator())
        sortMenu.addItem(makeItem(title: "恢复默认排序", symbol: "arrow.uturn.backward",
                                  box: box(.resetSort), target: target, action: action,
                                  enabled: true, state: .off))
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)
        return menu
    }

    /// 把菜单树转成可读文本，便于命令行核对结构与勾选状态。
    static func describe(_ menu: NSMenu, prefix: String = "") -> [String] {
        var lines: [String] = []
        for item in menu.items {
            if item.isSeparatorItem {
                lines.append(prefix + "────────")
                continue
            }
            let mark = item.state == .on ? "✓" : " "
            let disabled = item.isEnabled ? "" : "  (禁用)"
            lines.append("\(prefix)[\(mark)] \(item.title)\(disabled)")
            if let submenu = item.submenu {
                lines += describe(submenu, prefix: prefix + "    ")
            }
        }
        return lines
    }

    private static func symbol(for key: MediaSortKey) -> String {
        switch key {
        case .fileName: return "doc.text"
        case .captureDate: return "calendar"
        case .model: return "camera"
        case .lens: return "camera.viewfinder"
        }
    }

    private static func makeItem(title: String, symbol: String?,
                                 box: ThumbnailContextActionBox?,
                                 target: AnyObject?, action: Selector?,
                                 enabled: Bool, state: NSControl.StateValue) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = box
        item.isEnabled = enabled
        item.state = state
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            image.size = NSSize(width: 16, height: 16)
            item.image = image
        }
        return item
    }
}

extension MediaSortOptions: Equatable {
    static func == (lhs: MediaSortOptions, rhs: MediaSortOptions) -> Bool {
        lhs.key == rhs.key && lhs.order == rhs.order
    }
}
