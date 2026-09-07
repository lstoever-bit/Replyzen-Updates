from pathlib import Path
import sys

root = Path(sys.argv[1])


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f'{label} not found')
    return text.replace(old, new, 1)


# 1) OutlookAccessibility: preserve direct local file URLs exposed by Outlook
# instead of reducing everything to just the attachment filename. If Outlook
# has not materialized the attachment yet, pressing its AX element often makes
# Outlook create the local temporary file; Replyzen retries immediately after.
p = root / 'app' / 'OutlookAccessibility.swift'
s = p.read_text()
anchor = '    func runningPID() -> pid_t? {\n'
if anchor not in s:
    raise SystemExit('OutlookAccessibility runningPID anchor not found')
helper = r'''    func attachmentFileURLs(from snapshot: Snapshot) -> [URL] {
        let attributes: [CFString] = [
            "AXURL" as CFString,
            "AXFilename" as CFString,
            kAXValueAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString
        ]
        var urls: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default

        for window in snapshot.windows {
            var stack: [AXUIElement] = [window]
            var visited = 0
            while let element = stack.popLast(), visited < 20_000 {
                visited += 1
                for attribute in attributes {
                    guard let raw = stringLikeAttribute(attribute, from: element), !raw.isEmpty else { continue }
                    for url in localAttachmentURLs(from: raw) {
                        let ext = url.pathExtension.lowercased()
                        guard ["pdf", "png", "jpg", "jpeg", "tif", "tiff"].contains(ext),
                              fm.fileExists(atPath: url.path) else { continue }
                        let key = url.standardizedFileURL.path.lowercased()
                        if seen.insert(key).inserted {
                            urls.append(url.standardizedFileURL)
                        }
                    }
                }
                for child in children(of: element).reversed() { stack.append(child) }
            }
        }
        return Array(urls.prefix(8))
    }

    func activateAttachment(named filename: String, from snapshot: Snapshot) -> Bool {
        let needle = filename.lowercased()
        guard !needle.isEmpty else { return false }
        let attributes: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            kAXValueAttribute as CFString,
            "AXFilename" as CFString
        ]

        for window in snapshot.windows {
            var stack: [AXUIElement] = [window]
            var visited = 0
            while let element = stack.popLast(), visited < 20_000 {
                visited += 1
                let meta = attributes.compactMap { stringLikeAttribute($0, from: element) }
                    .joined(separator: " ")
                    .lowercased()
                if meta.contains(needle) {
                    if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                        return true
                    }
                    if let parent = axElementAttribute(kAXParentAttribute as CFString, from: element),
                       AXUIElementPerformAction(parent, kAXPressAction as CFString) == .success {
                        return true
                    }
                }
                for child in children(of: element).reversed() { stack.append(child) }
            }
        }
        return false
    }

    private func localAttachmentURLs(from raw: String) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL?) {
            guard let url, url.isFileURL else { return }
            let standardized = url.standardizedFileURL
            let key = standardized.path.lowercased()
            if seen.insert(key).inserted { result.append(standardized) }
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = URL(string: trimmed), direct.isFileURL {
            append(direct)
        }

        let decoded = trimmed.removingPercentEncoding ?? trimmed
        if decoded.hasPrefix("/") {
            append(URL(fileURLWithPath: decoded))
        }

        let pattern = #"file://[^\s\"'<>]+\.(?:pdf|png|jpe?g|tiff?)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            for match in regex.matches(in: trimmed, range: range) {
                guard let r = Range(match.range, in: trimmed) else { continue }
                append(URL(string: String(trimmed[r])))
            }
        }
        return result
    }

'''
s = s.replace(anchor, helper + anchor, 1)
p.write_text(s)


# 2) AttachmentTextExtractor: accept already-materialized file paths and scan
# the Outlook temporary locations before falling back to the broader profile.
p = root / 'app' / 'AttachmentTextExtractor.swift'
s = p.read_text()
old_start = '''    private func findFile(named filename: String) -> URL? {\n        let fm = FileManager.default\n        let base = URL(fileURLWithPath: filename).lastPathComponent\n        guard !base.isEmpty else { return nil }\n\n        // Spotlight is much faster than walking the full Outlook profile when the file is indexed.\n'''
new_start = '''    private func findFile(named filename: String) -> URL? {\n        let fm = FileManager.default\n        let cleaned = filename.trimmingCharacters(in: .whitespacesAndNewlines)\n\n        if let fileURL = URL(string: cleaned), fileURL.isFileURL, fm.fileExists(atPath: fileURL.path) {\n            return fileURL.standardizedFileURL\n        }\n        if cleaned.hasPrefix("/"), fm.fileExists(atPath: cleaned) {\n            return URL(fileURLWithPath: cleaned).standardizedFileURL\n        }\n\n        let base = URL(fileURLWithPath: filename).lastPathComponent\n        guard !base.isEmpty else { return nil }\n\n        // Spotlight is much faster than walking the full Outlook profile when the file is indexed.\n'''
s = must_replace(s, old_start, new_start, 'AttachmentTextExtractor findFile start')
old_roots = '''        let roots = [\n            home.appendingPathComponent("Library/Containers/com.microsoft.Outlook/Data/Library/Caches", isDirectory: true),\n            home.appendingPathComponent("Library/Group Containers/UBF8T346G9.Office/Outlook", isDirectory: true),\n            home.appendingPathComponent("Library/Caches/com.microsoft.Outlook", isDirectory: true),\n            home.appendingPathComponent("Downloads", isDirectory: true),\n            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)\n        ]\n'''
new_roots = '''        let roots = [\n            home.appendingPathComponent("Library/Containers/com.microsoft.Outlook/Data/tmp", isDirectory: true),\n            home.appendingPathComponent("Library/Containers/com.microsoft.Outlook/Data/Library/Caches", isDirectory: true),\n            home.appendingPathComponent("Library/Containers/com.microsoft.Outlook/Data/Library/Application Support", isDirectory: true),\n            home.appendingPathComponent("Library/Group Containers/UBF8T346G9.Office/TemporaryItems", isDirectory: true),\n            home.appendingPathComponent("Library/Group Containers/UBF8T346G9.Office/Outlook", isDirectory: true),\n            home.appendingPathComponent("Library/Caches/com.microsoft.Outlook", isDirectory: true),\n            home.appendingPathComponent("Downloads", isDirectory: true),\n            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)\n        ]\n'''
s = must_replace(s, old_roots, new_roots, 'AttachmentTextExtractor roots')
s = s.replace('if visited > 80_000 { break }', 'if visited > 140_000 { break }')
p.write_text(s)


# 3) Payment flow: combine direct AX file URLs with filesystem lookup. If the
# PDF is only shown in Outlook, activate it once to force Outlook to download /
# materialize it, wait briefly, and retry before falling back to mail text.
p = root / 'app' / 'AppDelegate.swift'
s = p.read_text()
old = '''            let filenames = self.outlook.attachmentFilenames(from: snapshot)\n            let resolvedFiles = self.attachmentExtractor.resolveFiles(filenames: filenames)\n            let pdfFiles = resolvedFiles.filter { $0.pathExtension.lowercased() == "pdf" }\n            let selectedPDFs = Array(pdfFiles.prefix(3))\n\n            var fallbackText = ""\n            var sourceStatus: String\n'''
new = '''            let filenames = self.outlook.attachmentFilenames(from: snapshot)\n            let mentionedPDF = filenames.first { $0.lowercased().hasSuffix(".pdf") }\n\n            var directFiles = self.outlook.attachmentFileURLs(from: snapshot)\n            var resolvedFiles = directFiles + self.attachmentExtractor.resolveFiles(filenames: filenames)\n            var selectedPDFs = Array(resolvedFiles.filter { $0.pathExtension.lowercased() == "pdf" }.prefix(3))\n\n            if selectedPDFs.isEmpty, let pdfName = mentionedPDF {\n                DispatchQueue.main.sync {\n                    self.state.statusText = "PDF wird aus Outlook geladen …"\n                    self.outlook.activateOutlook(pid: snapshot.pid)\n                    _ = self.outlook.activateAttachment(named: pdfName, from: snapshot)\n                }\n\n                Thread.sleep(forTimeInterval: 1.4)\n                let retrySnapshot = (try? self.outlook.captureSnapshot(includeAllWindows: true)) ?? snapshot\n                directFiles = self.outlook.attachmentFileURLs(from: retrySnapshot)\n                resolvedFiles = directFiles + self.attachmentExtractor.resolveFiles(filenames: filenames)\n                selectedPDFs = Array(resolvedFiles.filter { $0.pathExtension.lowercased() == "pdf" }.prefix(3))\n            }\n\n            var fallbackText = ""\n            var sourceStatus: String\n'''
s = must_replace(s, old, new, 'AppDelegate payment attachment resolution')
s = s.replace(
    'sourceStatus = "PDF-Anhang in Outlook erkannt, aber die lokale PDF-Datei war nicht zugänglich. Extraktion nur aus dem Mailtext."',
    'sourceStatus = "PDF-Anhang erkannt, aber Outlook hat keine lokale Datei bereitgestellt. Bitte den PDF-Anhang einmal in Outlook öffnen und erneut auf Überweisung klicken."'
)
p.write_text(s)


# 4) Version and release metadata.
p = root / 'app' / 'Info.plist'
s = p.read_text()
s = must_replace(s, '<string>1.20.0</string>', '<string>1.21.0</string>', 'version')
s = must_replace(s, '<string>21</string>', '<string>22</string>', 'build')
p.write_text(s)

p = root / 'Build-CI.sh'
s = p.read_text()
s = s.replace('Replyzen-update-1.20.zip', 'Replyzen-update-1.21.zip')
s = s.replace(
    'Replyzen 1.20: vier einheitliche Funktionsbuttons; GPT-5.6 Luna ohne Reasoning für schnelle Antworten; Überweisung liest PDF-Rechnungen direkt mit OpenAI und löscht temporär hochgeladene Dateien nach der Extraktion.',
    'Replyzen 1.21: robustere PDF-Übernahme aus Outlook über direkte AX-Datei-URLs und automatisches Materialisieren des Anhangs; erweiterte Outlook-Temp-Suche.'
)
p.write_text(s)
