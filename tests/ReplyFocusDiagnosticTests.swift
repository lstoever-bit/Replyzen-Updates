import Foundation

@main struct ReplyFocusDiagnosticTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        let outlook = ReplyFocusDiagnostic.Application(pid: 10, name: "Microsoft Outlook", bundleID: "com.microsoft.Outlook")
        let other = ReplyFocusDiagnostic.Application(pid: 20, name: "Different App", bundleID: "test.other")
        let report = ReplyFocusDiagnostic.Report(version: "1.75.1 (77)", observed: other, current: outlook,
            expected: outlook, expectedPID: 10, selfPID: 30, accessibilityApplication: outlook,
            accessibilityStatus: 0, focusedElementPID: 11, focusedElementRole: "AXTextArea",
            windowRelation: "target", pasteRequested: false, ownInteractiveWindow: false,
            outlookPIDs: [10, 40], replyzenPIDs: [50, 30])
        let original = report.text
        check(original.contains("observed: Different App [test.other] pid=20"), "retain process from decision")
        check(original.contains("now: Microsoft Outlook [com.microsoft.Outlook] pid=10"), "separate later observation")
        check(original.contains("AX-app: Microsoft Outlook"), "independent AX identity")
        check(original.contains("saved-pid=10"), "saved snapshot PID retained")
        check(original.contains("self-pid=30"), "own PID retained")
        check(original.contains("AX-element=11 / AXTextArea"), "renderer PID distinct from host")
        check(original.contains("Outlook-pids=[10, 40]"), "detect multiple Outlook processes")
        check(original.contains("ReplyZen-pids=[30, 50]"), "detect multiple ReplyZen processes")
        check(original.contains("paste-requested=false"), "no success claim before dispatch")
        check(original.contains("window=target"), "target relationship without subject")
        check(report.text == original, "rendering frozen snapshot is deterministic")
        check(original.components(separatedBy: "\n").count == 6, "bounded report")
        let corrupt = ReplyFocusDiagnostic.Application(pid: 9, name: "First\nSecond\r\t", bundleID: String(repeating: "x", count: 500))
        check(!corrupt.summary.contains("\n") && !corrupt.summary.contains("\r") && !corrupt.summary.contains("\t"), "names cannot add fake report lines")
        check(corrupt.summary.count < 150, "bounded application labels")
        let unknown = ReplyFocusDiagnostic.Report(version: "test", observed: nil, current: nil,
            expected: nil, expectedPID: 99, selfPID: 30, accessibilityApplication: nil,
            accessibilityStatus: -25204, focusedElementPID: nil, focusedElementRole: nil,
            windowRelation: "unavailable", pasteRequested: true, ownInteractiveWindow: true,
            outlookPIDs: [], replyzenPIDs: [])
        check(unknown.text.contains("observed: unavailable"), "unknown is not assigned an invented process")
        check(unknown.text.contains("not running / saved-pid=99"), "stale PID visible")
        check(unknown.text.contains("status=-25204"), "AX error retained without success assumption")
        check(unknown.text.contains("paste-requested=true"), "post-dispatch state explicit")
        #if canImport(AppKit)
        let live = ReplyFocusDiagnostic.capture(observed: nil, expectedPID: ProcessInfo.processInfo.processIdentifier,
            sourceWindow: nil, targetWindow: nil, pasteRequested: false, ownInteractiveWindow: false)
        check(live.contains("observed: unavailable"), "real sampler must not replace nil decision sample")
        check(live.contains("saved-pid="), "AppKit sampler returns a bounded report even without AX permission")
        #endif
        print("PASS: \(checks) failure metadata checks; no Outlook end-to-end test")
    }
}
