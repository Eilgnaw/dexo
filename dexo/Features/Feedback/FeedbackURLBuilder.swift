import Darwin
import Foundation
import UIKit

enum FeedbackURLBuilder {
    struct Context: Equatable {
        enum Theme: String {
            case light
            case dark
        }

        let packageIdentifier: String
        let deviceIdentifier: String
        let appVersion: String
        let osVersion: String
        let model: String
        let language: String
        let theme: Theme

        static func current(
            userInterfaceStyle: UIUserInterfaceStyle,
            bundle: Bundle = .main,
            deviceIdentifierStore: FeedbackDeviceIdentifierStore = .shared
        ) -> Context {
            Context(
                packageIdentifier: bundle.bundleIdentifier ?? "com.eilgnaw.dexo",
                deviceIdentifier: deviceIdentifierStore.deviceIdentifier(),
                appVersion: bundle.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "unknown",
                osVersion: UIDevice.current.systemVersion,
                model: hardwareModel,
                language: languageCode(for: preferredLocalization(in: bundle)),
                theme: theme(for: userInterfaceStyle)
            )
        }

        static func languageCode(for localization: String) -> String {
            localization.lowercased().hasPrefix("zh") ? "zh" : "en"
        }

        static func theme(for userInterfaceStyle: UIUserInterfaceStyle) -> Theme {
            userInterfaceStyle == .dark ? .dark : .light
        }

        private static func preferredLocalization(in bundle: Bundle) -> String {
            bundle.preferredLocalizations.first
                ?? Locale.current.language.languageCode?.identifier
                ?? "en"
        }

        private static var hardwareModel: String {
            #if targetEnvironment(simulator)
            if let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
               !simulatorModel.isEmpty {
                return simulatorModel
            }
            #endif

            var systemInfo = utsname()
            uname(&systemInfo)
            return withUnsafePointer(to: &systemInfo.machine) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
        }
    }

    enum BuildError: Error {
        case invalidBaseURL
    }

    static func makeURL(context: Context) throws -> URL {
        guard var components = URLComponents(string: "https://feedback.umiibo.app/") else {
            throw BuildError.invalidBaseURL
        }
        let queryItems = [
            URLQueryItem(name: "pkg", value: context.packageIdentifier),
            URLQueryItem(name: "device_id", value: context.deviceIdentifier),
            URLQueryItem(name: "app_version", value: context.appVersion),
            URLQueryItem(name: "os", value: "ios"),
            URLQueryItem(name: "os_version", value: context.osVersion),
            URLQueryItem(name: "model", value: context.model),
            URLQueryItem(name: "lang", value: context.language),
            URLQueryItem(name: "theme", value: context.theme.rawValue),
        ]
        components.percentEncodedQueryItems = queryItems.map { item in
            URLQueryItem(
                name: percentEncode(item.name),
                value: item.value.map(percentEncode)
            )
        }
        guard let url = components.url else {
            throw BuildError.invalidBaseURL
        }
        return url
    }

    nonisolated private static func percentEncode(_ value: String) -> String {
        let unreserved = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~")
        )
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
