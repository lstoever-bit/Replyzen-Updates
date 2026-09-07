import Foundation
import Security

final class KeychainStore {
    private let service = "com.lstoever.replyzen"
    private let legacyService = "com.lennard.outlookai"
    private let account = "openai-api-key"

    func loadAPIKey() -> String? {
        if let key = load(from: service) {
            return key
        }

        // One-time migration from the previous Lennard Outlook AI app.
        if let legacyKey = load(from: legacyService) {
            _ = saveAPIKey(legacyKey)
            return legacyKey
        }

        return nil
    }

    @discardableResult
    func saveAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return true
        }

        var add = base
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private func load(from serviceName: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}
