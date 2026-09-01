import Foundation

/// `Murmur --doctor` — one command that answers "why isn't it working?".
///
/// It exists because every failure in the pipeline used to surface as the same
/// two words in the recording pill. This walks the whole chain in order — config,
/// local whisper.cpp, keys, network, permissions — and prints what it actually
/// found at each step, including a live request to every provider that has a key.
final class Doctor {

    /// The report as text, plus whether anything blocking was found.
    static func report() -> (text: String, ok: Bool) {
        let d = Doctor()
        let ok = d.build()
        return (d.out.joined(separator: "\n") + "\n", ok)
    }

    /// Terminal entry point for `--doctor`.
    static func run() -> Int32 {
        let (text, ok) = report()
        print(text, terminator: "")
        return ok ? 0 : 1
    }

    /// Writes the report next to the log and returns its URL, for the
    /// "Run Diagnostics…" menu item — the menu-bar app has no terminal.
    @discardableResult
    static func writeReport() -> URL {
        let url = Paths.configDir.appendingPathComponent("diagnostics.txt")
        try? report().text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private var out: [String] = []

    private func build() -> Bool {
        let cfg = ConfigStore.loadOrCreate()
        let transcriber = Transcriber(config: cfg)
        let cleanup = Cleanup(config: cfg)
        var problems: [String] = []
        var notes: [String] = []

        header("Murmur doctor")

        // MARK: Config
        section("Config")
        let cfgExists = FileManager.default.fileExists(atPath: Paths.configFile.path)
        row("file", "\(Paths.configFile.path)\(cfgExists ? "" : "  (missing — defaults in use)")")
        if cfgExists, let data = try? Data(contentsOf: Paths.configFile),
           (try? JSONDecoder().decode(Config.self, from: data)) == nil {
            row("parse", "FAILED — config.json is not valid JSON, every setting fell back to its default")
            problems.append("config.json is not valid JSON. Fix it or delete it to regenerate defaults.")
        }
        row("backend", cfg.transcription_backend)
        row("hotkey", cfg.hotkey)
        row("insertion", cfg.insertion)
        row("language", "\(cfg.language)  (allowed: \(cfg.languages.isEmpty ? "any" : cfg.languages.joined(separator: ", ")))")
        row("cleanup", cfg.cleanup.enabled
            ? "on — provider=\(cfg.cleanup.provider), style=\(cfg.cleanup.style), fallback=\(cfg.cleanup.fallback_provider.isEmpty ? "none" : cfg.cleanup.fallback_provider)"
            : "off")

        // MARK: Local backend
        section("Local whisper.cpp")
        let cli = transcriber.resolvedWhisperCLI()
        row("whisper-cli", cli ?? "NOT FOUND — brew install whisper-cpp")
        let model = transcriber.resolvedModel()
        row("model", model.map { "\($0)  (\(self.fileSize($0)))" } ?? "NOT FOUND")
        row("models dir", modelsDirSummary())
        let localReady = transcriber.localIsAvailable()
        row("status", localReady ? "READY — dictation works with no network at all" : "unavailable")
        if !localReady {
            notes.append("Local transcription is unavailable, so every dictation depends on a hosted API. `./bootstrap.sh` installs whisper.cpp and the model.")
        }

        // MARK: Keys
        section("API keys (\(Paths.envFile.path))")
        if !FileManager.default.fileExists(atPath: Paths.envFile.path) {
            row(".env", "missing")
        }
        for name in ["GROQ_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "XAI_API_KEY"] {
            if let key = Env.get(name) {
                if Env.isPlaceholder(key) {
                    row(name, "PLACEHOLDER (\(mask(key))) — still the template value")
                    problems.append("\(name) is still a placeholder.")
                } else {
                    row(name, "set (\(mask(key)), \(key.count) chars)")
                }
            } else {
                row(name, "not set")
            }
        }

        // MARK: Plan
        section("Transcription plan (first one that works wins)")
        let plan = transcriber.backendPlan()
        if plan.isEmpty {
            row("1", "NOTHING AVAILABLE — no local model and no API key")
            problems.append("No transcription backend at all: install a local model or add a key.")
        } else {
            for (i, backend) in plan.enumerated() { row("\(i + 1)", backend.label) }
        }

        // MARK: Live network checks
        section("Connectivity")
        var probed = false
        for provider in [Cleanup.Provider.groq, .openai, .anthropic, .xai] {
            guard let key = Env.get(provider.keyName) else { continue }
            probed = true
            let result = probe(provider: provider, key: key)
            row(provider.host, result.line)
            if let problem = result.problem { problems.append(problem) }
        }
        // A custom base_url (Ollama, LM Studio, llama.cpp) is the other common
        // "unreachable": the server simply isn't running on that port.
        if cfg.cleanup.enabled, !cfg.cleanup.base_url.isEmpty {
            var base = cfg.cleanup.base_url
            while base.hasSuffix("/") { base.removeLast() }
            if let url = URL(string: base + "/models") {
                var req = URLRequest(url: url)
                req.timeoutInterval = 8
                row("base_url", "\(base) — \(probeRaw(req).line)")
                probed = true
            }
        }
        if !probed {
            row("—", "no keys set, nothing to probe")
        }

        // MARK: Permissions
        section("Permissions")
        let mic = AudioRecorder.hasPermission
        let ax = TextInserter.hasAccessibility(prompt: false)
        row("Microphone", mic ? "granted" : "NOT granted — Murmur will record silence")
        row("Accessibility", ax ? "granted" : "NOT granted — the ⌘V that pastes your text will do nothing")
        // Input Monitoring can only be told apart by actually receiving an
        // event, which needs the running app — Check Permissions… in the menu
        // reports it live.
        row("Input Monitoring", "check from the menu-bar item (needs a live key press)")
        if !mic { problems.append("Microphone permission is not granted.") }
        if !ax && cfg.insertion.lowercased() != "clipboard" {
            problems.append("Accessibility is not granted, so pasting will silently fail.")
        }

        section("Files")
        row("log", Paths.logFile.path)
        row("models", Paths.modelsDir.path)

        // MARK: Verdict
        section("Summary")
        if localReady {
            emit("  ✓ Local transcription is ready — a blocked or expired API cannot stop dictation.")
        }
        if cfg.cleanup.enabled && cleanup.resolveProvider() == nil {
            emit("  ! Cleanup is on but no provider has a key — transcripts will be inserted raw.")
        }
        for note in notes { emit("  ! \(note)") }
        if problems.isEmpty {
            emit("  ✓ No blocking problems found.")
            emit("")
            return true
        }
        for problem in problems { emit("  ✗ \(problem)") }
        emit("")
        return false
    }

    // MARK: - Live probes

    private struct ProbeResult {
        let line: String
        let problem: String?
    }

    /// Two requests per provider, because they fail independently: listing
    /// models proves the host is reachable and the key is valid, while a real
    /// completion is what a VPN-blocked IP actually gets refused on. Groq is
    /// the reason both are needed — its /v1/models answers from any address
    /// while /chat/completions returns 403, so testing only the first says
    /// "everything is fine" about a setup that cannot transcribe a word.
    private func probe(provider: Cleanup.Provider, key: String) -> ProbeResult {
        let base = provider.defaultBase
        guard let listURL = URL(string: base + "/models") else {
            return ProbeResult(line: "malformed base URL '\(base)'",
                               problem: "\(provider.rawValue) has a malformed base URL.")
        }
        var listReq = URLRequest(url: listURL)
        listReq.timeoutInterval = 12
        authorize(&listReq, provider: provider, key: key)

        let list = probeRaw(listReq)
        guard list.status != nil else {
            return ProbeResult(line: list.line,
                               problem: "\(provider.host) is unreachable: \(list.line)")
        }
        if list.status == 401 || list.status == 403 {
            return ProbeResult(line: "\(list.line) — the key is being rejected",
                               problem: "\(provider.keyName) was rejected by \(provider.host) (HTTP \(list.status!)).")
        }

        // Cheapest possible real completion: one token, no thinking.
        var chatReq = URLRequest(url: provider.endpoint(base: ""))
        chatReq.httpMethod = "POST"
        chatReq.timeoutInterval = 20
        chatReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&chatReq, provider: provider, key: key)
        let payload: [String: Any] = ["model": provider.defaultModel, "max_tokens": 1,
                                      "messages": [["role": "user", "content": "hi"]]]
        chatReq.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let chat = probeRaw(chatReq)

        if let status = chat.status, (200..<300).contains(status) {
            return ProbeResult(line: "OK — reachable, key valid, completions work (\(chat.line))",
                               problem: nil)
        }
        let detail = chat.line
        if chat.status == 403 && provider == .groq {
            return ProbeResult(
                line: "models OK, but completions returned 403 — Groq blocks VPN and datacenter IPs",
                problem: "Groq refuses this network (403 on completions). Turn the VPN off, or rely on the fallback provider.")
        }
        if chat.status == 404 || chat.status == 400 {
            return ProbeResult(line: "reachable, key OK, but model '\(provider.defaultModel)' was refused (\(detail))",
                               problem: nil)
        }
        return ProbeResult(line: "models OK, completions failed: \(detail)",
                           problem: "\(provider.host) accepted the key but refused a completion: \(detail)")
    }

    private func authorize(_ req: inout URLRequest, provider: Cleanup.Provider, key: String) {
        if provider.usesAnthropicSchema {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private struct RawProbe {
        let status: Int?
        let line: String
    }

    private func probeRaw(_ request: URLRequest) -> RawProbe {
        let started = Date()
        do {
            let (data, response) = try HTTP.sendSync(request)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(status) {
                return RawProbe(status: status, line: "HTTP \(status) in \(ms) ms")
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
            return RawProbe(status: status, line: "HTTP \(status) in \(ms) ms — \(snippet)")
        } catch {
            return RawProbe(status: nil, line: error.localizedDescription)
        }
    }

    // MARK: - Formatting

    private func emit(_ line: String) { out.append(line) }

    private func header(_ text: String) {
        emit("")
        emit(text)
        emit(String(repeating: "=", count: text.count))
    }

    private func section(_ text: String) {
        emit("")
        emit(text)
    }

    private func row(_ label: String, _ value: String) {
        let padded = label.padding(toLength: max(18, label.count), withPad: " ", startingAt: 0)
        emit("  \(padded): \(value)")
    }

    /// Never print a key. Enough characters to recognise which one it is, and
    /// the length, which is what catches a truncated paste.
    private func mask(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: key.count) }
        return "\(key.prefix(5))…\(key.suffix(4))"
    }

    private func fileSize(_ path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let bytes = (attrs?[.size] as? NSNumber)?.doubleValue ?? 0
        return String(format: "%.1f MB", bytes / 1_048_576)
    }

    private func modelsDirSummary() -> String {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Paths.modelsDir.path) else {
            return "\(Paths.modelsDir.path) — unreadable or missing"
        }
        let models = names.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }.sorted()
        if models.isEmpty {
            let others = names.filter { !$0.hasPrefix(".") }
            return others.isEmpty
                ? "empty"
                : "no ggml-*.bin — found instead: \(others.prefix(5).joined(separator: ", "))"
        }
        return models.joined(separator: ", ")
    }
}
