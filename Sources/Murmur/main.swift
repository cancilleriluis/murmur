import AppKit
import ServiceManagement

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = ConfigStore()
    private let hotkey = HotKeyMonitor()
    private let pill = RecordingPill()
    private var recorder = AudioRecorder()

    private var statusItem: NSStatusItem!
    private var isEnabled = true
    private var isRecording = false
    private var isProcessing = false
    /// Kept so it can be re-copied from the menu if the paste went nowhere.
    private var lastTranscript: String = ""

    private let work = DispatchQueue(label: "murmur.pipeline", qos: .userInitiated)

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon

        buildStatusItem()
        wireHotkey()

        // Ask for mic up front so the first dictation isn't eaten by a prompt.
        AudioRecorder.requestPermission { granted in
            if !granted { Log.write("Microphone permission not granted.") }
        }

        if !TextInserter.hasAccessibility(prompt: false) {
            // Prompt once; the tap below will also fail without it.
            TextInserter.hasAccessibility(prompt: true)
        }

        if !hotkey.start() {
            showPermissionAlert()
        }

        Log.write("Murmur started. hotkey=\(store.config.hotkey) backend=\(store.config.transcription_backend)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
    }

    // MARK: Hotkey wiring

    private func wireHotkey() {
        hotkey.setHotkey(store.config.hotkey)
        hotkey.debugLogging = store.config.debug_hotkey
        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.endRecording() }
    }

    // MARK: Record → transcribe → clean → insert

    private func beginRecording() {
        guard isEnabled, !isRecording, !isProcessing else {
            Log.write("press ignored (enabled=\(isEnabled) recording=\(isRecording) processing=\(isProcessing))")
            return
        }
        guard AudioRecorder.hasPermission else {
            Log.write("press ignored — MICROPHONE NOT GRANTED. Requesting…")
            AudioRecorder.requestPermission { ok in
                Log.write("microphone permission result: \(ok ? "granted" : "DENIED")")
            }
            return
        }

        recorder = AudioRecorder()
        recorder.onLevel = { [weak self] level in self?.pill.update(level: level) }

        do {
            try recorder.start()
            isRecording = true
            pill.show(state: .recording)
            refreshStatusIcon()
            Log.write("recording started")
        } catch {
            Log.write("Failed to start recording: \(error)")
            flashError("Mic error")
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        refreshStatusIcon()

        guard let result = recorder.stop() else {
            Log.write("stopped — no usable audio captured (mic silent or blocked?)")
            pill.hide()
            return
        }
        // Ignore accidental taps.
        guard result.duration >= store.config.min_recording_seconds else {
            Log.write(String(format: "stopped — too short (%.2fs < %.2fs), discarded",
                             result.duration, store.config.min_recording_seconds))
            try? FileManager.default.removeItem(at: result.url)
            pill.hide()
            return
        }
        // Silence gate — whisper invents speech from room tone, so a take that
        // never reached speech level must not reach it at all.
        let peak = Double(recorder.peakLevel)
        let voiced = recorder.voicedFraction
        if store.config.min_peak_level > 0,
           peak < store.config.min_peak_level || voiced < store.config.min_voiced_fraction {
            Log.write(String(format:
                "discarded — too quiet (peak %.2f < %.2f, voiced %.0f%% < %.0f%%). Mic muted or accidental tap?",
                peak, store.config.min_peak_level,
                voiced * 100, store.config.min_voiced_fraction * 100))
            try? FileManager.default.removeItem(at: result.url)
            pill.hide()
            return
        }

        Log.write(String(format: "recorded %.2fs (peak %.2f, voiced %.0f%%) — transcribing…",
                         result.duration, peak, voiced * 100))

        isProcessing = true
        pill.show(state: .working)
        let config = store.config

        work.async { [weak self] in
            defer { try? FileManager.default.removeItem(at: result.url) }
            guard let self = self else { return }

            do {
                let transcriber = Transcriber(config: config)
                let raw = try transcriber.transcribe(wav: result.url)
                let lang = transcriber.result.language
                Log.write("transcript [\(lang)] (\(raw.count) chars): \(String(raw.prefix(120)))")
                if config.filter_hallucinations, Transcriber.isLikelyHallucination(raw) {
                    Log.write("discarded — known whisper hallucination: \"\(raw)\"")
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.pill.hide()
                    }
                    return
                }
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    Log.write("transcript empty — nothing to insert")
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.pill.hide()
                    }
                    return
                }

                let polished = Cleanup(config: config).polish(raw)
                History.add(text: polished, language: lang,
                            duration: result.duration, config: config.history)

                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.pill.hide()
                    self.lastTranscript = polished
                    let ax = TextInserter.hasAccessibility(prompt: false)
                    Log.write("inserting via \(config.insertion) — accessibility=\(ax ? "granted" : "NOT GRANTED (paste will silently fail)")")
                    // Keeping the text on the clipboard and restoring the old
                    // contents are mutually exclusive; keeping wins.
                    TextInserter.insert(polished,
                                        using: config.insertion,
                                        restoreClipboard: config.restore_clipboard
                                                          && !config.keep_in_clipboard)
                    if config.keep_in_clipboard && config.insertion.lowercased() == "type" {
                        // "type" never touches the pasteboard, so put it there now.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(polished, forType: .string)
                    }
                    self.rebuildMenu()
                }
            } catch {
                Log.write("Pipeline failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.flashError(Self.shortError(error))
                }
            }
        }
    }

    private static func shortError(_ error: Error) -> String {
        let msg = error.localizedDescription
        return msg.count > 34 ? String(msg.prefix(31)) + "…" : msg
    }

    private func flashError(_ message: String) {
        pill.show(state: .error(message))
        pill.hide(after: 2.4)
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshStatusIcon()
        rebuildMenu()
    }

    private func refreshStatusIcon() {
        guard let button = statusItem.button else { return }
        let name = isRecording ? "waveform.circle.fill"
                 : (isEnabled ? "waveform" : "waveform.slash")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Murmur")
        image?.isTemplate = true
        button.image = image
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let cfg = store.config

        let toggle = NSMenuItem(title: isEnabled ? "Dictation On" : "Dictation Off",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = isEnabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())

        // Status line: which backend will actually be used.
        let t = Transcriber(config: cfg)
        let backendLabel: String
        switch cfg.transcription_backend.lowercased() {
        case "local":  backendLabel = t.localIsAvailable() ? "Local whisper.cpp" : "Local (model missing!)"
        case "groq":   backendLabel = "Groq API"
        case "openai": backendLabel = "OpenAI API"
        default:
            if t.localIsAvailable() { backendLabel = "Local whisper.cpp (auto)" }
            else if Env.get("GROQ_API_KEY") != nil { backendLabel = "Groq API (auto)" }
            else if Env.get("OPENAI_API_KEY") != nil { backendLabel = "OpenAI API (auto)" }
            else { backendLabel = "⚠︎ No backend configured" }
        }
        let info = NSMenuItem(title: backendLabel, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)

        let hotkeyInfo = NSMenuItem(title: "Hold: \(prettyHotkey(cfg.hotkey))",
                                    action: nil, keyEquivalent: "")
        hotkeyInfo.isEnabled = false
        menu.addItem(hotkeyInfo)

        menu.addItem(.separator())

        // Hotkey picker
        let hotkeyMenu = NSMenu()
        for key in ["fn", "right_option", "left_option", "right_command",
                    "right_control", "right_shift"] {
            let item = NSMenuItem(title: prettyHotkey(key),
                                  action: #selector(selectHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = (cfg.hotkey == key) ? .on : .off
            hotkeyMenu.addItem(item)
        }
        let hotkeyParent = NSMenuItem(title: "Push-to-Talk Key", action: nil, keyEquivalent: "")
        menu.setSubmenu(hotkeyMenu, for: hotkeyParent)
        menu.addItem(hotkeyParent)

        // Insertion mode: paste at the caret, or copy only.
        let insertMenu = NSMenu()
        for (key, label) in [("paste", "Copiar y pegar (automático)"),
                             ("clipboard", "Solo copiar al portapapeles"),
                             ("type", "Escribir con el teclado")] {
            let item = NSMenuItem(title: label, action: #selector(selectInsertion(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = (cfg.insertion.lowercased() == key) ? .on : .off
            insertMenu.addItem(item)
        }
        let insertParent = NSMenuItem(title: "Al terminar…", action: nil, keyEquivalent: "")
        menu.setSubmenu(insertMenu, for: insertParent)
        menu.addItem(insertParent)

        let cleanup = NSMenuItem(title: "AI Cleanup",
                                 action: #selector(toggleCleanup), keyEquivalent: "")
        cleanup.target = self
        cleanup.state = cfg.cleanup.enabled ? .on : .off
        menu.addItem(cleanup)

        // Cleanup style: prose vs organized into title + numbered points.
        let styleMenu = NSMenu()
        for (key, label) in [("auto", "Auto — organiza si enumeras puntos"),
                             ("clean", "Solo limpiar (prosa)"),
                             ("structured", "Siempre título + puntos")] {
            let item = NSMenuItem(title: label, action: #selector(selectStyle(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = (cfg.cleanup.style.lowercased() == key) ? .on : .off
            styleMenu.addItem(item)
        }
        let styleParent = NSMenuItem(title: "Formato del texto", action: nil, keyEquivalent: "")
        menu.setSubmenu(styleMenu, for: styleParent)
        menu.addItem(styleParent)

        let langs = cfg.languages.isEmpty ? "todos" : cfg.languages.joined(separator: ", ")
        let langInfo = NSMenuItem(title: "Idiomas: \(langs)", action: nil, keyEquivalent: "")
        langInfo.isEnabled = false
        menu.addItem(langInfo)

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        if !lastTranscript.isEmpty {
            let last = NSMenuItem(title: "Copiar último: \"\(Self.preview(lastTranscript))\"",
                                  action: #selector(copyLastTranscript), keyEquivalent: "c")
            last.target = self
            menu.addItem(last)
        }

        // History: click any entry to copy it back to the clipboard.
        let entries = History.prune(History.load(), config: cfg.history)
        let historyMenu = NSMenu()
        if entries.isEmpty {
            let empty = NSMenuItem(title: "(sin dictados recientes)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
        } else {
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            for (i, e) in entries.prefix(15).enumerated() {
                let item = NSMenuItem(title: "\(df.string(from: e.timestamp))  \(Self.preview(e.text))",
                                      action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                historyMenu.addItem(item)
            }
            historyMenu.addItem(.separator())
            let open = NSMenuItem(title: "Abrir historial completo…",
                                  action: #selector(openHistory), keyEquivalent: "")
            open.target = self
            historyMenu.addItem(open)
            let clear = NSMenuItem(title: "Borrar historial",
                                   action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            historyMenu.addItem(clear)
        }
        let historyParent = NSMenuItem(
            title: "Historial (\(entries.count) · \(Int(cfg.history.retention_hours))h)",
            action: nil, keyEquivalent: "")
        menu.setSubmenu(historyMenu, for: historyParent)
        menu.addItem(historyParent)

        menu.addItem(.separator())

        let openConfig = NSMenuItem(title: "Edit Settings…",
                                    action: #selector(openConfig), keyEquivalent: ",")
        openConfig.target = self
        menu.addItem(openConfig)

        let reload = NSMenuItem(title: "Reload Settings",
                                action: #selector(reloadConfig), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        let openLog = NSMenuItem(title: "Show Log", action: #selector(openLog), keyEquivalent: "")
        openLog.target = self
        menu.addItem(openLog)

        let perms = NSMenuItem(title: "Check Permissions…",
                               action: #selector(checkPermissions), keyEquivalent: "")
        perms.target = self
        menu.addItem(perms)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Murmur", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func prettyHotkey(_ key: String) -> String {
        switch key {
        case "fn":            return "fn (Globe)"
        case "right_option":  return "Right ⌥"
        case "left_option":   return "Left ⌥"
        case "right_command": return "Right ⌘"
        case "left_command":  return "Left ⌘"
        case "right_control": return "Right ⌃"
        case "left_control":  return "Left ⌃"
        case "right_shift":   return "Right ⇧"
        case "left_shift":    return "Left ⇧"
        default:              return key
        }
    }

    // MARK: Menu actions

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        if !isEnabled, isRecording {
            _ = recorder.stop()
            isRecording = false
            pill.hide()
        }
        refreshStatusIcon()
        rebuildMenu()
    }

    @objc private func toggleCleanup() {
        store.setEnabledCleanup(!store.config.cleanup.enabled)
        rebuildMenu()
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        store.setHotkey(key)
        hotkey.setHotkey(key)
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
        rebuildMenu()
    }

    static func preview(_ text: String, limit: Int = 44) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    @objc private func selectInsertion(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        store.setInsertion(key)
        rebuildMenu()
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        store.setCleanupStyle(key)
        rebuildMenu()
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        let entries = History.prune(History.load(), config: store.config.history)
        guard sender.tag >= 0, sender.tag < entries.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries[sender.tag].text, forType: .string)
    }

    @objc private func openHistory() {
        let url = History.writeReadable(config: store.config.history)
        NSWorkspace.shared.open(url)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "¿Borrar el historial de dictado?"
        alert.informativeText = "Se eliminarán todas las transcripciones guardadas. No se puede deshacer."
        alert.addButton(withTitle: "Borrar")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            History.clear()
            lastTranscript = ""
            rebuildMenu()
        }
    }

    @objc private func copyLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(Paths.configFile)
    }

    @objc private func reloadConfig() {
        store.reload()
        Env.reload()
        hotkey.setHotkey(store.config.hotkey)
        rebuildMenu()
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Paths.logFile.path) {
            try? "".write(to: Paths.logFile, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(Paths.logFile)
    }

    @objc private func checkPermissions() {
        let ax = TextInserter.hasAccessibility(prompt: false)
        let mic = AudioRecorder.hasPermission
        _ = hotkey.start()
        // The only trustworthy signal: have we actually received a key event?
        let receiving = hotkey.hasSeenAnyEvent

        let alert = NSAlert()
        alert.messageText = "Murmur Permissions"
        alert.informativeText = """
        Microphone:     \(mic ? "granted" : "NOT granted")
        Accessibility:  \(ax ? "granted" : "NOT granted")

        Key events seen: \(receiving ? "YES — hotkey is live" : "NONE YET")

        If that says NONE YET: press a modifier key (⌘, ⌥, fn) a few \
        times, then open this dialog again. If it still says NONE, grant \
        Input Monitoring AND Accessibility, then quit and reopen Murmur.
        """
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Murmur needs Input Monitoring"
        alert.informativeText = """
        Murmur can't watch the push-to-talk key yet.

        Open System Settings ▸ Privacy & Security ▸ Input Monitoring \
        (and Accessibility) and enable Murmur, then relaunch the app.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Launch at login

enum LaunchAtLogin {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static func set(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            Log.write("Launch at login toggle failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Entry point

/// `Murmur --test-pipeline <file.wav>` runs the real transcribe → cleanup path
/// against a WAV and prints both stages, without touching the mic, the hotkey,
/// or your clipboard. Useful for checking backends and prompt tweaks.
if CommandLine.arguments.contains("--test-pipeline") {
    let args = CommandLine.arguments
    guard let idx = args.firstIndex(of: "--test-pipeline"), idx + 1 < args.count else {
        print("usage: Murmur --test-pipeline <file.wav>")
        exit(2)
    }
    let wav = URL(fileURLWithPath: (args[idx + 1] as NSString).expandingTildeInPath)
    let cfg = ConfigStore.loadOrCreate()
    let t = Transcriber(config: cfg)

    print("backend      : \(cfg.transcription_backend)")
    print("whisper-cli  : \(t.resolvedWhisperCLI() ?? "(none)")")
    print("model        : \(t.resolvedModel() ?? "(none)")")
    let c = Cleanup(config: cfg)
    print("cleanup      : \(cfg.cleanup.enabled ? (c.resolveProvider().map { $0.rawValue } ?? "no API key — will pass through") : "disabled")")
    print("---")

    do {
        let started = Date()
        let raw = try t.transcribe(wav: wav)
        let tTranscribe = Date().timeIntervalSince(started)
        print("RAW      (\(String(format: "%.2f", tTranscribe))s): \(raw)")

        // Mirror the recording path's guard so this command reflects what a
        // real dictation would actually produce.
        if cfg.filter_hallucinations, Transcriber.isLikelyHallucination(raw) {
            print("FILTERED: discarded as a known whisper hallucination — nothing would be inserted.")
            exit(0)
        }

        let mid = Date()
        let polished = c.polish(raw)
        let tClean = Date().timeIntervalSince(mid)
        print("CLEANED  (\(String(format: "%.2f", tClean))s): \(polished)")
        exit(0)
    } catch {
        print("FAILED: \(error.localizedDescription)")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
