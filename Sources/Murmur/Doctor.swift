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
        row("timeouts", String(format: "transcription %.0fs, cleanup %.0fs — how long a hung provider stalls a dictation",
                               cfg.api_timeout_seconds, cfg.cleanup.timeout_seconds))

        // MARK: Local backend
        section("Local whisper.cpp")
        let cli = transcriber.resolvedWhisperCLI()
        row("whisper-cli", cli ?? "NOT FOUND — brew install whisper-cpp")
        let model = transcriber.resolvedModel()
        row("model", model.map { "\($0)  (\(self.fileSize($0)))" } ?? "NOT FOUND")
        row("models dir", modelsDirSummary())
        let localReady = transcriber.localIsAvailable()
        row("status", localReady ? "READY — dictation works with no network at all" : "unavailable")
        if localReady {
            row("threads", "\(Transcriber.threadCount(config: cfg))  (performance cores; whisper_threads overrides)")
            row("beam size", "\(max(1, cfg.whisper_beam_size))\(cfg.whisper_beam_size <= 1 ? "  (greedy — fastest)" : "  (beam search — slower)")")
            if let cliPath = cli {
                row("flash attn", Transcriber.useFlashAttention(config: cfg, cli: cliPath) ? "on" : "off (not supported by this whisper-cli, or disabled)")
            }
            // A real run, so "it feels slow" becomes a number. The first one
            // after a reboot or rebuild includes the Metal shader compile and
            // will be several seconds; the ones after it are the real figure.
            if let seconds = transcriber.warmUp(force: true) {
                row("speed", String(format: "%.2fs for a 0.5s clip%@", seconds,
                                    seconds > 4 ? "  — SLOW. Rerun: if it stays high it is not the shader compile." : ""))
                if seconds > 8 {
                    problems.append(String(format: "Local transcription took %.1fs on a half-second clip. Try a smaller model, or pin whisper_threads.", seconds))
                }
            }
        }
        if !localReady {
            // Say which half is missing. "unavailable" on its own sent people
            // to rerun a bootstrap that had already done its job.
            if cli == nil {
                // "brew install whisper-cpp" is not advice if brew itself is
                // missing or off the PATH, which is the state that produced
                // this in the first place.
                problems.append("whisper-cli is not installed. \(Doctor.homebrewAdvice()) Until then every dictation needs a working API key and an unblocked network.")
            }
            if model == nil {
                let stubs = suspiciousModelFiles()
                if stubs.isEmpty {
                    problems.append("No speech model in \(Paths.modelsDir.path) — `./bootstrap.sh` downloads one (~465 MB).")
                } else {
                    // A file that is named like a model but isn't one. curl
                    // without -f writes the server's error page to the output
                    // file and still exits 0, so a failed download leaves a
                    // few KB of HTML called ggml-small.bin and every later
                    // check happily reports "model already present".
                    problems.append("\(stubs.joined(separator: ", ")) — that is a failed download, not a model. Delete it and rerun ./bootstrap.sh.")
                }
            }
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
        var working: [String] = []
        for provider in [Cleanup.Provider.groq, .openai, .anthropic, .xai] {
            guard let key = Env.get(provider.keyName) else { continue }
            probed = true
            let result = probe(provider: provider, key: key)
            row(provider.host, result.line)
            if let problem = result.problem { problems.append(problem) } else { working.append(provider.rawValue) }
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
        } else {
            // The one combination that means dictation is dead right now, and
            // the one worth spelling out rather than leaving as two separate
            // bullet points the reader has to combine.
            let transcribers = working.filter { $0 == "groq" || $0 == "openai" }
            if transcribers.isEmpty {
                emit("  ✗ Nothing can transcribe: no local model, and no hosted provider is answering.")
                emit("    Shortest way out is local — it removes the network from the equation entirely:")
                emit("      cd ~/Murmur && ./bootstrap.sh")
            } else {
                emit("  ! Transcription is working through \(transcribers.joined(separator: " / ")) only.")
                emit("    That is one blocked network or expired key away from stopping. `./bootstrap.sh`")
                emit("    installs the local model and makes the hosted providers a fallback instead.")
            }
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
        if list.status == 401 {
            return ProbeResult(line: "\(list.line) — the key is being rejected",
                               problem: "\(provider.keyName) was rejected by \(provider.host) (401). The key is wrong, expired, or revoked.")
        }
        if list.status == 403 {
            // 403 is NOT 401. Reporting it as a bad key sends you off to
            // regenerate a key that was fine all along — which is the exact
            // trap this repo already documents for Groq, and which this
            // function walked straight into. Let the response body decide.
            return classifyForbidden(list, provider: provider)
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

    /// A 403 means "I know who you are and I still won't serve you", which for
    /// these providers is almost always about *where the request came from*,
    /// not the key. Groq refuses VPN, datacenter and some regional IPs with a
    /// plain "Access denied. Please check your network settings." — no header,
    /// no retry and no new key gets past it.
    private func classifyForbidden(_ probe: RawProbe, provider: Cleanup.Provider) -> ProbeResult {
        let body = probe.line.lowercased()
        let saysKey = body.contains("invalid_api_key") || body.contains("invalid api key")
            || body.contains("authentication") || body.contains("unauthorized")
        let saysNetwork = body.contains("network settings") || body.contains("access denied")
            || body.contains("cloudflare") || body.contains("region")
            || body.contains("not available in your")

        if saysKey && !saysNetwork {
            return ProbeResult(line: "\(probe.line) — the key is being rejected",
                               problem: "\(provider.keyName) was rejected by \(provider.host) (403, and the response names the key).")
        }
        if saysNetwork || provider == .groq {
            return ProbeResult(
                line: "\(probe.line) — this is the NETWORK being refused, not the key",
                problem: "\(provider.host) refuses this IP address (403). \(provider == .groq ? "Groq blocks VPN, datacenter and some regional addresses" : "The provider is blocking this network or region") — a new key will not help. Turn any VPN off and rerun, or stop depending on it by installing the local model.")
        }
        return ProbeResult(line: "\(probe.line) — 403, cause unclear from the response",
                           problem: "\(provider.host) returned 403. Read the response text above: if it names the key, replace it; if it mentions the network or your region, the key is fine and the IP is blocked.")
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

    /// Files named like a model that cannot be one — too small, or not
    /// actually in ggml format. Returned as ready-to-read descriptions.
    private func suspiciousModelFiles() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Paths.modelsDir.path) else { return [] }
        return names
            .filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }
            .sorted()
            .compactMap { name in
                let path = Paths.modelsDir.appendingPathComponent(name).path
                let bytes = ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
                if bytes < 1_000_000 { return "\(name) is only \(bytes) bytes" }
                if !Doctor.looksLikeGGML(path) { return "\(name) is not in ggml format" }
                return nil
            }
    }

    /// Homebrew has three states worth telling apart, and only one of them is
    /// fixed by "run brew install".
    static func homebrewAdvice() -> String {
        let fm = FileManager.default
        let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .contains { fm.isExecutableFile(atPath: "\($0)/brew") }
        let installed = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { fm.isExecutableFile(atPath: $0) }

        if onPath || installed != nil {
            let brew = installed ?? "brew"
            if !onPath, let path = installed {
                return "Homebrew is installed at \(path) but is not on your PATH, which is why `brew` reports command-not-found. Run: `\(brew) install whisper-cpp` (and `echo 'eval \"$(\(path) shellenv)\"' >> ~/.zprofile` to fix your shell)."
            }
            return "Install it with `\(brew) install whisper-cpp`."
        }
        return "Homebrew is not installed either — get it from https://brew.sh, follow the 'Next steps' it prints, then `brew install whisper-cpp`."
    }

    /// True if the file starts with a whisper model's magic number.
    ///
    /// The magic is `0x67676d6c`, written as a **native-endian uint32** — so on
    /// disk, on every machine this runs on, the bytes are `6c 6d 67 67` and the
    /// file reads "lmgg", not "ggml". Comparing against the literal "ggml" is
    /// the obvious mistake and it declares every real model corrupt. Newer
    /// GGUF-packaged models are accepted too.
    static func looksLikeGGML(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        let ggml = Data([0x6c, 0x6d, 0x67, 0x67])   // 0x67676d6c little-endian, "lmgg"
        let gguf = Data([0x47, 0x47, 0x55, 0x46])   // "GGUF"
        return magic == ggml || magic == gguf
    }

    private func modelsDirSummary() -> String {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Paths.modelsDir.path) else {
            return "\(Paths.modelsDir.path) — unreadable or missing"
        }
        let models = names.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }.sorted()
        if !models.isEmpty {
            // Sizes, because "ggml-small.bin is present" and "ggml-small.bin is
            // a usable model" are different statements and only one of them is
            // worth printing.
            return models.map { name in
                let path = Paths.modelsDir.appendingPathComponent(name).path
                let ok = Doctor.looksLikeGGML(path)
                return "\(name) (\(self.fileSize(path))\(ok ? "" : ", NOT a ggml file"))"
            }.joined(separator: ", ")
        }
        let others = names.filter { !$0.hasPrefix(".") }
        return others.isEmpty
            ? "empty"
            : "no ggml-*.bin — found instead: \(others.prefix(5).joined(separator: ", "))"
    }
}
