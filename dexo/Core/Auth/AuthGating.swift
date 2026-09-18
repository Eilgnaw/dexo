import Foundation

protocol AuthGating: AnyObject {
    func requireAuth(then action: @escaping () -> Void)
    func isAuthenticated() -> Bool
    func currentUsername() -> String?
    func performLogout()
    func verifyAuthenticationIfNeeded()
}

extension AuthGating {
    func verifyAuthenticationIfNeeded() {}
}
