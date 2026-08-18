import Foundation
import Security
import UIKit

/// Persists the anonymous identifier used to associate feedback submitted by
/// the same installation. Keychain storage deliberately survives WebKit cache
/// clearing and, in the usual case, an app reinstall.
final class FeedbackDeviceIdentifierStore {
    static let shared = FeedbackDeviceIdentifierStore()

    private let service: String
    private let account: String
    private let vendorIdentifierProvider: () -> UUID?
    private let runtimeFallback: String

    init(
        service: String = "com.eilgnaw.dexo.feedbackDeviceIdentifier",
        account: String = "anonymous-device",
        vendorIdentifierProvider: @escaping () -> UUID? = {
            UIDevice.current.identifierForVendor
        },
        runtimeFallback: String = UUID().uuidString
    ) {
        self.service = service
        self.account = account
        self.vendorIdentifierProvider = vendorIdentifierProvider
        self.runtimeFallback = runtimeFallback
    }

    func deviceIdentifier() -> String {
        if let storedIdentifier = readStoredIdentifier() {
            return storedIdentifier
        }

        let identifier = UUID().uuidString
        if persist(identifier) {
            return identifier
        }

        return vendorIdentifierProvider()?.uuidString ?? runtimeFallback
    }

    private func readStoredIdentifier() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let identifier = String(data: data, encoding: .utf8),
              !identifier.isEmpty else { return nil }
        return identifier
    }

    private func persist(_ identifier: String) -> Bool {
        let itemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(identifier.utf8)

        let updateStatus = SecItemUpdate(
            itemQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = itemQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return true
        }
        guard addStatus == errSecDuplicateItem else { return false }

        return SecItemUpdate(
            itemQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        ) == errSecSuccess
    }
}
