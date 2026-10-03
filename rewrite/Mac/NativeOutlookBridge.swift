import AppKit
import Foundation

/// Native Outlook object model. No UI focus, keyboard simulation, clipboard,
/// coordinate clicking, accessibility tree traversal or automatic send command.
final class NativeOutlookBridge: NativeOutlookTransport {
    private var script: NSAppleScript?
    private let scriptURL: URL?
    private let executor: (([Argument]) throws -> NSAppleEventDescriptor)?
    init(scriptURL: URL? = Bundle.main.url(forResource: "Outlook", withExtension: "applescript"), executor: (([Argument]) throws -> NSAppleEventDescriptor)? = nil) {
        self.scriptURL = scriptURL
        self.executor = executor
    }

    func capture() throws -> NativeMailContext {
        let row = try execute([.string("capture")])
        guard row.numberOfItems == 4 else { throw NativeMailError.unsupportedOutlook }
        return NativeMailContext(token: NativeMessageToken(localID: try string(row, 1),
            internetID: try string(row, 2), subject: try string(row, 3)), plainText: try string(row, 4))
    }
    func validateSource(_ token: NativeMessageToken) throws { _ = try execute(sourceArguments("validate", token)) }
    func sourceAttachments(_ token: NativeMessageToken) throws -> [NativeAttachment] {
        try attachments(execute(sourceArguments("sourceAttachments", token)))
    }
    func create(mode: NativeMailMode, source: NativeMessageToken?) throws -> String {
        let args: [Argument] = source.map { sourceArguments("create", $0) } ?? [.string("create"), .string("0"), .string(""), .string("")]
        let result = try execute(args + [.string(mode.rawValue)])
        guard let id = result.stringValue, !id.isEmpty else { throw NativeMailError.invalidDraft }
        return id
    }
    func readDraft(id: String) throws -> NativeDraftSnapshot {
        let row = try execute([.string("read"), .string(id)])
        guard row.numberOfItems == 6, let list = row.atIndex(5), let htmlFlag = row.atIndex(6) else { throw NativeMailError.invalidDraft }
        return NativeDraftSnapshot(id: try string(row, 1), subject: try string(row, 2), html: try string(row, 3),
            plainText: try string(row, 4), attachments: try attachments(list), isHTML: htmlFlag.booleanValue)
    }
    func apply(id: String, expected: NativeDraftSnapshot, subject: String, html: String, reminderBCC: String?) throws {
        let bcc = reminderBCC?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard bcc.isEmpty || (bcc.contains("@") && !bcc.contains(where: { $0.isWhitespace || $0 == ";" || $0 == "," })) else {
            throw NativeMailError.transport(code: -9008)
        }
        let inventory = expected.attachments.map { Argument.list([.string($0.name), .integer($0.size)]) }
        _ = try execute([.string("apply"), .string(id), .string(expected.subject), .string(expected.html),
            .string(expected.plainText), .list(inventory), .string(subject), .string(html), .string(bcc)])
    }
    func reveal(id: String) throws { _ = try execute([.string("reveal"), .string(id)]) }
    private func sourceArguments(_ action: String, _ token: NativeMessageToken) -> [Argument] {
        [.string(action), .string(token.localID), .string(token.internetID), .string(token.subject)]
    }
    private func string(_ row: NSAppleEventDescriptor, _ index: Int) throws -> String {
        guard let value = row.atIndex(index)?.stringValue else { throw NativeMailError.invalidDraft }
        return value
    }
    private func attachments(_ rows: NSAppleEventDescriptor) throws -> [NativeAttachment] {
        if rows.numberOfItems == 0 { return [] }
        return try (1...rows.numberOfItems).map { index in
            guard let row = rows.atIndex(index), row.numberOfItems == 2, let size = row.atIndex(2) else { throw NativeMailError.invalidDraft }
            return NativeAttachment(name: try string(row, 1), size: Int(size.int32Value))
        }
    }
    enum Argument {
        case string(String), integer(Int), list([Argument])
        var descriptor: NSAppleEventDescriptor {
            switch self {
            case .string(let value): return NSAppleEventDescriptor(string: value)
            case .integer(let value): return NSAppleEventDescriptor(int32: Int32(clamping: value))
            case .list(let values):
                let list = NSAppleEventDescriptor.list()
                for (index, value) in values.enumerated() { list.insert(value.descriptor, at: index + 1) }
                return list
            }
        }
    }
    private func execute(_ args: [Argument]) throws -> NSAppleEventDescriptor {
        precondition(Thread.isMainThread, "NSAppleScript must run on the main thread")
        if let executor { return try executor(args) }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.Outlook").count == 1 else {
            throw NativeMailError.notRunning
        }
        if script == nil {
            guard let scriptURL, let source = try? String(contentsOf: scriptURL, encoding: .utf8),
                  let candidate = NSAppleScript(source: source) else { throw NativeMailError.unsupportedOutlook }
            var error: NSDictionary?
            guard candidate.compileAndReturnError(&error) else { throw translate(error) }
            script = candidate
        }
        guard let script else { throw NativeMailError.unsupportedOutlook }
        // Invoke the static run handler with genuine Apple-event descriptors.
        // Quotes, newlines and malicious-looking text remain data, not code.
        let event = NSAppleEventDescriptor(eventClass: 0x61657674, eventID: 0x6F617070,
            targetDescriptor: nil, returnID: -1, transactionID: 0)
        event.setParam(Argument.list(args).descriptor, forKeyword: 0x2D2D2D2D)
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error { throw translate(error) }
        return result
    }
    private func translate(_ error: NSDictionary?) -> NativeMailError {
        let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
        switch code {
        case -1743: return .permissionDenied
        case -1708, -2741, -2753: return .unsupportedOutlook
        case -600: return .notRunning
        case -9001: return .missingSource
        case -9002: return .sourceChanged
        default: return .transport(code: code)
        }
    }
}
