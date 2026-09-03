import Foundation

enum ReadTimingReportingStatus: Equatable {
    case enabled
    case disabled
    case verificationRequired
}

/// Per-forum UI/feature toggles that depend on the connected Discourse instance.
/// Centralizes host-specific decisions so call sites don't sprinkle string checks.
enum ForumPolicy {
    /// Hosts where the like affordance should be suppressed in post cells.
    private static let likeButtonSuppressedHosts: Set<String> = []

    /// Hosts where read timing uploads require browser authentication and a
    /// stricter transport policy because repeated POSTs may trigger anti-bot protection.
    nonisolated private static let protectedReadTimingHosts: Set<String> = ["linux.do"]

    /// True when posts on this forum should hide the heart / like button.
    static func hidesLikeButton(baseURL: String) -> Bool {
        matches(baseURL: baseURL, suppressed: likeButtonSuppressedHosts)
    }

    /// True when `/topics/timings` reporting is allowed for the current
    /// forum/authentication combination. Discourse does not accept anonymous
    /// timing uploads; linux.do additionally requires the browser session so
    /// Cloudflare clearance and its matching User-Agent remain usable.
    static func tracksReadTimings(baseURL: String) -> Bool {
        tracksReadTimings(
            baseURL: baseURL,
            authKind: AuthManager.shared.authenticationKind(for: baseURL)
        )
    }

    static func tracksReadTimings(baseURL: String, authKind: ForumAuthKind) -> Bool {
        readTimingReportingStatus(baseURL: baseURL, authKind: authKind) == .enabled
    }

    static func readTimingReportingStatus(baseURL: String) -> ReadTimingReportingStatus {
        readTimingReportingStatus(
            baseURL: baseURL,
            authKind: AuthManager.shared.authenticationKind(for: baseURL)
        )
    }

    static func readTimingReportingStatus(
        baseURL: String,
        authKind: ForumAuthKind
    ) -> ReadTimingReportingStatus {
        guard matches(baseURL: baseURL, suppressed: protectedReadTimingHosts) else {
            return authKind == .anonymous ? .disabled : .enabled
        }
        guard AppSettings.shared.linuxDoReadTimingsEnabled,
              authKind == .webSession
        else { return .disabled }
        return AppSettings.shared.linuxDoReadTimingsNeedsVerification
            ? .verificationRequired
            : .enabled
    }

    nonisolated static func isLinuxDoFamily(baseURL: String) -> Bool {
        matches(baseURL: baseURL, suppressed: protectedReadTimingHosts)
    }

    /// Host check that also matches subdomains (e.g. `meta.linux.do` for `linux.do`).
    nonisolated private static func matches(baseURL: String, suppressed: Set<String>) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return suppressed.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
    }
}
