import Foundation
import OSLog

enum TopicTimingDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.eilgnaw.dexo",
        category: "TopicTiming"
    )

    static func log(_ message: String) {
        // Messages deliberately contain only request metadata. Authentication
        // values (Cookie, User-Agent, CSRF) are logged as presence booleans.
        logger.info("\(message, privacy: .public)")
    }
}

/// Builds the linux.do read-timing request in the same deterministic shape as
/// Discourse's browser client. Authentication cookies, the browser User-Agent,
/// and the CSRF token are attached later by `DiscourseAuthInterceptor`.
enum TopicTimingRequestBuilder {
    static func makeRequest(baseURL: String, batch: TopicTimingBatch) -> URLRequest? {
        guard let url = URL(string: baseURL + DiscourseRouter.topicTimings.path),
              let origin = origin(for: url)
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(formBody(for: batch).utf8)

        // Match the explicit headers ArkDO captured from Discourse's browser
        // request. Fetch Metadata and Origin/Referer are normally synthesized
        // by a browser; URLSession needs them supplied explicitly.
        request.setValue(
            "application/x-www-form-urlencoded; charset=UTF-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("true", forHTTPHeaderField: "X-SILENCE-LOGGER")
        request.setValue("true", forHTTPHeaderField: "Discourse-Background")
        request.setValue("true", forHTTPHeaderField: "Discourse-Present")
        request.setValue("true", forHTTPHeaderField: "Discourse-Logged-In")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(topicReferrer(baseURL: baseURL, topicId: batch.topicId), forHTTPHeaderField: "Referer")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    static func formBody(for batch: TopicTimingBatch) -> String {
        var parts = batch.timings.keys.sorted().compactMap { postNumber -> String? in
            guard let milliseconds = batch.timings[postNumber] else { return nil }
            return "timings%5B\(postNumber)%5D=\(milliseconds)"
        }
        // Preserve the browser payload order: timings, topic_time, topic_id.
        parts.append("topic_time=\(batch.topicTime)")
        parts.append("topic_id=\(batch.topicId)")
        return parts.joined(separator: "&")
    }

    private static func topicReferrer(baseURL: String, topicId: Int) -> String {
        "\(baseURL)/t/topic/\(topicId)"
    }

    private static func origin(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}
