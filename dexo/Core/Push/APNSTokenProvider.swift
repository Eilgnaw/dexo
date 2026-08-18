import Foundation
import UIKit
import UserNotifications

@MainActor
final class APNSTokenProvider {
    static let shared = APNSTokenProvider()

    private var currentToken: Data?
    private var waiters: [UUID: CheckedContinuation<Data, Error>] = [:]

    private init() {}

    func requestToken() async throws -> Data {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        )
        guard granted else { throw PushSubscriptionError.permissionDenied }
        UIApplication.shared.registerForRemoteNotifications()
        if let currentToken { return currentToken }

        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.timeout(id: id)
            }
        }
    }

    func didRegister(deviceToken: Data) {
        currentToken = deviceToken
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume(returning: deviceToken) }
    }

    func didFailToRegister(error: Error) {
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: error) }
    }

    private func timeout(id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: PushSubscriptionError.apnsRegistrationTimedOut)
    }
}
