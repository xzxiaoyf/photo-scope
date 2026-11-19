import AppKit
import Foundation

/// 后台生成 + 内存缓存缩略图，保证缩略图条滚动时不会阻塞主线程。
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(
        label: "com.local.photoscope.thumbnails",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 160 * 1024 * 1024
    }

    private func key(for url: URL) -> NSString {
        url.standardizedFileURL.path as NSString
    }

    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: key(for: url))
    }

    /// 旋转、文件替换或删除后让缓存失效，否则缩略图会一直显示旧朝向。
    func invalidate(_ url: URL) {
        cache.removeObject(forKey: key(for: url))
    }

    /// 完成回调始终在主线程执行。
    func image(for item: MediaItem, maxPixel: Int = ImageDecoder.thumbnailMaxPixel,
               completion: @escaping (NSImage?) -> Void) {
        let cacheKey = key(for: item.url)
        if let cached = cache.object(forKey: cacheKey) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        queue.async { [weak self] in
            let image: NSImage? = item.isVideo
                ? ImageDecoder.videoPoster(url: item.url, maxPixel: maxPixel)
                : ImageDecoder.thumbnailNSImage(url: item.url, maxPixel: maxPixel)

            if let image = image {
                let cost = max(1, Int(image.size.width * image.size.height * 4))
                self?.cache.setObject(image, forKey: cacheKey, cost: cost)
            }
            DispatchQueue.main.async { completion(image) }
        }
    }
}
