import CryptoKit
import Foundation
import PushCrypto
import SDWebImage
import UIKit

@MainActor
enum ForumNotificationMetadataSynchronizer {
    static func syncAll(database providedDatabase: DatabaseManager? = nil) async {
        let database = providedDatabase ?? .shared
        guard let forums = try? database.fetchAllForums() else { return }
        await sync(forums: forums)
    }

    static func sync(forumID: Int64, database providedDatabase: DatabaseManager? = nil) async {
        let database = providedDatabase ?? .shared
        guard let forums = try? database.fetchAllForums(),
              forums.contains(where: { $0.id == forumID }) else { return }
        await sync(forums: forums)
    }

    private static func sync(forums: [ForumInstance]) async {
        guard let appGroup = Bundle.main.object(forInfoDictionaryKey: "DexoPushAppGroup") as? String,
              let store = try? ForumNotificationMetadataStore(
                appGroupIdentifier: appGroup
              ) else { return }
        let existing = (try? store.loadAll()) ?? []
        let existingByBaseURL = Dictionary(existing.map { ($0.baseURL, $0) }) { _, last in last }
        var updated: [ForumNotificationMetadata] = []

        for forum in forums {
            guard let baseURL = URL(string: forum.baseURL),
                  let domain = baseURL.host else { continue }
            let previous = existingByBaseURL[forum.baseURL]
            let iconSource = forum.iconURL
            var iconFileName = previous?.iconFileName

            if iconSource != previous?.iconSourceURL || !iconExists(previous, in: store) {
                iconFileName = nil
                if let iconSource,
                   let iconURL = URL(string: iconSource, relativeTo: baseURL)?.absoluteURL,
                   let pngData = await downloadPNG(from: iconURL) {
                    let digest = SHA256.hash(data: Data(forum.baseURL.utf8))
                    let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
                    let candidate = name + ".png"
                    if (try? store.saveIcon(pngData, fileName: candidate)) != nil {
                        iconFileName = candidate
                    }
                }
            }
            updated.append(ForumNotificationMetadata(
                name: forum.title,
                baseURL: forum.baseURL,
                domain: domain,
                iconFileName: iconFileName,
                iconSourceURL: iconSource
            ))
        }

        guard (try? store.save(updated)) != nil else { return }
        let referenced = Set(updated.compactMap(\.iconFileName))
        try? store.removeUnreferencedIcons(keeping: referenced)
    }

    private static func iconExists(
        _ metadata: ForumNotificationMetadata?,
        in store: ForumNotificationMetadataStore
    ) -> Bool {
        guard let metadata else { return false }
        do {
            return try store.iconURL(for: metadata) != nil
        } catch {
            return false
        }
    }

    private static func downloadPNG(from url: URL) async -> Data? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        guard let (data, response) = try? await URLSession(configuration: configuration).data(from: url),
              let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode),
              response.url?.scheme?.lowercased() == "https",
              data.count <= 2 * 1024 * 1024,
              let image = SDImageCodersManager.shared.decodedImage(
                with: data,
                options: [
                    .decodeThumbnailPixelSize: NSValue(
                        cgSize: CGSize(width: 384, height: 384)
                    ),
                ]
              ) else { return nil }
        return rasterizedPNG(image)
    }

    private static func rasterizedPNG(_ image: UIImage) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let size = CGSize(width: 192, height: 192)
        let renderer = UIGraphicsImageRenderer(size: size)
        let output = renderer.image { _ in
            let scale = min(size.width / image.size.width, size.height / image.size.height)
            let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(
                x: (size.width - target.width) / 2,
                y: (size.height - target.height) / 2
            )
            image.draw(in: CGRect(origin: origin, size: target))
        }
        return output.pngData()
    }
}
