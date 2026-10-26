import Foundation
import Security
import LocalAuthentication

/// The menu-bar installation token lives only in the user's login Keychain.
enum TokenStore {
    private static let service = "com.derpmeter.companion"
    private static let account = "menu-bar-token"
    private static let pattern = try! NSRegularExpression(pattern: "^dm_menubar_[0-9a-f]{64}$")

    static func isValid(_ token: String) -> Bool {
        pattern.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil
    }

    static func read() -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            // Never block the app's UI behind an authentication dialog.
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Metadata only. Inaccessible credentials must not be replaced automatically.
    static var containsToken: Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        let result = SecItemCopyMatching(query as CFDictionary, nil)
        return result != errSecItemNotFound
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        guard isValid(token) else { return false }
        delete()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8),
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
