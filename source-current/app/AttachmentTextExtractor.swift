import Foundation
import AppKit
import PDFKit
import Vision

final class AttachmentTextExtractor {
    struct Result {
        let text: String
        let usedFiles: [String]
    }

    func extract(filenames: [String]) -> Result {
        var chunks: [String] = []
        var used: [String] = []

        for filename in filenames.prefix(4) {
            guard let url = findFile(named: filename) else { continue }
            let ext = url.pathExtension.lowercased()
            let text: String
            if ext == "pdf" {
                text = extractPDF(url)
            } else if ["png", "jpg", "jpeg", "tif", "tiff"].contains(ext) {
                text = extractImage(url)
            } else {
                text = ""
            }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                used.append(url.lastPathComponent)
                chunks.append("ATTACHMENT \(url.lastPathComponent):\n\(String(cleaned.prefix(18_000)))")
            }
        }

        return Result(text: String(chunks.joined(separator: "\n\n").prefix(30_000)), usedFiles: used)
    }

    private func findFile(named filename: String) -> URL? {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: filename).lastPathComponent
        guard !base.isEmpty else { return nil }

        // Spotlight is much faster than walking the full Outlook profile when the file is indexed.
        if let path = spotlightPath(named: base), fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let home = fm.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent("Library/Containers/com.microsoft.Outlook/Data/Library/Caches", isDirectory: true),
            home.appendingPathComponent("Library/Group Containers/UBF8T346G9.Office/Outlook", isDirectory: true),
            home.appendingPathComponent("Library/Caches/com.microsoft.Outlook", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        ]

        var best: (URL, Date)?
        var visited = 0
        for root in roots where fm.fileExists(atPath: root.path) {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                visited += 1
                if visited > 80_000 { break }
                guard url.lastPathComponent.caseInsensitiveCompare(base) == .orderedSame else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let date = values?.contentModificationDate ?? .distantPast
                if best == nil || date > best!.1 { best = (url, date) }
            }
            if visited > 80_000 { break }
        }
        return best?.0
    }

    private func spotlightPath(named filename: String) -> String? {
        let escaped = filename.replacingOccurrences(of: "'", with: "\\'")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemFSName == '\(escaped)'c"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let candidates = output.split(separator: "\n").map(String.init)
            return candidates.first { path in
                let lower = path.lowercased()
                return lower.contains("outlook") || lower.contains("downloads") || lower.contains("temporary") || lower.contains("/var/folders/")
            } ?? candidates.first
        } catch {
            return nil
        }
    }

    private func extractPDF(_ url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        var pieces: [String] = []
        for index in 0..<min(document.pageCount, 12) {
            if let text = document.page(at: index)?.string, !text.isEmpty {
                pieces.append(text)
            }
        }
        return pieces.joined(separator: "\n")
    }

    private func extractImage(_ url: URL) -> String {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["de-DE", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        } catch {
            return ""
        }
    }
}
