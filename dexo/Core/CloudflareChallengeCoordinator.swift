import Foundation

struct CloudflareChallengeReason: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let readTiming = CloudflareChallengeReason(rawValue: 1 << 0)
    static let generalRequest = CloudflareChallengeReason(rawValue: 1 << 1)
}

/// Persists and consolidates Cloudflare challenge state independently of the
/// screen or request that discovered it. linux.do and its subdomains keep
/// separate entries, while repeat reports for the same site are idempotent.
final class CloudflareChallengeCoordinator {
    static let shared = CloudflareChallengeCoordinator()

    private static let storageKey = "cloudflareChallengeReasonsBySite"
    private static let legacyReadTimingKey = "linuxDoReadTimingsNeedsVerification"

    private let defaults: UserDefaults
    private var reasonsBySite: [String: CloudflareChallengeReason]

    init(defaults: UserDefaults = .standard, migrateLegacyState: Bool = true) {
        self.defaults = defaults
        reasonsBySite = Self.loadReasons(from: defaults)

        if migrateLegacyState,
           defaults.bool(forKey: Self.legacyReadTimingKey),
           let linuxDo = Self.normalizedSite(for: "https://linux.do")
        {
            reasonsBySite[linuxDo, default: []].formUnion(.readTiming)
        }
        if migrateLegacyState,
           defaults.object(forKey: Self.legacyReadTimingKey) != nil
        {
            defaults.removeObject(forKey: Self.legacyReadTimingKey)
            persist()
        }
    }

    var pendingSiteBaseURLs: [String] {
        reasonsBySite
            .filter { !$0.value.isEmpty }
            .map(\.key)
            .sorted()
    }

    var primaryPendingBaseURL: String? {
        pendingSiteBaseURLs.first
    }

    func reasons(for baseURL: String) -> CloudflareChallengeReason {
        guard let site = Self.normalizedSite(for: baseURL) else { return [] }
        return reasonsBySite[site] ?? []
    }

    func requiresVerification(for baseURL: String) -> Bool {
        !reasons(for: baseURL).isEmpty
    }

    func allowsAutomaticRequests(for baseURL: String) -> Bool {
        !requiresVerification(for: baseURL)
    }

    @discardableResult
    func report(_ reason: CloudflareChallengeReason, for baseURL: String) -> Bool {
        guard !reason.isEmpty,
              ForumPolicy.isLinuxDoFamily(baseURL: baseURL),
              let site = Self.normalizedSite(for: baseURL)
        else { return false }

        let previous = reasonsBySite[site] ?? []
        let updated = previous.union(reason)
        guard updated != previous else { return false }
        reasonsBySite[site] = updated
        persistAndNotify(site: site)
        return true
    }

    func clear(_ reason: CloudflareChallengeReason, for baseURL: String) {
        guard !reason.isEmpty,
              let site = Self.normalizedSite(for: baseURL),
              var existing = reasonsBySite[site]
        else { return }

        let previous = existing
        existing.subtract(reason)
        guard existing != previous else { return }
        if existing.isEmpty {
            reasonsBySite.removeValue(forKey: site)
        } else {
            reasonsBySite[site] = existing
        }
        persistAndNotify(site: site)
    }

    func clearAll(for baseURL: String) {
        guard let site = Self.normalizedSite(for: baseURL),
              reasonsBySite.removeValue(forKey: site) != nil
        else { return }
        persistAndNotify(site: site)
    }

    private func persistAndNotify(site: String) {
        persist()
        NotificationCenter.default.post(
            name: .cloudflareChallengeStateDidChange,
            object: self,
            userInfo: ["baseURL": site]
        )
    }

    private func persist() {
        defaults.set(
            reasonsBySite.mapValues(\.rawValue),
            forKey: Self.storageKey
        )
    }

    private static func loadReasons(from defaults: UserDefaults) -> [String: CloudflareChallengeReason] {
        guard let stored = defaults.dictionary(forKey: storageKey) else { return [:] }
        var result: [String: CloudflareChallengeReason] = [:]
        for (site, rawValue) in stored {
            guard let number = rawValue as? NSNumber,
                  let normalized = normalizedSite(for: site)
            else { continue }
            let reasons = CloudflareChallengeReason(rawValue: number.intValue)
            if !reasons.isEmpty {
                result[normalized, default: []].formUnion(reasons)
            }
        }
        return result
    }

    static func normalizedSite(for baseURL: String) -> String? {
        guard let url = URL(string: baseURL),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "https://\(host)\(port)"
    }
}

extension Notification.Name {
    static let cloudflareChallengeStateDidChange = Notification.Name(
        "cloudflareChallengeStateDidChange"
    )
}
