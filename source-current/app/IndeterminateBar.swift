import SwiftUI
import AppKit

struct IndeterminateBar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.controlSize = .regular
        indicator.startAnimation(nil)
        return indicator
    }

    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {
        nsView.startAnimation(nil)
    }
}
