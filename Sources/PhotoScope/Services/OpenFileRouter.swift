import Foundation

/// Finder「打开方式 / 双击」传入的路径解析。
///
/// Info.plist 里声明了 `public.image` / `public.movie` 的 Viewer 角色，
/// 因此 Launch Services 会把「打开文件」事件发给本程序。程序本身是目录浏览器，
/// 所以要把单个媒体文件换算成「打开它所在的目录，并在列表中定位到这个文件」。
///
/// 纯逻辑，不依赖 AppKit，便于命令行自检。
enum OpenFileRouter {

    struct Request {
        /// 需要作为根目录打开/选中的目录。
        let directory: URL
        /// 若打开的是文件，则是需要在目录中定位的媒体文件；打开目录时为 nil。
        let selectedFile: URL?
    }

    /// - Parameter isDirectory: 由调用方用 FileManager 判定后传入，避免这里做磁盘 I/O。
    /// - Returns: 无法处理（非媒体文件）时返回 nil，AppKit 会据此回绝打开请求。
    static func request(for url: URL, isDirectory: Bool) -> Request? {
        if isDirectory {
            return Request(directory: url.standardizedFileURL, selectedFile: nil)
        }
        guard MediaSupport.kind(of: url) != nil else { return nil }
        return Request(directory: url.deletingLastPathComponent().standardizedFileURL,
                       selectedFile: url.standardizedFileURL)
    }
}
