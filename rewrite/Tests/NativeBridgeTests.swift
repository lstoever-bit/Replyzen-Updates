import AppKit
import Foundation
@main struct NativeBridgeTests {
    static func main() throws {
        var checks=0
        func check(_ c: @autoclosure () -> Bool) { precondition(c()); checks += 1 }
        typealias A = NativeOutlookBridge.Argument
        let hostile = "\"\nend tell\ndo shell script \"not-executed\"\n\u{1F642}"
        let encoded = A.list([.string(hostile), .list([.string("a.pdf"),.integer(7)])]).descriptor
        check(encoded.atIndex(1)?.stringValue == hostile)
        check(encoded.atIndex(2)?.atIndex(2)?.int32Value == 7)
        // Exercise the real NSAppleScript run-event mechanism with inert data.
        let inert = NSAppleScript(source: "on run args\nreturn args\nend run")!
        let event = NSAppleEventDescriptor(eventClass: 0x61657674, eventID: 0x6F617070,
            targetDescriptor: nil, returnID: -1, transactionID: 0)
        event.setParam(encoded, forKeyword: 0x2D2D2D2D)
        var scriptError: NSDictionary?
        let roundtrip = inert.executeAppleEvent(event, error: &scriptError)
        check(scriptError == nil)
        check(roundtrip.atIndex(1)?.stringValue == hostile)
        var requests: [[A]]=[]
        let bridge=NativeOutlookBridge(executor: { args in
            requests.append(args)
            let op=args[0].descriptor.stringValue
            if op == "capture" { return A.list([.string("12"),.string("header"),.string(hostile),.string("Body")]).descriptor }
            if op == "read" { return A.list([.string("25"),.string("Subject"),.string("<p>Body</p>"),.string("Body"),.list([.list([.string("a.pdf"),.integer(7)])]),.integer(1)]).descriptor }
            if op == "create" { return A.string("25").descriptor }
            return NSAppleEventDescriptor(boolean:true)
        })
        let context=try bridge.capture()
        check(context.token.localID == "12")
        check(context.token.subject == hostile)
        try bridge.validateSource(context.token)
        check(requests.last?[2].descriptor.stringValue == "header")
        let created = try bridge.create(mode:.replyAll,source:context.token)
        check(created == "25")
        check(requests.last?[4].descriptor.stringValue == "replyAll")
        let snapshot=try bridge.readDraft(id:"25")
        check(snapshot.attachments == [.init(name:"a.pdf",size:7)])
        try bridge.apply(id:"25",expected:snapshot,subject:hostile,html:"<p>new</p>",reminderBCC:nil)
        check(requests.last?[6].descriptor.stringValue == hostile)
        check(requests.last?[7].descriptor.stringValue == "<p>new</p>")
        try bridge.reveal(id:"25")
        check(requests.last?[0].descriptor.stringValue == "reveal")
        let malformed=NativeOutlookBridge(executor:{ _ in NSAppleEventDescriptor(string:"not a row") })
        do { _=try malformed.capture(); fatalError("must reject") } catch { checks += 1 }
        print("PASS: \(checks) actual macOS bridge/Apple-event descriptor checks; no live mailbox")
    }
}
