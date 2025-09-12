import AppKit

enum Clipboard {
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        LOG("Copied to clipboard", ctx: ["size":"\(text.count)"])
    }
}