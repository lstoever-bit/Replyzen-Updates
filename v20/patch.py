from pathlib import Path

root = Path(__import__('sys').argv[1])

# Make update checks resistant to GitHub/raw CDN caching.
p = root / 'app' / 'UpdateManager.swift'
s = p.read_text()
old = '''        var request = URLRequest(url: url)\n        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData\n        request.timeoutInterval = 15\n\n        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in\n'''
new = '''        let fetchURL = cacheBustedURL(url, token: String(Int(Date().timeIntervalSince1970)))\n        var request = URLRequest(url: fetchURL)\n        request.cachePolicy = .reloadIgnoringLocalCacheData\n        request.timeoutInterval = 15\n        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")\n        request.setValue("no-cache", forHTTPHeaderField: "Pragma")\n\n        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in\n'''
if old not in s:
    raise SystemExit('update request block not found')
s = s.replace(old, new, 1)

old = '''    private func resolvedDownloadURL(_ update: AvailableUpdate) -> URL? {\n        if let absolute = URL(string: update.manifest.downloadURL), absolute.scheme != nil {\n            guard absolute.scheme?.lowercased() == "https" else { return nil }\n            return absolute\n        }\n\n        let base = update.feedURL.deletingLastPathComponent()\n        return URL(string: update.manifest.downloadURL, relativeTo: base)?.absoluteURL\n    }\n'''
new = '''    private func resolvedDownloadURL(_ update: AvailableUpdate) -> URL? {\n        let resolved: URL?\n        if let absolute = URL(string: update.manifest.downloadURL), absolute.scheme != nil {\n            guard absolute.scheme?.lowercased() == "https" else { return nil }\n            resolved = absolute\n        } else {\n            let base = update.feedURL.deletingLastPathComponent()\n            resolved = URL(string: update.manifest.downloadURL, relativeTo: base)?.absoluteURL\n        }\n        guard let resolved else { return nil }\n        return cacheBustedURL(resolved, token: "build-\\(update.manifest.build)")\n    }\n\n    private func cacheBustedURL(_ url: URL, token: String) -> URL {\n        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }\n        var items = components.queryItems ?? []\n        items.removeAll { $0.name == "replyzen_cb" }\n        items.append(URLQueryItem(name: "replyzen_cb", value: token))\n        components.queryItems = items\n        return components.url ?? url\n    }\n'''
if old not in s:
    raise SystemExit('resolvedDownloadURL block not found')
s = s.replace(old, new, 1)
p.write_text(s)

# Version bump.
p = root / 'app' / 'Info.plist'
s = p.read_text()
s = s.replace('<string>1.9.0</string>', '<string>1.10.0</string>', 1)
s = s.replace('<string>10</string>', '<string>11</string>', 1)
p.write_text(s)

# Use a version-specific ZIP filename so even old clients cannot receive a stale cached archive.
p = root / 'Build-CI.sh'
s = p.read_text()
s = s.replace('UPDATE_ZIP="$ROOT/Replyzen-update.zip"', 'UPDATE_ZIP="$ROOT/Replyzen-update-1.10.zip"', 1)
s = s.replace('"download_url": "Replyzen-update.zip"', '"download_url": "Replyzen-update-1.10.zip"', 1)
s = s.replace('Replyzen 1.9: altes leeres Einstellungsfenster wird unterdrückt; beim Start erscheint eine Bestätigung mit lokalem Zufallswitz.', 'Replyzen 1.10: Update-Cache behoben; Versionsprüfung und Download nutzen Cache-Busting, plus versionsspezifisches Update-Paket.')
p.write_text(s)
