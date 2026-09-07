import Foundation
import AppKit

final class UpdateManager {
    struct Manifest: Decodable {
        let version: String
        let build: Int
        let downloadURL: String
        let sha256: String?
        let notes: String?

        enum CodingKeys: String, CodingKey {
            case version
            case build
            case downloadURL = "download_url"
            case sha256
            case notes
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
                return "Es ist noch keine Update-Quelle eingerichtet."
            case .invalidFeedURL:
                return "Die Update-URL ist ungültig. Bitte eine HTTPS-Adresse verwenden."
            case .badResponse:
                return "Die Update-Quelle hat keine gültige Antwort geliefert."
            case .invalidManifest:
                return "Die Update-Datei update.json ist ungültig."
            case .invalidDownloadURL:
                return "Die Download-Adresse des Updates ist ungültig."
            case .checksumMismatch:
                return "Die Prüfsumme des Updates stimmt nicht. Das Update wurde aus Sicherheitsgründen abgebrochen."
            case .archiveInvalid:
                return "Das heruntergeladene Update enthält keine gültige Replyzen.app."
            case .bundleMismatch:
                return "Das Update gehört nicht zu Replyzen."
            case .appNotWritable:
                return "Die installierte App kann nicht ersetzt werden. Bitte Replyzen in den Programme-Ordner verschieben und erneut versuchen."
            case .installPreparationFailed(let message):
                return "Das Update konnte nicht vorbereitet werden: \(message)"
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let localSigningIdentity = "Replyzen Local Signing"
    private let feedKey = "Replyzen.UpdateFeedURL"
    private let lastCheckKey = "Replyzen.LastUpdateCheck"

    private let defaultFeedURL = "https://raw.githubusercontent.com/lstoever-bit/Replyzen-Updates/main/update.json"

    var feedURLString: String {
        get {
            let stored = defaults.string(forKey: feedKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultFeedURL : stored
        }
        set {
            let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || cleaned == defaultFeedURL {
                defaults.removeObject(forKey: feedKey)
            } else {
                defaults.set(cleaned, forKey: feedKey)
            }
        }
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

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if markCheckTime {
                self.defaults.set(Date(), forKey: self.lastCheckKey)
            }

            if let error {
                completion(.failure(error))
                return
            }

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data else {
                completion(.failure(UpdateError.badResponse))
                return
            }

            do {
                let manifest = try JSONDecoder().decode(Manifest.self, from: data)
                guard manifest.build > 0, !manifest.version.isEmpty, !manifest.downloadURL.isEmpty, !(manifest.sha256 ?? "").isEmpty else {
                    completion(.failure(UpdateError.invalidManifest))
                    return
                }

                if manifest.build > self.currentBuild {
                    completion(.success(AvailableUpdate(manifest: manifest, feedURL: url)))
                } else {
                    completion(.success(nil))
                }
            } catch {
                completion(.failure(UpdateError.invalidManifest))
            }
        }.resume()
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
        if let absolute = URL(string: update.manifest.downloadURL), absolute.scheme != nil {
            guard absolute.scheme?.lowercased() == "https" else { return nil }
            return absolute
        }

        let base = update.feedURL.deletingLastPathComponent()
        return URL(string: update.manifest.downloadURL, relativeTo: base)?.absoluteURL
    }

    private func sha256(of url: URL) throws -> String {
        let output = try runWithOutput("/usr/bin/shasum", ["-a", "256", url.path])
        guard let first = output.split(whereSeparator: { $0.isWhitespace }).first else {
            throw UpdateError.installPreparationFailed("SHA-256 konnte nicht berechnet werden.")
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
