// Appended to the unchanged production UpdateManager.swift by native-update CI.
import Foundation
import AppKit

extension UpdateManager {
    static func checkNativeUpdateCompatibility(manifestURL: URL) throws {
        let manager = UpdateManager()
        let data = try Data(contentsOf: manifestURL)
        let manifest = try manager.decodeManifest(from: data)
        precondition(manifest.version == "2.0.0" && manifest.build == 200)
        let wrapped = try JSONSerialization.data(withJSONObject: [
            "encoding": "base64", "content": data.base64EncodedString(options: .lineLength64Characters)
        ])
        let wrappedManifest = try manager.decodeManifest(from: wrapped)
        precondition(wrappedManifest.build == 200)
        let feed = URL(string: manager.defaultFeedURL)!
        let update = AvailableUpdate(manifest: manifest, feedURL: feed)
        let resolved = manager.resolvedDownloadURL(update)!
        precondition(resolved.scheme == "https")
        precondition(resolved.host == "raw.githubusercontent.com")
        precondition(resolved.path == "/lstoever-bit/Replyzen-Updates/main/Replyzen-update-2.0.zip")
        precondition(URLComponents(url: resolved, resolvingAgainstBaseURL: false)!.queryItems!.contains {
            $0.name == "replyzen_cb" && $0.value == "build-200"
        })
        let archive = manifestURL.deletingLastPathComponent().appendingPathComponent(manifest.downloadURL)
        let checksum = try manager.sha256(of: archive)
        precondition(checksum == manifest.sha256)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try manager.run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        guard let app = manager.findApp(in: directory), let bundle = Bundle(url: app) else {
            fatalError("Existing updater failed to find native update bundle")
        }
        precondition(bundle.bundleIdentifier == "com.lstoever.replyzen")
        precondition(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "200")
        precondition(bundle.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String != nil)
        print("PASS: unchanged installed updater decodes raw and GitHub API feed, resolves exact package, verifies SHA-256 and locates matching app")
    }
}

@main struct UpdaterCompatibilityRunner {
    static func main() throws {
        try UpdateManager.checkNativeUpdateCompatibility(manifestURL: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
