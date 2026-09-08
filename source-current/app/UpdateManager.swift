import Foundation
import AppKit

final class UpdateManager {
    struct Manifest: Decodable {
        let version: String
        let build: Int
        let downloadURL: String
        let sha256: String?
        let notes: String?
        let notesLocalized: [String: String]?

        var localizedNotes: String {
            if let localized = notesLocalized?[L10n.language.rawValue], !localized.isEmpty { return localized }
            if let notes, !notes.isEmpty { return L10n.render(notes) }
            return L10n.tr("Die neue Version kann jetzt automatisch geladen und installiert werden.")
        }

        enum CodingKeys: String, CodingKey {
            case version
            case build
            case downloadURL = "download_url"
            case sha256
            case notes
            case notesLocalized = "notes_localized"
        }
    }

    struct AvailableUpdate {
        let manifest: Manifest
        let feedURL: URL
    }

    enum UpdateError: LocalizedError {
        case feedNotConfigured
        case invalidFeedURL
        case badResponse
        case invalidManifest
        case invalidDownloadURL
        case checksumMismatch
        case archiveInvalid
        case bundleMismatch
        case appNotWritable
        case installPreparationFailed(String)

        var errorDescription: String? {
            switch self {
            case .feedNotConfigured:
                return L10n.source("Es ist noch keine Update-Quelle eingerichtet.")
            case .invalidFeedURL:
                return L10n.source("Die Update-URL ist ungültig. Bitte eine HTTPS-Adresse verwenden.")
            case .badResponse:
                return L10n.source("Die Update-Quelle hat keine gültige Antwort geliefert.")
            case .invalidManifest:
                return L10n.source("Die Update-Datei update.json ist ungültig.")
            case .invalidDownloadURL:
                return L10n.source("Die Download-Adresse des Updates ist ungültig.")
            case .checksumMismatch:
                return L10n.source("Die Prüfsumme des Updates stimmt nicht. Das Update wurde aus Sicherheitsgründen abgebrochen.")
            case .archiveInvalid:
                return L10n.source("Das heruntergeladene Update enthält keine gültige Replyzen.app.")
            case .bundleMismatch:
                return L10n.source("Das Update gehört nicht zu Replyzen.")
            case .appNotWritable:
                return L10n.source("Die installierte App kann nicht ersetzt werden. Bitte Replyzen in den Programme-Ordner verschieben und erneut versuchen.")
            case .installPreparationFailed(let message):
                return L10n.source("Das Update konnte nicht vorbereitet werden: {0}", L10n.diagnostic(message))
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let localSigningIdentity = "Replyzen Local Signing"
    private let feedKey = "Replyzen.UpdateFeedURL"
    private let lastCheckKey = "Replyzen.LastUpdateCheck"

    private let defaultFeedURL = "https://raw.githubusercontent.com/lstoever-bit/Replyzen-Updates/main/update.json"
    private let githubAPIFeedURL = "https://api.github.com/repos/lstoever-bit/Replyzen-Updates/contents/update.json?ref=main"

    var feedURLString: String {
        get {
            let stored = defaults.string(forKey: feedKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Older Replyzen versions asked users to add cache-busting query strings or
            // versioned update manifests manually. From 1.19 onward all official-feed
            // variants are migrated back to the canonical URL automatically.
            if stored.isEmpty || isOfficialFeedVariant(stored) {
                return defaultFeedURL
            }
            return stored
        }
        set {
            let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || isOfficialFeedVariant(cleaned) {
                defaults.removeObject(forKey: feedKey)
            } else {
                defaults.set(cleaned, forKey: feedKey)
            }
        }
    }

    private func isOfficialFeedVariant(_ raw: String) -> Bool {
        guard let url = URL(string: raw),
              url.host?.lowercased() == "raw.githubusercontent.com" else { return false }
        return url.path.hasPrefix("/lstoever-bit/Replyzen-Updates/") &&
               url.lastPathComponent.lowercased().hasPrefix("update") &&
               url.pathExtension.lowercased() == "json"
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var currentBuild: Int {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return Int(raw) ?? 0
    }

    func shouldAutoCheck(now: Date = Date()) -> Bool {
        guard !feedURLString.isEmpty else { return false }
        guard let last = defaults.object(forKey: lastCheckKey) as? Date else { return true }
        return now.timeIntervalSince(last) >= 12 * 60 * 60
    }

    private struct ManifestCandidate {
        let requestURL: URL
        let feedURL: URL
        let acceptHeader: String?
    }

    private struct GitHubContentsResponse: Decodable {
        let content: String?
        let encoding: String?
    }

    func checkForUpdates(markCheckTime: Bool = true, completion: @escaping (Result<AvailableUpdate?, Error>) -> Void) {
        let raw = feedURLString
        guard !raw.isEmpty else {
            completion(.failure(UpdateError.feedNotConfigured))
            return
        }

        guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
            completion(.failure(UpdateError.invalidFeedURL))
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        let candidates = manifestCandidates(for: url)

        fetchManifestCandidates(candidates, index: 0, session: session, decoded: [], lastError: nil) { [weak self] decoded, lastError in
            guard let self else { return }
            session.finishTasksAndInvalidate()

            if markCheckTime {
                self.defaults.set(Date(), forKey: self.lastCheckKey)
            }

            guard let best = decoded.max(by: { $0.0.build < $1.0.build }) else {
                completion(.failure(lastError ?? UpdateError.badResponse))
                return
            }

            if best.0.build > self.currentBuild {
                completion(.success(AvailableUpdate(manifest: best.0, feedURL: best.1)))
            } else {
                completion(.success(nil))
            }
        }
    }

    private func manifestCandidates(for feedURL: URL) -> [ManifestCandidate] {
        let token = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
        var result = [
            ManifestCandidate(
                requestURL: cacheBustedURL(feedURL, token: token),
                feedURL: feedURL,
                acceptHeader: nil
            )
        ]

        // The official raw.githubusercontent.com feed can occasionally be stale at the
        // CDN edge. Always query GitHub's Contents API as a second independent source
        // and choose the highest build number returned by either endpoint.
        if feedURL.host?.lowercased() == "raw.githubusercontent.com",
           feedURL.path.hasPrefix("/lstoever-bit/Replyzen-Updates/"),
           let apiURL = URL(string: githubAPIFeedURL) {
            result.append(ManifestCandidate(
                requestURL: cacheBustedURL(apiURL, token: token),
                feedURL: URL(string: defaultFeedURL) ?? feedURL,
                acceptHeader: "application/vnd.github.raw+json"
            ))
        }
        return result
    }

    private func fetchManifestCandidates(
        _ candidates: [ManifestCandidate],
        index: Int,
        session: URLSession,
        decoded: [(Manifest, URL)],
        lastError: Error?,
        completion: @escaping ([(Manifest, URL)], Error?) -> Void
    ) {
        guard index < candidates.count else {
            completion(decoded, lastError)
            return
        }

        let candidate = candidates[index]
        var request = URLRequest(url: candidate.requestURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("Replyzen/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if let acceptHeader = candidate.acceptHeader {
            request.setValue(acceptHeader, forHTTPHeaderField: "Accept")
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            var nextDecoded = decoded
            var nextError = lastError

            if let error {
                nextError = error
            } else if let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      let data {
                do {
                    let manifest = try self.decodeManifest(from: data)
                    nextDecoded.append((manifest, candidate.feedURL))
                } catch {
                    nextError = error
                }
            } else {
                nextError = UpdateError.badResponse
            }

            self.fetchManifestCandidates(
                candidates,
                index: index + 1,
                session: session,
                decoded: nextDecoded,
                lastError: nextError,
                completion: completion
            )
        }.resume()
    }

    private func decodeManifest(from data: Data) throws -> Manifest {
        let decoder = JSONDecoder()

        if let manifest = try? decoder.decode(Manifest.self, from: data),
           manifest.build > 0,
           !manifest.version.isEmpty,
           !manifest.downloadURL.isEmpty,
           !(manifest.sha256 ?? "").isEmpty {
            return manifest
        }

        // GitHub may return either raw file bytes or the normal Contents API JSON
        // wrapper depending on media-type handling. Support both forms.
        if let wrapper = try? decoder.decode(GitHubContentsResponse.self, from: data),
           wrapper.encoding?.lowercased() == "base64",
           let content = wrapper.content {
            let compact = content.replacingOccurrences(of: "\n", with: "")
            if let decodedData = Data(base64Encoded: compact),
               let manifest = try? decoder.decode(Manifest.self, from: decodedData),
               manifest.build > 0,
               !manifest.version.isEmpty,
               !manifest.downloadURL.isEmpty,
               !(manifest.sha256 ?? "").isEmpty {
                return manifest
            }
        }

        throw UpdateError.invalidManifest
    }

    func install(_ update: AvailableUpdate, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let downloadURL = resolvedDownloadURL(update) else {
            completion(.failure(UpdateError.invalidDownloadURL))
            return
        }

        URLSession.shared.downloadTask(with: downloadURL) { [weak self] temporaryURL, response, error in
            guard let self else { return }

            if let error {
                completion(.failure(error))
                return
            }

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let temporaryURL else {
                completion(.failure(UpdateError.badResponse))
                return
            }

            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Replyzen-Update-\(UUID().uuidString)", isDirectory: true)
                let archive = root.appendingPathComponent("update.zip")
                let extract = root.appendingPathComponent("extract", isDirectory: true)

                try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: temporaryURL, to: archive)

                let expected = (update.manifest.sha256 ?? "").lowercased()
                let actual = try self.sha256(of: archive).lowercased()
                guard actual == expected else { throw UpdateError.checksumMismatch }

                try self.run("/usr/bin/ditto", ["-x", "-k", archive.path, extract.path])

                guard let appURL = self.findApp(in: extract) else {
                    throw UpdateError.archiveInvalid
                }

                guard let updatedBundle = Bundle(url: appURL),
                      updatedBundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw UpdateError.bundleMismatch
                }

                let updatedBuild = Int(updatedBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
                guard updatedBuild > self.currentBuild else {
                    throw UpdateError.archiveInvalid
                }

                // Sign the downloaded build with the same local identity used for the initial install.
                // This gives every version a stable designated requirement on this Mac, helping macOS
                // preserve Accessibility approval across updates.
                try self.run("/usr/bin/codesign", ["--force", "--deep", "--sign", self.localSigningIdentity, appURL.path])
                try self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])

                let destination = Bundle.main.bundleURL
                let parent = destination.deletingLastPathComponent()
                guard destination.pathExtension == "app", FileManager.default.isWritableFile(atPath: parent.path) else {
                    throw UpdateError.appNotWritable
                }

                try self.prepareInstaller(stagedApp: appURL, destination: destination, updateRoot: root)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func resolvedDownloadURL(_ update: AvailableUpdate) -> URL? {
        let resolved: URL?
        if let absolute = URL(string: update.manifest.downloadURL), absolute.scheme != nil {
            guard absolute.scheme?.lowercased() == "https" else { return nil }
            resolved = absolute
        } else {
            let base = update.feedURL.deletingLastPathComponent()
            resolved = URL(string: update.manifest.downloadURL, relativeTo: base)?.absoluteURL
        }
        guard let resolved else { return nil }
        return cacheBustedURL(resolved, token: "build-\(update.manifest.build)")
    }

    private func cacheBustedURL(_ url: URL, token: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "replyzen_cb" }
        items.append(URLQueryItem(name: "replyzen_cb", value: token))
        components.queryItems = items
        return components.url ?? url
    }

    private func sha256(of url: URL) throws -> String {
        let output = try runWithOutput("/usr/bin/shasum", ["-a", "256", url.path])
        guard let first = output.split(whereSeparator: { $0.isWhitespace }).first else {
            throw UpdateError.installPreparationFailed(L10n.source("SHA-256 konnte nicht berechnet werden."))
        }
        return String(first)
    }

    private func findApp(in directory: URL) -> URL? {
        let fm = FileManager.default
        if let direct = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            if let app = direct.first(where: { $0.pathExtension == "app" }) {
                return app
            }
        }

        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in enumerator where url.pathExtension == "app" {
            enumerator.skipDescendants()
            return url
        }
        return nil
    }

    private func prepareInstaller(stagedApp: URL, destination: URL, updateRoot: URL) throws {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("replyzen-updater-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        set -e
        PID="$1"
        SRC="$2"
        DEST="$3"
        ROOT="$4"
        PARENT="$(dirname "$DEST")"
        NAME="$(basename "$DEST")"
        NEW="$PARENT/.${NAME}.update.$$"
        OLD="$PARENT/.${NAME}.old.$$"

        while /bin/kill -0 "$PID" >/dev/null 2>&1; do
          /bin/sleep 0.2
        done

        /bin/rm -rf "$NEW" "$OLD"
        /usr/bin/ditto "$SRC" "$NEW"
        /usr/bin/xattr -cr "$NEW" >/dev/null 2>&1 || true
        /usr/bin/codesign --verify --deep --strict "$NEW"

        if ! /bin/mv "$DEST" "$OLD"; then
          /usr/bin/open "$DEST" >/dev/null 2>&1 || true
          exit 1
        fi

        if ! /bin/mv "$NEW" "$DEST"; then
          /bin/mv "$OLD" "$DEST" >/dev/null 2>&1 || true
          /usr/bin/open "$DEST" >/dev/null 2>&1 || true
          exit 1
        fi

        /bin/rm -rf "$OLD" "$ROOT"
        /usr/bin/open "$DEST"
        /bin/rm -f "$0"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "\(ProcessInfo.processInfo.processIdentifier)", stagedApp.path, destination.path, updateRoot.path]
        try process.run()
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        try runWithOutput(executable, arguments)
    }

    private func runWithOutput(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpdateError.installPreparationFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
