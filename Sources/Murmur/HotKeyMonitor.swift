import Foundation
import AppKit
import CoreGraphics

/// Global push-to-talk detector. Watches `flagsChanged` events through a
/// CGEventTap and reports press/release edges for a chosen modifier (fn or a
/// left/right modifier key). Hold-to-talk semantics.
final class HotKeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var mask: UInt64 = HotKeyMonitor.maskFor("fn")
    private var isDown = false

    /// Logs every modifier change to murmur.log. Toggled by `debug_hotkey`.
    var debugLogging = false

    /// True once any source has actually delivered a modifier event — proof
    /// that we're really receiving input, not just holding a dead tap.
    private(set) var hasSeenAnyEvent = false

    /// CGEventFlags bit for the configured hotkey. Includes device-dependent
    /// left/right modifier bits (from IOLLEvent.h) so we can tell sides apart.
    static func maskFor(_ name: String) -> UInt64 {
        switch name.lowercased() {
        case "fn", "globe", "function":       return 0x800000   // maskSecondaryFn
        case "left_control", "left_ctrl":     return 0x00000001
        case "left_shift":                    return 0x00000002
        case "right_shift":                   return 0x00000004
        case "left_command", "left_cmd":      return 0x00000008
        case "right_command", "right_cmd":    return 0x00000010
        case "left_option", "left_alt":       return 0x00000020
        case "right_option", "right_alt":     return 0x00000040
        case "right_control", "right_ctrl":   return 0x00002000
        default:                              return 0x800000
        }
    }

    func setHotkey(_ name: String) {
        mask = HotKeyMonitor.maskFor(name)
        isDown = false
    }

    /// Starts both input sources and returns false only if *neither* could be
    /// established.
    ///
    /// Two sources, deliberately:
    ///  - `CGEventTap` needs **Input Monitoring**. It can be created
    ///    successfully and then silently deliver nothing when that grant is
    ///    missing, so its return value alone proves nothing.
    ///  - `NSEvent.addGlobalMonitorForEvents` needs **Accessibility**.
    /// Whichever is alive drives the hotkey; `handleFlags` de-duplicates, so
    /// both firing is harmless.
    @discardableResult
    func start() -> Bool {
        let tapOK = startEventTap()
        let monitorOK = startGlobalMonitor()
        if !tapOK && monitorOK {
            Log.write("Event tap unavailable; running on NSEvent global monitor (Accessibility).")
        }
        return tapOK || monitorOK
    }

    // MARK: NSEvent global monitor (Accessibility-backed)

    private func startGlobalMonitor() -> Bool {
        guard globalMonitor == nil else { return true }
        // NSEvent's raw modifier bits line up with CGEventFlags: the
        // device-independent flags live in 0xFFFF0000 (fn = 1<<23) and the
        // left/right-specific bits in the low half, so one mask table serves both.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlags(UInt64(event.modifierFlags.rawValue), source: "global")
        }
        // The global monitor is blind to our own app's events; add a local one
        // so the hotkey still works when Murmur's menu happens to be focused.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlags(UInt64(event.modifierFlags.rawValue), source: "local")
            return event
        }
        return globalMonitor != nil
    }

    /// Returns false if the tap could not be created (missing permission).
    @discardableResult
    private func startEventTap() -> Bool {
        stopTap()
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .flagsChanged {
                monitor.handleFlags(event.flags.rawValue, source: "tap")
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        ) else {
            Log.write("Failed to create event tap — Input Monitoring / Accessibility not granted.")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        stopTap()
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        isDown = false
    }

    private func stopTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        isDown = false
    }

    private func handleFlags(_ rawFlags: UInt64, source: String) {
        hasSeenAnyEvent = true
        let nowDown = (rawFlags & mask) != 0

        if debugLogging {
            Log.write(String(format: "[%@] flags=0x%llX mask=0x%llX -> %@",
                             source, rawFlags, mask, nowDown ? "DOWN" : "up"))
        }

        // Both sources can report the same physical press; only act on edges.
        if nowDown == isDown { return }
        isDown = nowDown
        DispatchQueue.main.async { [weak self] in
            nowDown ? self?.onPress?() : self?.onRelease?()
        }
    }
}
