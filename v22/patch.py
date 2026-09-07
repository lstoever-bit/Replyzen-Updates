from pathlib import Path

root = Path(__import__('sys').argv[1])

p = root / 'app' / 'CalendarManager.swift'
s = p.read_text()
marker = 'private final class GoogleKeychain {'
if marker not in s:
    raise SystemExit('GoogleKeychain class not found')
prefix = s.rsplit(marker, 1)[0]
replacement = r'''private final class GoogleKeychain {
    // New layout: all Google OAuth values live in ONE Keychain item.  The old
    // implementation created a separate protected item for every value, which
    // could make macOS show several almost identical "Allow" dialogs in a row.
    private let service = "com.lstoever.replyzen.google.v2"
    private let account = "oauth-bundle"
    private let legacyService = "com.lstoever.replyzen.google"
    private let migrationDisabledKey = "Replyzen.GoogleKeychainV2.LegacyDisabled"

    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var bundleLoaded = false

    func load(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        ensureBundleLoaded()
        if let value = cache[key], !value.isEmpty {
            return value
        }

        // One-time compatibility path for existing installations. Each legacy
        // value that is successfully read is immediately copied into the single
        // v2 bundle, so the old per-item prompts disappear after migration.
        guard !UserDefaults.standard.bool(forKey: migrationDisabledKey),
              let legacy = legacyLoad(key), !legacy.isEmpty else {
            return nil
        }

        cache[key] = legacy
        try? saveBundle()
        markLegacyMigrationCompleteIfPossible()
        return legacy
    }

    func save(_ value: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }

        ensureBundleLoaded()
        cache[key] = value
        try saveBundle()
        markLegacyMigrationCompleteIfPossible()
    }

    func delete(_ key: String) {
        lock.lock()
        defer { lock.unlock() }

        ensureBundleLoaded()
        cache.removeValue(forKey: key)
        try? saveBundle()

        // A delete is intentional (for example "Trennen"). Never resurrect an
        // old token from the legacy keychain afterwards.
        UserDefaults.standard.set(true, forKey: migrationDisabledKey)
        legacyDelete(key)
    }

    private func ensureBundleLoaded() {
        guard !bundleLoaded else { return }
        bundleLoaded = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        cache = decoded
    }

    private func saveBundle() throws {
        let data = try JSONEncoder().encode(cache)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CalendarManager.CalendarError.keychainError(updateStatus)
        }

        var add = base
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CalendarManager.CalendarError.keychainError(addStatus)
        }
    }

    private func legacyLoad(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func legacyDelete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func markLegacyMigrationCompleteIfPossible() {
        let essentials = [
            "google.oauth.client_id",
            "google.oauth.client_secret",
            "google.oauth.refresh_token",
            "google.oauth.email"
        ]
        if essentials.allSatisfy({ !(cache[$0] ?? "").isEmpty }) {
            UserDefaults.standard.set(true, forKey: migrationDisabledKey)
        }
    }
}
'''
p.write_text(prefix + replacement)

# Version bump.
p = root / 'app' / 'Info.plist'
s = p.read_text()
s = s.replace('<string>1.11.0</string>', '<string>1.12.0</string>', 1)
s = s.replace('<string>12</string>', '<string>13</string>', 1)
p.write_text(s)

# Version-specific package and notes.
p = root / 'Build-CI.sh'
s = p.read_text()
s = s.replace('Replyzen-update-1.11.zip', 'Replyzen-update-1.12.zip')
s = s.replace(
    'Replyzen 1.11: Fenstergröße passt sich automatisch an Inhalt, Modus und verfügbare Bildschirmfläche an; Scroll-Fallback verhindert abgeschnittene Buttons.',
    'Replyzen 1.12: Google-Schlüsselbundzugriff auf einen einzigen Eintrag konsolidiert; wiederholte macOS-Zugriffsabfragen werden nach einmaliger Migration vermieden.'
)
p.write_text(s)
