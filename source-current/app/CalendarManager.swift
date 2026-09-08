import Foundation
import AppKit
import Network
import Security

struct CalendarOption: Identifiable, Equatable {
    let id: String
    let title: String
    let sourceTitle: String
}

final class CalendarManager {
    static let targetEmail = "lennard@minubo.com"
    static let eventTimeZoneIdentifier = "Europe/Berlin"
    static let eventTimeZone = TimeZone(identifier: eventTimeZoneIdentifier) ?? TimeZone(secondsFromGMT: 3600)!

    enum CalendarError: LocalizedError {
        case oauthNotConfigured
        case notConnected
        case authorizationCancelled
        case authorizationFailed(String)
        case wrongAccount(String)
        case invalidResponse
        case selectedCalendarNotFound
        case invalidDates
        case apiError(String)
        case keychainError(OSStatus)

        var errorDescription: String? {
            switch self {
            case .oauthNotConfigured:
                return L10n.source("Google OAuth ist noch nicht eingerichtet. Bitte einmalig Client-ID und Client Secret eines Google-OAuth-Clients vom Typ Desktop-App hinterlegen.")
            case .notConnected:
                return L10n.source("Replyzen ist noch nicht mit Google Calendar verbunden. Bitte zuerst mit lennard@minubo.com anmelden.")
            case .authorizationCancelled:
                return L10n.source("Die Google-Anmeldung wurde abgebrochen.")
            case .authorizationFailed(let message):
                return L10n.source("Google-Anmeldung fehlgeschlagen: {0}", L10n.diagnostic(message))
            case .wrongAccount(let email):
                return L10n.source("Bitte mit lennard@minubo.com anmelden. Angemeldet wurde {0}.", email)
            case .invalidResponse:
                return L10n.source("Google hat eine unerwartete Antwort geliefert.")
            case .selectedCalendarNotFound:
                return L10n.source("Der ausgewählte Google-Kalender ist nicht mehr verfügbar. Bitte einen anderen Kalender wählen.")
            case .invalidDates:
                return L10n.source("Start- und Endzeit des Termins sind ungültig.")
            case .apiError(let message):
                return L10n.source("Google Calendar: {0}", L10n.diagnostic(message))
            case .keychainError(let status):
                return L10n.source("Google-Zugangsdaten konnten nicht im Schlüsselbund gespeichert werden ({0}).", status)
            }
        }
    }

    private enum Key {
        static let clientID = "google.oauth.client_id"
        static let clientSecret = "google.oauth.client_secret"
        static let accessToken = "google.oauth.access_token"
        static let refreshToken = "google.oauth.refresh_token"
        static let expiry = "google.oauth.expiry"
        static let email = "google.oauth.email"
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double?
        let refresh_token: String?
    }

    private struct UserInfo: Decodable {
        let email: String
    }

    private struct CalendarListResponse: Decodable {
        struct Item: Decodable {
            let id: String
            let summary: String
            let accessRole: String?
            let primary: Bool?
        }
        let items: [Item]?
        let nextPageToken: String?
    }

    private struct GoogleErrorEnvelope: Decodable {
        struct Body: Decodable {
            let message: String?
        }
        let error: Body
    }

    private let session = URLSession(configuration: .default)
    private let keychain = GoogleKeychain()
    private let oauthQueue = DispatchQueue(label: "Replyzen.GoogleOAuth")
    private var listener: NWListener?
    private var oauthState: String?
    private var oauthRedirectURI: String?
    private var oauthCompletion: ((Result<String, Error>) -> Void)?

    func isConfigured() -> Bool {
        !(keychain.load(Key.clientID) ?? "").isEmpty && !(keychain.load(Key.clientSecret) ?? "").isEmpty
    }

    func connectedEmail() -> String? {
        let email = keychain.load(Key.email)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (email?.isEmpty == false) ? email : nil
    }

    func disconnect() {
        keychain.delete(Key.accessToken)
        keychain.delete(Key.refreshToken)
        keychain.delete(Key.expiry)
        keychain.delete(Key.email)
    }

    func connect(
        clientID: String,
        clientSecret: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if !trimmedID.isEmpty || !trimmedSecret.isEmpty {
                guard !trimmedID.isEmpty, !trimmedSecret.isEmpty else {
                    completion(.failure(CalendarError.oauthNotConfigured))
                    return
                }
                try keychain.save(trimmedID, key: Key.clientID)
                try keychain.save(trimmedSecret, key: Key.clientSecret)
                disconnect()
            }
        } catch {
            completion(.failure(error))
            return
        }

        guard let storedID = keychain.load(Key.clientID), !storedID.isEmpty,
              let storedSecret = keychain.load(Key.clientSecret), !storedSecret.isEmpty else {
            completion(.failure(CalendarError.oauthNotConfigured))
            return
        }

        oauthQueue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.oauthCompletion = completion
            self.oauthState = UUID().uuidString.replacingOccurrences(of: "-", with: "")

            do {
                let listener = try NWListener(using: .tcp, on: .any)
                self.listener = listener

                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleOAuthConnection(connection, clientID: storedID, clientSecret: storedSecret)
                }

                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener?.port else {
                            self.finishOAuth(.failure(CalendarError.authorizationFailed(L10n.source("Lokaler Callback-Port konnte nicht geöffnet werden."))))
                            return
                        }
                        let redirect = "http://127.0.0.1:\(port.rawValue)/oauth2callback"
                        self.oauthRedirectURI = redirect
                        self.openAuthorizationPage(clientID: storedID, redirectURI: redirect)
                    case .failed(let error):
                        self.finishOAuth(.failure(CalendarError.authorizationFailed(error.localizedDescription)))
                    default:
                        break
                    }
                }

                listener.start(queue: self.oauthQueue)
            } catch {
                self.finishOAuth(.failure(CalendarError.authorizationFailed(error.localizedDescription)))
            }
        }
    }

    func loadCalendarOptions(completion: @escaping (Result<[CalendarOption], Error>) -> Void) {
        withAccessToken { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let token):
                self.loadCalendarPage(accessToken: token, pageToken: nil, accumulated: [], completion: completion)
            }
        }
    }

    func createEvent(
        title: String,
        notes: String,
        start: Date,
        end: Date,
        calendarIdentifier: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard end > start else {
            completion(.failure(CalendarError.invalidDates))
            return
        }
        guard !calendarIdentifier.isEmpty else {
            completion(.failure(CalendarError.selectedCalendarNotFound))
            return
        }

        withAccessToken { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let token):
                var allowed = CharacterSet.urlPathAllowed
                allowed.remove(charactersIn: "/")
                guard let encodedCalendar = calendarIdentifier.addingPercentEncoding(withAllowedCharacters: allowed),
                      let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendar)/events") else {
                    completion(.failure(CalendarError.selectedCalendarNotFound))
                    return
                }

                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                let timezone = Self.eventTimeZoneIdentifier
                let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                var body: [String: Any] = [
                    "summary": title.trimmingCharacters(in: .whitespacesAndNewlines),
                    "start": ["dateTime": formatter.string(from: start), "timeZone": timezone],
                    "end": ["dateTime": formatter.string(from: end), "timeZone": timezone]
                ]
                if !trimmedNotes.isEmpty {
                    body["description"] = trimmedNotes
                }

                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    self.perform(request) { response in
                        switch response {
                        case .success:
                            completion(.success(calendarIdentifier))
                        case .failure(let error):
                            completion(.failure(error))
                        }
                    }
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func openAuthorizationPage(clientID: String, redirectURI: String) {
        guard var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth"),
              let state = oauthState else {
            finishOAuth(.failure(CalendarError.authorizationFailed(L10n.source("OAuth-URL konnte nicht erstellt werden."))))
            return
        }

        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/userinfo.email"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "login_hint", value: Self.targetEmail),
            URLQueryItem(name: "state", value: state)
        ]

        guard let url = components.url else {
            finishOAuth(.failure(CalendarError.authorizationFailed(L10n.source("OAuth-URL konnte nicht erstellt werden."))))
            return
        }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    private func handleOAuthConnection(_ connection: NWConnection, clientID: String, clientSecret: String) {
        connection.start(queue: oauthQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            guard let data, let requestText = String(data: data, encoding: .utf8),
                  let firstLine = requestText.split(separator: "\n").first else {
                self.sendBrowserResponse(connection, success: false, message: L10n.source("Ungültige OAuth-Antwort."))
                return
            }

            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.sendBrowserResponse(connection, success: false, message: L10n.source("Ungültige OAuth-Antwort."))
                return
            }

            let target = String(parts[1])
            guard target.hasPrefix("/oauth2callback") else {
                self.sendBrowserResponse(connection, success: false, message: L10n.source("Replyzen wartet auf die Google-Anmeldung."))
                return
            }

            guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
                self.sendBrowserResponse(connection, success: false, message: L10n.source("Ungültige OAuth-Antwort."))
                return
            }

            let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if let error = values["error"], !error.isEmpty {
                self.sendBrowserResponse(connection, success: false, message: L10n.source("Google-Anmeldung wurde abgebrochen."))
                self.finishOAuth(.failure(CalendarError.authorizationCancelled))
                return
            }

            guard values["state"] == self.oauthState,
                  let code = values["code"], !code.isEmpty,
                  let redirect = self.oauthRedirectURI else {
                self.sendBrowserResponse(connection, success: false, message: L10n.source("OAuth-Prüfung fehlgeschlagen."))
                self.finishOAuth(.failure(CalendarError.authorizationFailed(L10n.source("State oder Autorisierungscode fehlt."))))
                return
            }

            self.sendBrowserResponse(connection, success: true, message: L10n.source("Replyzen ist mit Google Calendar verbunden. Dieses Fenster kann geschlossen werden."))
            self.listener?.cancel()
            self.listener = nil
            self.exchangeAuthorizationCode(code, clientID: clientID, clientSecret: clientSecret, redirectURI: redirect)
        }
    }

    private func sendBrowserResponse(_ connection: NWConnection, success: Bool, message: String) {
        let symbol = success ? "✓" : "!"
        let body = "<html><head><meta charset=\"utf-8\"><title>ReplyZen</title></head><body style=\"font-family:-apple-system;padding:48px;max-width:620px;margin:auto\"><h2>\(symbol) ReplyZen</h2><p>\(L10n.render(message))</p></body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func exchangeAuthorizationCode(_ code: String, clientID: String, clientSecret: String, redirectURI: String) {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            finishOAuth(.failure(CalendarError.authorizationFailed(L10n.source("Token-URL fehlt."))))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData([
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ])

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.finishOAuth(.failure(CalendarError.authorizationFailed(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse, let data, (200..<300).contains(http.statusCode) else {
                self.finishOAuth(.failure(CalendarError.authorizationFailed(self.googleMessage(from: data) ?? L10n.source("Token konnte nicht abgerufen werden."))))
                return
            }
            do {
                let token = try JSONDecoder().decode(TokenResponse.self, from: data)
                try self.storeTokenResponse(token)
                self.fetchUserEmail(accessToken: token.access_token) { result in
                    switch result {
                    case .failure(let error):
                        self.finishOAuth(.failure(error))
                    case .success(let email):
                        guard email.caseInsensitiveCompare(Self.targetEmail) == .orderedSame else {
                            self.disconnect()
                            self.finishOAuth(.failure(CalendarError.wrongAccount(email)))
                            return
                        }
                        do {
                            try self.keychain.save(email, key: Key.email)
                            self.finishOAuth(.success(email))
                        } catch {
                            self.finishOAuth(.failure(error))
                        }
                    }
                }
            } catch {
                self.finishOAuth(.failure(CalendarError.authorizationFailed(L10n.source("Token-Antwort konnte nicht gelesen werden."))))
            }
        }.resume()
    }

    private func fetchUserEmail(accessToken: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else {
            completion(.failure(CalendarError.invalidResponse))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, let data, (200..<300).contains(http.statusCode),
                  let info = try? JSONDecoder().decode(UserInfo.self, from: data) else {
                completion(.failure(CalendarError.invalidResponse))
                return
            }
            completion(.success(info.email))
        }.resume()
    }

    private func withAccessToken(completion: @escaping (Result<String, Error>) -> Void) {
        guard isConfigured() else {
            completion(.failure(CalendarError.oauthNotConfigured))
            return
        }
        guard let refreshToken = keychain.load(Key.refreshToken), !refreshToken.isEmpty else {
            completion(.failure(CalendarError.notConnected))
            return
        }

        let expiry = Double(keychain.load(Key.expiry) ?? "") ?? 0
        if let accessToken = keychain.load(Key.accessToken), !accessToken.isEmpty,
           expiry > Date().timeIntervalSince1970 + 60 {
            completion(.success(accessToken))
            return
        }

        refreshAccessToken(refreshToken, completion: completion)
    }

    private func refreshAccessToken(_ refreshToken: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let clientID = keychain.load(Key.clientID), let clientSecret = keychain.load(Key.clientSecret),
              let url = URL(string: "https://oauth2.googleapis.com/token") else {
            completion(.failure(CalendarError.oauthNotConfigured))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData([
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, let data, (200..<300).contains(http.statusCode) else {
                completion(.failure(CalendarError.apiError(self.googleMessage(from: data) ?? L10n.source("Google-Zugriff muss erneut autorisiert werden."))))
                return
            }
            do {
                let token = try JSONDecoder().decode(TokenResponse.self, from: data)
                try self.storeTokenResponse(token, preserveRefreshToken: refreshToken)
                completion(.success(token.access_token))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func storeTokenResponse(_ token: TokenResponse, preserveRefreshToken: String? = nil) throws {
        try keychain.save(token.access_token, key: Key.accessToken)
        let refresh = token.refresh_token ?? preserveRefreshToken
        if let refresh, !refresh.isEmpty {
            try keychain.save(refresh, key: Key.refreshToken)
        }
        let expiry = Date().timeIntervalSince1970 + (token.expires_in ?? 3600)
        try keychain.save(String(expiry), key: Key.expiry)
    }

    private func loadCalendarPage(
        accessToken: String,
        pageToken: String?,
        accumulated: [CalendarOption],
        completion: @escaping (Result<[CalendarOption], Error>) -> Void
    ) {
        guard var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList") else {
            completion(.failure(CalendarError.invalidResponse))
            return
        }
        var items = [
            URLQueryItem(name: "minAccessRole", value: "writer"),
            URLQueryItem(name: "maxResults", value: "250")
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        components.queryItems = items
        guard let url = components.url else {
            completion(.failure(CalendarError.invalidResponse))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, let data, (200..<300).contains(http.statusCode) else {
                completion(.failure(CalendarError.apiError(self.googleMessage(from: data) ?? L10n.source("Kalender konnten nicht geladen werden."))))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(CalendarListResponse.self, from: data)
                let page = (decoded.items ?? []).map {
                    CalendarOption(id: $0.id, title: $0.summary, sourceTitle: Self.targetEmail)
                }
                let all = accumulated + page
                if let next = decoded.nextPageToken, !next.isEmpty {
                    self.loadCalendarPage(accessToken: accessToken, pageToken: next, accumulated: all, completion: completion)
                } else {
                    let sorted = all.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                    completion(.success(sorted))
                }
            } catch {
                completion(.failure(CalendarError.invalidResponse))
            }
        }.resume()
    }

    private func perform(_ request: URLRequest, completion: @escaping (Result<Data, Error>) -> Void) {
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(CalendarError.invalidResponse))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(CalendarError.apiError(self.googleMessage(from: data) ?? "HTTP \(http.statusCode)")))
                return
            }
            completion(.success(data))
        }.resume()
    }

    private func googleMessage(from data: Data?) -> String? {
        guard let data else { return nil }
        if let envelope = try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data),
           let message = envelope.error.message, !message.isEmpty {
            return message
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let description = object["error_description"] as? String {
            return description
        }
        return String(data: data, encoding: .utf8)?.prefix(240).description
    }

    private func formData(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let text = values
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .sorted()
            .joined(separator: "&")
        return Data(text.utf8)
    }

    private func finishOAuth(_ result: Result<String, Error>) {
        oauthQueue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.oauthState = nil
            self.oauthRedirectURI = nil
            let completion = self.oauthCompletion
            self.oauthCompletion = nil
            completion?(result)
        }
    }
}

private final class GoogleKeychain {
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
