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

        // Snapshot every representation on the current item so we can put back
        // images/RTF/files, not just plain text.
        var snapshot: [(NSPasteboard.PasteboardType, Data)] = []
        if restoreClipboard, let item = pb.pasteboardItems?.first {
            for type in item.types {
                if let data = item.data(forType: type) {
                    snapshot.append((type, data))
                }
            }
        }

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Let the pasteboard settle before the keystroke reaches the target app.
        usleep(30_000)
        sendCommandV()

        guard restoreClipboard else { return }
        // Restore after the paste has been consumed. 400 ms is enough for
        // Electron apps, which read the pasteboard asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pb.clearContents()
            guard !snapshot.isEmpty else { return }
            let item = NSPasteboardItem()
            for (type, data) in snapshot {
                item.setData(data, forType: type)
            }
            pb.writeObjects([item])
        }
    }

    private static func sendCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // Don't let our synthetic Cmd-V re-enter our own event tap logic.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let vKey: CGKeyCode = 0x09  // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
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
