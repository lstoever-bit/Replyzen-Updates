import AppKit

@main
enum ReplyzenApp {
    static func main() {
        let app = NSApplication.shared
        ReplyZenDragInstaller.install()
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
