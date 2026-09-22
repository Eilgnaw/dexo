import SDWebImage
import WebKit

final class ImageCacheManager {
    static let shared = ImageCacheManager()
    nonisolated static let maxAnimatedDownloadBytes: Int64 = 64 * 1024 * 1024
    nonisolated static let contentAnimationMaxBufferBytes = 12 * 1024 * 1024
    nonisolated static let fullScreenAnimationMaxBufferBytes = 32 * 1024 * 1024

    /// User avatars & flair badges — moderate retention.
    let avatarCache: SDImageCache
    /// Custom Discourse emoji & reaction images — long retention.
    let emojiCache: SDImageCache
    /// Post content images, onebox cards, video thumbnails — short retention.
    let contentCache: SDImageCache

    /// SDWebImage context dictionaries for each cache type.
    let avatarContext: [SDWebImageContextOption: Any]
    let emojiContext: [SDWebImageContextOption: Any]
    let contentContext: [SDWebImageContextOption: Any]
    let fullScreenContentContext: [SDWebImageContextOption: Any]
    let animatedContentContext: [SDWebImageContextOption: Any]
    let fullScreenAnimatedContentContext: [SDWebImageContextOption: Any]

    private init() {
        avatarCache = SDImageCache(namespace: "avatars")
        emojiCache = SDImageCache(namespace: "emoji")
        contentCache = SDImageCache(namespace: "content")

        avatarCache.config.maxDiskAge = 7 * 24 * 60 * 60       // 7 days
        emojiCache.config.maxDiskAge = 90 * 24 * 60 * 60       // 90 days
        contentCache.config.maxDiskAge = 3 * 24 * 60 * 60      // 3 days

        // Memory caps. SDImageCache otherwise relies on NSCache + system
        // memory-pressure heuristics, which let an animated emoji set in a
        // long topic (~400 unique GIFs × ~475 KiB decoded each = 180+ MiB)
        // sit in RAM until iOS asks for memory. Hard caps stop the in-memory
        // working set from tracking the full topic length.
        emojiCache.config.maxMemoryCost = 30 * 1024 * 1024        // 30 MiB
        emojiCache.config.maxMemoryCount = 150
        contentCache.config.maxMemoryCost = 50 * 1024 * 1024      // 50 MiB
        contentCache.config.maxMemoryCount = 80
        avatarCache.config.maxMemoryCost = 30 * 1024 * 1024       // 30 MiB
        avatarCache.config.maxMemoryCount = 1500

        // A nonzero thumbnail size makes SDImageSVGCoder rasterize SVGs instead
        // of creating a vector UIImage. The vector path can crash inside
        // CoreSVG while SDWebImage validates the image on a background queue.
        // These are pixel bounds (not points) and preserve the aspect ratio.
        avatarContext = [
            .imageCache: avatarCache,
            .imageThumbnailPixelSize: NSValue(cgSize: CGSize(width: 512, height: 512)),
        ]
        emojiContext = [
            .imageCache: emojiCache,
            .imageThumbnailPixelSize: NSValue(cgSize: CGSize(width: 256, height: 256)),
        ]
        contentContext = [
            .imageCache: contentCache,
            .imageThumbnailPixelSize: NSValue(cgSize: CGSize(width: 2048, height: 2048)),
        ]
        fullScreenContentContext = [
            .imageCache: contentCache,
            .imageThumbnailPixelSize: NSValue(cgSize: CGSize(width: 4096, height: 4096)),
        ]

        // Animated images keep their compressed source data plus a decoded
        // frame buffer. Give them a smaller per-frame pixel ceiling than
        // static images, keep decoded results out of the shared memory cache,
        // and reject responses that declare an unreasonable payload size.
        // Unknown/chunked lengths are also stopped by the progress callbacks
        // at each call site once they cross the same byte limit.
        let animatedResponseModifier = SDWebImageDownloaderResponseModifier { response in
            let length = response.expectedContentLength
            guard length < 0 || length <= Self.maxAnimatedDownloadBytes else { return nil }
            return response
        }
        animatedContentContext = [
            .imageCache: contentCache,
            .imageThumbnailPixelSize: NSValue(cgSize: CGSize(width: 1536, height: 1536)),
            .queryCacheType: SDImageCacheType.disk.rawValue,
            .storeCacheType: SDImageCacheType.disk.rawValue,
            .downloadResponseModifier: animatedResponseModifier,
        ]
        fullScreenAnimatedContentContext = [
            .imageCache: contentCache,
            .imageThumbnailPixelSize: NSValue(cgSize: CGSize(width: 2048, height: 2048)),
            .queryCacheType: SDImageCacheType.disk.rawValue,
            .storeCacheType: SDImageCacheType.disk.rawValue,
            .downloadResponseModifier: animatedResponseModifier,
        ]
    }

    struct CacheInfo {
        let name: String
        let count: UInt
        let bytes: UInt
    }

    /// Calculate sizes for all three caches.
    func calculateSizes(completion: @escaping ([CacheInfo]) -> Void) {
        let group = DispatchGroup()
        var results: [CacheInfo] = Array(repeating: CacheInfo(name: "", count: 0, bytes: 0), count: 3)

        group.enter()
        avatarCache.calculateSize { count, size in
            results[0] = CacheInfo(name: "avatar", count: count, bytes: size)
            group.leave()
        }

        group.enter()
        emojiCache.calculateSize { count, size in
            results[1] = CacheInfo(name: "emoji", count: count, bytes: size)
            group.leave()
        }

        group.enter()
        contentCache.calculateSize { count, size in
            results[2] = CacheInfo(name: "content", count: count, bytes: size)
            group.leave()
        }

        group.notify(queue: .main) {
            completion(results)
        }
    }

    /// Clear all image caches, URLCache, WKWebView data, and stale Caches dir entries.
    func clearAll(completion: @escaping () -> Void) {
        let group = DispatchGroup()

        // Image caches (three namespaced + legacy shared)
        for cache in [avatarCache, emojiCache, contentCache, SDImageCache.shared] {
            cache.clearMemory()
            group.enter()
            cache.clearDisk { group.leave() }
        }

        // URLCache (HTTP response cache)
        URLCache.shared.removeAllCachedResponses()

        // WKWebView data (localStorage, IndexedDB, disk cache, cookies, etc.)
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        group.enter()
        WKWebsiteDataStore.default().removeData(
            ofTypes: dataTypes,
            modifiedSince: .distantPast
        ) { group.leave() }

        // Sweep remaining files in Library/Caches/ and tmp/
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            if let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
                if let contents = try? fm.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: nil) {
                    for item in contents {
                        try? fm.removeItem(at: item)
                    }
                }
            }
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            if let contents = try? fm.contentsOfDirectory(at: tmpURL, includingPropertiesForKeys: nil) {
                for item in contents {
                    try? fm.removeItem(at: item)
                }
            }
            group.leave()
        }
        group.enter()

        group.notify(queue: .main, execute: completion)
    }
}

// MARK: - Convenience

extension UIImageView {
    func sd_setImage(with url: URL?, context: [SDWebImageContextOption: Any]) {
        sd_setImage(with: url, placeholderImage: nil, options: [], context: context)
    }
}
