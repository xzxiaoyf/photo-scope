import Foundation

enum MediaScanner {

    /// 扫描单个目录下的媒体文件（默认不递归）。
    static func scan(directory: URL, recursive: Bool = false) -> [MediaItem] {
        if !recursive {
            return items(in: contents(of: directory))
        }

        // 递归扩展点：目录树中勾选「包含子文件夹」时启用。
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isHiddenKey,
            .fileSizeKey, .contentModificationDateKey
        ]
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            urls.append(url)
        }
        return items(in: urls)
    }

    private static func contents(of directory: URL) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isHiddenKey,
            .fileSizeKey, .contentModificationDateKey
        ]
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        return urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return true }
            return values.isDirectory != true && values.isHidden != true
        }
    }

    private static func items(in urls: [URL]) -> [MediaItem] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        var result: [MediaItem] = []
        result.reserveCapacity(urls.count)

        for url in urls {
            guard let kind = MediaSupport.kind(of: url) else { continue }
            let values = try? url.resourceValues(forKeys: keys)
            result.append(MediaItem(
                url: url,
                kind: kind,
                byteCount: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate
            ))
        }

        result.sort { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return result
    }
}
