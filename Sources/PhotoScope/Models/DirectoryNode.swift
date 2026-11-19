import Foundation

/// 目录树节点。子目录按需加载（展开时才读取磁盘），避免一次性遍历整个磁盘。
final class DirectoryNode: NSObject {

    let url: URL
    let name: String
    weak var parent: DirectoryNode?

    private var cachedChildren: [DirectoryNode]?

    init(url: URL, displayName: String? = nil, parent: DirectoryNode? = nil) {
        self.url = url
        self.name = displayName ?? FileManager.default.displayName(atPath: url.path)
        self.parent = parent
        super.init()
    }

    var children: [DirectoryNode] {
        if let cached = cachedChildren { return cached }
        let loaded = DirectoryNode.subdirectories(of: url, parent: self)
        cachedChildren = loaded
        return loaded
    }

    var hasChildren: Bool { !children.isEmpty }

    func invalidate() {
        cachedChildren = nil
    }

    static func subdirectories(of directory: URL, parent: DirectoryNode?) -> [DirectoryNode] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey
        ]
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            // 无权限 / 已卸载的卷：作为叶子节点处理，不抛错
            return []
        }

        let directories: [DirectoryNode] = contents.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            guard values.isDirectory == true else { return nil }
            guard values.isPackage != true else { return nil }   // .app / .photoslibrary 等包不展开
            guard values.isHidden != true else { return nil }
            return DirectoryNode(url: url, parent: parent)
        }
        return directories.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
