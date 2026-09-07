import AppKit
import CoreText

/// Reuse fonts from an already installed Office app, without copying, downloading
/// or redistributing them. Registration is limited to the ReplyZen process.
enum MailFontResolver {
    static let light: NSFont? = {
        func findLight() -> NSFont? {
            for name in ["Calibri-Light", "Calibri Light", "CalibriLight"] {
                if let font = NSFont(name: name, size: 10.5) { return font }
            }
            return nil
        }
        if let font = findLight() { return font }
        let fm = FileManager.default
        for identifier in ["com.microsoft.Outlook", "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint"] {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
                  let resources = Bundle(url: appURL)?.resourceURL else { continue }
            for folder in ["DFonts", "Fonts"] {
                let directory = resources.appendingPathComponent(folder, isDirectory: true)
                guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for url in files where url.lastPathComponent.lowercased().hasPrefix("calibri") && ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                }
            }
            if let font = findLight() { return font }
        }
        return nil
    }()
}
