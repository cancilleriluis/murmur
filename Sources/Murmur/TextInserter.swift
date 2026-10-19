import Foundation
import AppKit
import CoreGraphics

/// Places text at the caret of whatever app has focus.
///
/// Two strategies:
///  - `.paste`: stash the pasteboard, write the text, synthesize Cmd-V, restore.
///    Fast and reliable for long text; the standard approach.
///  - `.type`: synthesize the characters directly via CGEvent unicode strings.
///    Slower, but leaves the pasteboard untouched and works in the rare app
///    that blocks paste.
enum TextInserter {

    static func insert(_ text: String, using mode: String, restoreClipboard: Bool) {
        guard !text.isEmpty else { return }
        switch mode.lowercased() {
        case "type":
            typeText(text)
        case "clipboard", "copy":
            // Copy only — never press anything. Works without Accessibility.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        default:
            pasteText(text, restoreClipboard: restoreClipboard)
        }
    }

    // MARK: - Pasteboard + Cmd-V

    private static func pasteText(_ text: String, restoreClipboard: Bool) {
        let pb = NSPasteboard.general

        let snapshot = restoreClipboard ? snapshotPasteboard(pb) : []

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Let the pasteboard settle before the keystroke reaches the target app.
        usleep(30_000)
        sendCommandV()

        guard restoreClipboard else { return }
        // Restore after the paste has been consumed. 400 ms is enough for
        // Electron apps, which read the pasteboard asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            restorePasteboard(pb, from: snapshot)
        }
    }

    /// Every representation on the current item, so images/RTF/files come
    /// back too, not just plain text.
    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [(NSPasteboard.PasteboardType, Data)] {
        guard let item = pb.pasteboardItems?.first else { return [] }
        return item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }

    private static func restorePasteboard(_ pb: NSPasteboard,
                                          from snapshot: [(NSPasteboard.PasteboardType, Data)]) {
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        let item = NSPasteboardItem()
        for (type, data) in snapshot {
            item.setData(data, forType: type)
        }
        pb.writeObjects([item])
    }

    /// The text selected in the frontmost app, read with a synthetic ⌘C;
    /// the clipboard is put back afterwards. Nil when nothing is selected
    /// (the copy never changes the clipboard). Blocks for up to ~0.3 s.
    static func copySelection() -> String? {
        let pb = NSPasteboard.general
        let snapshot = snapshotPasteboard(pb)
        let before = pb.changeCount
        sendKey(0x08, flags: .maskCommand)              // kVK_ANSI_C
        var copied: String?
        for _ in 0..<30 {
            usleep(10_000)
            if pb.changeCount != before {
                copied = pb.string(forType: .string)
                break
            }
        }
        if pb.changeCount != before { restorePasteboard(pb, from: snapshot) }
        return copied
    }

    /// ⌘Z in the frontmost app — undoes a paste in practically every app.
    static func sendUndo() {
        sendKey(0x06, flags: .maskCommand)              // kVK_ANSI_Z
    }

    private static func sendCommandV() {
        sendKey(0x09, flags: .maskCommand)              // kVK_ANSI_V
    }

    private static func sendKey(_ key: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // Don't let our synthetic keystroke re-enter our own event tap logic.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Direct keystroke synthesis

    private static func typeText(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // CGEvent unicode payloads are capped; chunk to stay well inside it.
        for chunk in chunks(of: Array(text.utf16), size: 16) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            var buffer = chunk
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(2_000)
        }
    }

    private static func chunks(of array: [UInt16], size: Int) -> [[UInt16]] {
        stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<min($0 + size, array.count)])
        }
    }

    // MARK: - Accessibility permission

    /// True when the process may post synthetic events. `prompt: true` shows
    /// the system dialog that deep-links into System Settings.
    @discardableResult
    static func hasAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
