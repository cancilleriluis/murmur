import AppKit
import ServiceManagement

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = ConfigStore()
    private let hotkey = HotKeyMonitor()
    private let pill = RecordingPill()
    private let recorder = AudioRecorder()

    private var statusItem: NSStatusItem!
    private var isEnabled = true
    private var isRecording = false
    /// Takes released but not yet inserted or discarded. You can start the
    /// next dictation while earlier ones are still transcribing; `work` is
    /// serial, so they still land in the order you spoke them.
    private var pendingJobs = 0
    /// Kept so it can be re-copied from the menu if the paste went nowhere.
    private var lastTranscript: String = ""
    /// Newer commits on GitHub's main than this build, from the last check.
    private var pendingUpdate: Updater.Status?
    private var updateTimer: Timer?

    private let work = DispatchQueue(label: "murmur.pipeline", qos: .userInitiated)

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon

        buildStatusItem()
        wireHotkey()

        recorder.onLevel = { [weak self] level in self?.pill.update(level: level) }
        recorder.setWarmSeconds(store.config.mic_warm_seconds)
        // Loads the model in the background so the first dictation is fast too.
        WhisperServer.shared.configure(store.config)

        // Ask for mic up front so the first dictation isn't eaten by a prompt.
        AudioRecorder.requestPermission { granted in
            if !granted { Log.write("Microphone permission not granted.") }
        }

        Log.write("signature: \(Self.signingSummary()) · \(Bundle.main.bundlePath)")
        healAccessibilityIfNeeded()

        if !hotkey.start() {
            showPermissionAlert()
        }

        // Look for a newer version now and every few hours; the menu shows
        // an "Actualizar" item when there is one.
        checkForUpdates(interactive: false)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates(interactive: false)
        }

        Log.write("Murmur started (build \(Updater.buildCommit)). hotkey=\(store.config.hotkey) backend=\(store.config.transcription_backend)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        WhisperServer.shared.stop()
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
        guard isEnabled, !isRecording else {
            Log.write("press ignored (enabled=\(isEnabled) recording=\(isRecording))")
            return
        }
        guard AudioRecorder.hasPermission else {
            Log.write("press ignored — MICROPHONE NOT GRANTED. Requesting…")
            AudioRecorder.requestPermission { ok in
                Log.write("microphone permission result: \(ok ? "granted" : "DENIED")")
            }
            return
        }

        // Feedback first, hardware second: the pill answers the keypress
        // itself, while the input device spins up off the main thread.
        isRecording = true
        pill.show(state: .recording)
        refreshStatusIcon()
        Prewarm.connections(for: store.config)

        let pressed = Date()
        recorder.start { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    Log.write("Failed to start recording: \(error.localizedDescription)")
                    if self.isRecording {
                        self.isRecording = false
                        self.refreshStatusIcon()
                    }
                    self.flashError("Mic error")
                    return
                }
                Log.write(String(format: "recording started (mic ready in %.0f ms)",
                                 Date().timeIntervalSince(pressed) * 1000))
            }
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        refreshStatusIcon()
        pendingJobs += 1
        // Straight to "working": this take may queue behind an earlier one,
        // and a discarded tap only flashes it for a moment.
        pill.show(state: .working)

        let config = store.config
        let released = Date()
        recorder.stop { [weak self] take in
            self?.work.async { self?.process(take, config: config, released: released) }
        }
    }

    /// Runs on `work`, one take at a time.
    private func process(_ take: AudioRecorder.Take?, config: Config, released: Date) {
        guard let take = take else {
            Log.write("stopped — no usable audio captured (mic silent or blocked?)")
            finishJob()
            return
        }
        defer { try? FileManager.default.removeItem(at: take.url) }

        // Ignore accidental taps.
        guard take.duration >= config.min_recording_seconds else {
            Log.write(String(format: "stopped — too short (%.2fs < %.2fs), discarded",
                             take.duration, config.min_recording_seconds))
            finishJob()
            return
        }
        // Silence gate — whisper invents speech from room tone, so a take that
        // never reached speech level must not reach it at all.
        let peak = Double(take.peakLevel)
        let voiced = take.voicedFraction
        if config.min_peak_level > 0,
           peak < config.min_peak_level || voiced < config.min_voiced_fraction {
            Log.write(String(format:
                "discarded — too quiet (peak %.2f < %.2f, voiced %.0f%% < %.0f%%). Mic muted or accidental tap?",
                peak, config.min_peak_level,
                voiced * 100, config.min_voiced_fraction * 100))
            finishJob()
            return
        }

        Log.write(String(format: "recorded %.2fs (peak %.2f, voiced %.0f%%) — transcribing…",
                         take.duration, peak, voiced * 100))

        do {
            let t0 = Date()
            let transcriber = Transcriber(config: config)
            let raw = try transcriber.transcribe(wav: take.url)
            let tTranscribe = Date().timeIntervalSince(t0)
            let lang = transcriber.result.language
            Log.write("transcript [\(lang)] (\(raw.count) chars): \(String(raw.prefix(120)))")
            if config.filter_hallucinations, Transcriber.isLikelyHallucination(raw) {
                Log.write("discarded — known whisper hallucination: \"\(raw)\"")
                finishJob()
                return
            }
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Log.write("transcript empty — nothing to insert")
                finishJob()
                return
            }

            let t1 = Date()
            let polished = Cleanup(config: config).polish(raw)
            let tCleanup = Date().timeIntervalSince(t1)
            History.add(text: polished, language: lang,
                        duration: take.duration, config: config.history)
            Log.write(String(format: "timing: release → text %.2fs (transcribe %.2fs, cleanup %.2fs)",
                             Date().timeIntervalSince(released), tTranscribe, tCleanup))

            DispatchQueue.main.async {
                self.lastTranscript = polished
                let ax = TextInserter.hasAccessibility(prompt: false)
                var mode = config.insertion.lowercased()
                var notice: String?
                if !ax && mode != "clipboard" {
                    // macOS drops synthetic ⌘V / keystrokes from an untrusted
                    // app without any error, so the dictation would vanish.
                    // Leave it on the clipboard instead and say so.
                    mode = "clipboard"
                    notice = "Sin Accesibilidad · pega con ⌘V"
                    Log.write("accessibility NOT GRANTED — copied to clipboard instead of pasting. Use menu ▸ Arreglar permiso de Accesibilidad.")
                } else {
                    Log.write("inserting via \(mode) — accessibility=\(ax ? "granted" : "not needed")")
                }
                // Keeping the text on the clipboard and restoring the old
                // contents are mutually exclusive; keeping wins.
                TextInserter.insert(polished,
                                    using: mode,
                                    restoreClipboard: config.restore_clipboard
                                                      && !config.keep_in_clipboard)
                if config.keep_in_clipboard && mode == "type" {
                    // "type" never touches the pasteboard, so put it there now.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(polished, forType: .string)
                }
                self.rebuildMenu()
                self.finishJob(error: notice)
            }
        } catch {
            Log.write("Pipeline failed: \(error.localizedDescription)")
            finishJob(error: Self.shortError(error))
        }
    }

    /// Marks one take done (inserted, discarded or failed); safe from any
    /// thread. The pill stays up while you're recording or anything is queued.
    private func finishJob(error: String? = nil) {
        DispatchQueue.main.async {
            self.pendingJobs = max(0, self.pendingJobs - 1)
            if self.isRecording { return }
            if let error = error {
                self.flashError(error)
            } else if self.pendingJobs == 0 {
                self.pill.hide()
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
        button.image = WaveShape.menuBarImage(recording: isRecording, enabled: isEnabled)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let cfg = store.config

        // After a rebuild with a new signature, System Settings keeps showing
        // the old grant as enabled while this build is denied. Offer the fix
        // right at the top instead of failing silently on every paste.
        if let update = pendingUpdate, update.behind > 0 {
            let item = NSMenuItem(title: "⬆︎ Actualizar Murmur (\(update.behind) cambio\(update.behind == 1 ? "" : "s"))…",
                                  action: #selector(installUpdate), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if !TextInserter.hasAccessibility(prompt: false) {
            let fix = NSMenuItem(title: "⚠︎ Arreglar permiso de Accesibilidad…",
                                 action: #selector(fixAccessibility), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: isEnabled ? "Dictation On" : "Dictation Off",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = isEnabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())

        // Status line: which backend will actually be used.
        let t = Transcriber(config: cfg)
        let serverTag = WhisperServer.shared.isReady ? " · model loaded" : ""
        let backendLabel: String
        switch cfg.transcription_backend.lowercased() {
        case "local":  backendLabel = t.localIsAvailable() ? "Local whisper.cpp\(serverTag)" : "Local (model missing!)"
        case "groq":   backendLabel = "Groq API"
        case "openai": backendLabel = "OpenAI API"
        default:
            if t.localIsAvailable() { backendLabel = "Local whisper.cpp (auto)\(serverTag)" }
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

        let updates = NSMenuItem(title: "Buscar actualizaciones…",
                                 action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

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
            recorder.cancel()
            isRecording = false
            if pendingJobs == 0 { pill.hide() }
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
        hotkey.debugLogging = store.config.debug_hotkey
        recorder.setWarmSeconds(store.config.mic_warm_seconds)
        WhisperServer.shared.configure(store.config)
        rebuildMenu()
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Paths.logFile.path) {
            try? "".write(to: Paths.logFile, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(Paths.logFile)
    }

    // MARK: Accessibility

    private var accessibilityWatch: Timer?

    /// System Settings keeps showing an older build's grant as "on" while
    /// this build — signed differently — is denied, and flipping that switch
    /// changes nothing. So on launch, if we're not trusted, delete our stale
    /// entry (once per build, so a "not now" isn't undone on every launch),
    /// ask macOS to prompt, and relaunch by ourselves the moment it's granted.
    /// The one click left is the one macOS reserves for a person.
    private func healAccessibilityIfNeeded() {
        guard !TextInserter.hasAccessibility(prompt: false) else { return }
        let key = "accessibilityResetForBuild"
        if UserDefaults.standard.string(forKey: key) != Updater.buildCommit {
            UserDefaults.standard.set(Updater.buildCommit, forKey: key)
            resetAccessibilityEntry()
        }
        TextInserter.hasAccessibility(prompt: true)
        watchForAccessibilityGrant()
    }

    @objc private func fixAccessibility() {
        resetAccessibilityEntry()
        TextInserter.hasAccessibility(prompt: true)
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        watchForAccessibilityGrant()
        rebuildMenu()
    }

    private func resetAccessibilityEntry() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.murmur.dictation"
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", bundleID]
        reset.standardOutput = FileHandle.nullDevice
        reset.standardError = FileHandle.nullDevice
        do {
            try reset.run()
            reset.waitUntilExit()
            Log.write("cleared stale Accessibility entry for \(bundleID) (tccutil status \(reset.terminationStatus))")
        } catch {
            Log.write("tccutil reset failed: \(error.localizedDescription)")
        }
    }

    /// Polls until the switch is on, then restarts Murmur so the grant
    /// applies to everything, with no "quit and reopen" step for you.
    private func watchForAccessibilityGrant() {
        accessibilityWatch?.invalidate()
        let started = Date()
        accessibilityWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if TextInserter.hasAccessibility(prompt: false) {
                timer.invalidate()
                Log.write("Accessibility granted — relaunching")
                self.relaunch()
            } else if Date().timeIntervalSince(started) > 600 {
                timer.invalidate()   // gave up waiting; the menu item stays
            }
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 1; open \"$0\"", path]
        try? proc.run()
        NSApp.terminate(nil)
    }

    /// "Murmur Self-Signed" when built after ./setup-signing.sh; "ad-hoc"
    /// means every rebuild looks like a new app to macOS.
    static func signingSummary() -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-dvv", Bundle.main.bundlePath]
        let pipe = Pipe()
        proc.standardError = pipe          // codesign -d prints to stderr
        proc.standardOutput = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return "unknown" }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        proc.waitUntilExit()
        if out.contains("Signature=adhoc") { return "ad-hoc (permissions reset on every rebuild)" }
        if let line = out.split(separator: "\n").first(where: { $0.hasPrefix("Authority=") }) {
            return String(line)
        }
        return "unknown"
    }

    // MARK: Updates

    @objc private func checkForUpdatesFromMenu() {
        checkForUpdates(interactive: true)
    }

    private func checkForUpdates(interactive: Bool) {
        DispatchQueue.global(qos: .utility).async {
            let status = Updater.check()
            DispatchQueue.main.async {
                self.pendingUpdate = status
                self.rebuildMenu()
                guard interactive else { return }
                if Updater.sourceDir == nil {
                    self.showInfo("No sé dónde está el código de Murmur",
                                  "Esta versión se compiló antes de que existieran las actualizaciones desde el menú. Actualiza una última vez a mano:\n\ncd ~/Murmur && git checkout main && git pull && ./build.sh --install")
                } else if let status = status, status.behind > 0 {
                    self.installUpdate()
                } else if status == nil {
                    self.showInfo("No se pudo comprobar", "No he podido contactar con GitHub. Revisa la conexión e inténtalo de nuevo.")
                } else {
                    self.showInfo("Murmur está al día", "Tienes la última versión (\(Updater.buildCommit)).")
                }
            }
        }
    }

    @objc private func installUpdate() {
        let changes = (pendingUpdate?.summary ?? []).prefix(8).map { "• \($0)" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Actualizar Murmur"
        alert.informativeText = """
        \(changes.isEmpty ? "Hay una versión nueva en GitHub." : changes)

        Se descarga y se compila en este Mac (1–2 minutos). Murmur se \
        cerrará y volverá a abrirse solo.
        """
        alert.addButton(withTitle: "Actualizar")
        alert.addButton(withTitle: "Ahora no")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        pill.show(state: .working)
        Updater.install { [weak self] in
            self?.pill.hide()
            let fail = NSAlert()
            fail.messageText = "La actualización falló"
            fail.informativeText = "Murmur sigue funcionando con la versión actual. Los detalles están en update.log."
            fail.addButton(withTitle: "Ver detalles")
            fail.addButton(withTitle: "Cerrar")
            NSApp.activate(ignoringOtherApps: true)
            if fail.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Updater.logFile)
            }
        }
    }

    private func showInfo(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
    let serverUp = WhisperServer.shared.configureAndWait(cfg)

    print("backend      : \(cfg.transcription_backend)")
    print("whisper-cli  : \(t.resolvedWhisperCLI() ?? "(none)")")
    print("model        : \(t.resolvedModel() ?? "(none)")")
    print("whisper-server: \(serverUp ? "running (model resident)" : "not used — whisper-cli per run")")
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
            WhisperServer.shared.stop()
            exit(0)
        }

        let mid = Date()
        let polished = c.polish(raw)
        let tClean = Date().timeIntervalSince(mid)
        print("CLEANED  (\(String(format: "%.2f", tClean))s): \(polished)")
        WhisperServer.shared.stop()
        exit(0)
    } catch {
        print("FAILED: \(error.localizedDescription)")
        WhisperServer.shared.stop()
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
