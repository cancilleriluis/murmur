import Foundation

/// Runs the raw transcript through an LLM that strips filler words, fixes
/// punctuation and casing, and otherwise leaves the words alone.
///
/// Failure here is never fatal: if the key is missing or the call errors, the
/// caller keeps the raw transcript rather than losing the user's speech.
struct Cleanup {
    let config: Config

    enum Provider: String {
        case groq, openai, anthropic, xai, local

        var keyName: String {
            switch self {
            case .groq:      return "GROQ_API_KEY"
            case .openai:    return "OPENAI_API_KEY"
            case .anthropic: return "ANTHROPIC_API_KEY"
            case .xai:       return "XAI_API_KEY"
            case .local:     return "MURMUR_LOCAL_KEY"   // usually unset; not required
            }
        }
        /// Local OpenAI-compatible servers don't authenticate.
        var requiresKey: Bool { self != .local }
        /// Small + fast by default: dictation cleanup is latency-critical and
        /// the task is mechanical. Override with `cleanup.model` in config.json.
        /// Measured on real dictations (see README → What it costs): latency
        /// matters more than price here, so each default is the fastest model
        /// of its provider that still passes the language and structure checks.
        var defaultModel: String {
            switch self {
            case .groq:      return "llama-3.3-70b-versatile"
            case .openai:    return "gpt-4o-mini"
            case .anthropic: return "claude-haiku-4-5"
            case .xai:       return "grok-4.3"   // 4.6 is ~2x slower for no gain here
            case .local:     return "llama3.2"
            }
        }
        /// Anthropic uses the Messages API; everything else is OpenAI-shaped.
        var usesAnthropicSchema: Bool { self == .anthropic }

        var defaultBase: String {
            switch self {
            case .groq:      return "https://api.groq.com/openai/v1"
            case .openai:    return "https://api.openai.com/v1"
            case .anthropic: return "https://api.anthropic.com/v1"
            case .xai:       return "https://api.x.ai/v1"
            case .local:     return "http://localhost:11434/v1"
            }
        }

        var host: String { endpoint(base: "").host ?? rawValue }

        func endpoint(base override: String) -> URL {
            var base = override.isEmpty ? defaultBase : override
            while base.hasSuffix("/") { base.removeLast() }
            let path = usesAnthropicSchema ? "/messages" : "/chat/completions"
            return URL(string: base + path) ?? URL(string: defaultBase + path)!
        }
    }

    func resolveProvider() -> Provider? {
        let requested = config.cleanup.provider.lowercased()
        if requested != "auto", let p = Provider(rawValue: requested) {
            if !p.requiresKey { return p }
            return Env.get(p.keyName) != nil ? p : nil
        }
        // auto: ordered by measured round-trip latency on real dictations,
        // not by price — a 30s wait after releasing the key makes dictation
        // unusable, while the whole price spread is about $1.50/month.
        for p in [Provider.groq, .openai, .anthropic, .xai] where Env.get(p.keyName) != nil {
            return p
        }
        return nil
    }

    /// True when some provider can be called (a key is set, or it's local).
    var isAvailable: Bool { resolveProvider() != nil }

    /// Loads a local cleanup model into memory at launch, so the first
    /// dictation doesn't pay for reading gigabytes off disk. Hosted providers
    /// have nothing to warm. Same queue as the pipeline, so it never runs
    /// alongside a real take.
    func warmUp() {
        guard config.cleanup.enabled, resolveProvider() == .local else { return }
        let model = config.cleanup.model.isEmpty ? Provider.local.defaultModel : config.cleanup.model
        let started = Date()
        do {
            _ = try call(provider: .local, key: Env.get(Provider.local.keyName), model: model,
                         base: config.cleanup.base_url, system: "Reply with OK.", user: "OK",
                         timeout: 120, capped: false)
            Log.write(String(format: "warm-up: cleanup model %@ ready in %.2fs",
                             model, Date().timeIntervalSince(started)))
        } catch {
            Log.write("warm-up: cleanup model \(model) failed: \(error.localizedDescription)")
        }
    }

    /// Returns cleaned text, or the input unchanged if cleanup is off or
    /// unavailable. `style` overrides `cleanup.style` (per-app formatting).
    /// `language` is whisper's detection ("es", "en", …), passed on as a hint.
    func polish(_ transcript: String, style requested: String? = nil,
                language: String? = nil) -> String {
        guard config.cleanup.enabled else { return transcript }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return transcript }

        let style = (requested ?? config.cleanup.style).lowercased()
        if style == "raw" { return trimmed }
        // A short phrase gains nothing from the LLM but its round trip.
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        if words < config.cleanup.min_words && style != "structured" {
            return Cleanup.stripFillers(trimmed)
        }

        let system = (config.cleanup.prompt.isEmpty
            ? Config.cleanupPrompt(style: style)
            : config.cleanup.prompt) + vocabularyNote + languageNote(language)
        // Guard against a model that ignored instructions and answered the
        // text instead of cleaning it: a wild length change means bail out.
        // Structuring legitimately adds a title, numbers and newlines, so
        // it gets more headroom before we call the output suspicious.
        let upper = (style == "auto" || style == "structured") ? 3.5 : 2.5
        let out = complete(system: system, user: trimmed) { cleaned in
            let ratio = Double(cleaned.count) / Double(max(trimmed.count, 1))
            if ratio > upper || ratio < 0.25 {
                Log.write("cleanup output ratio \(String(format: "%.2f", ratio)) — rejected.")
                return nil
            }
            return Cleanup.tidy(cleaned)
        }
        return out ?? transcript
    }

    /// Command mode: rewrites `text` the way the spoken `instruction` asks.
    /// Nil when no provider is available or every attempt failed.
    func transform(_ text: String, instruction: String) -> String? {
        let user = "INSTRUCTION:\n\(instruction)\n\nTEXT:\n\(text)"
        return complete(system: Config.commandPrompt + vocabularyNote, user: user) { $0 }
    }

    /// Names the language whisper heard. The base prompt says "reply in the
    /// transcript's language", but a small local model has to work that out
    /// itself and gets it wrong: qwen2.5:7b turned every English dictation
    /// into Spanish, swayed by the Spanish examples in the prompt. Stating it
    /// outright fixes that. Mixed speech is the risk — so other-language
    /// words are explicitly left alone rather than translated to match.
    private func languageNote(_ code: String?) -> String {
        guard let code = code?.lowercased(), !code.isEmpty, code != "auto" else { return "" }
        let names = ["es": "Spanish", "en": "English", "it": "Italian", "pt": "Portuguese",
                     "fr": "French", "de": "German", "ca": "Catalan", "gl": "Galician"]
        let name = names[code] ?? code
        return "\n\nLANGUAGE: speech recognition detected \(name). The output MUST be in \(name), "
            + "the same language as the transcript. Leave any words or sentences spoken in "
            + "another language exactly as they are — never translate them."
    }

    private var vocabularyNote: String {
        let words = config.vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }
        return "\n\nVOCABULARY: these names and terms are spelled exactly like this. "
            + "When the text has something that sounds like one of them, use this spelling: "
            + words.joined(separator: ", ") + "."
    }

    /// Primary provider, then the configured fallback. Groq refuses VPN and
    /// datacenter source IPs, so without this a VPN toggle silently drops
    /// you back to raw, unstructured transcripts with no visible error.
    /// `base_url` belongs to the primary provider only — pointing the
    /// fallback at the primary's host would just fail the same way.
    /// `accept` vets each answer; nil moves on to the next provider.
    private func complete(system: String, user: String,
                          accept: (String) -> String?) -> String? {
        guard let provider = resolveProvider() else { return nil }
        let model = config.cleanup.model.isEmpty ? provider.defaultModel : config.cleanup.model

        var attempts: [(provider: Provider, model: String, base: String)] = [
            (provider, model, config.cleanup.base_url)
        ]
        let fb = config.cleanup.fallback_provider.lowercased()
        if !fb.isEmpty, let fbProvider = Provider(rawValue: fb), fbProvider != provider {
            let fbModel = config.cleanup.fallback_model.isEmpty
                ? fbProvider.defaultModel : config.cleanup.fallback_model
            attempts.append((fbProvider, fbModel, ""))
        }

        for (index, attempt) in attempts.enumerated() {
            let key = Env.get(attempt.provider.keyName)
            if attempt.provider.requiresKey && key == nil { continue }
            // When something is lined up behind this attempt, give up on a
            // stalled provider quickly rather than leaving you on the pill.
            let timeout: TimeInterval = index < attempts.count - 1 ? 10 : 30
            do {
                let out = try call(provider: attempt.provider, key: key, model: attempt.model,
                                   base: attempt.base, system: system, user: user,
                                   timeout: timeout)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !out.isEmpty, let accepted = accept(out) else { continue }
                if index > 0 {
                    Log.write("cleanup fell back to \(attempt.provider.rawValue)/\(attempt.model)")
                }
                return accepted
            } catch {
                Log.write("\(attempt.provider.rawValue) cleanup failed: \(error.localizedDescription)")
            }
        }
        return nil
    }

    private static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "erm", "eh", "ehm", "em", "mmm", "hmm",
    ]

    /// Drops standalone filler words from a short phrase that skipped the LLM.
    static func stripFillers(_ text: String) -> String {
        let kept = text.split(separator: " ").filter { token in
            !fillers.contains(token.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }
        let joined = kept.joined(separator: " ")
            .replacingOccurrences(of: #"^[,\s]+"#, with: "", options: .regularExpression)
        guard let first = joined.first else { return text }
        return first.uppercased() + joined.dropFirst()
    }

    /// Deterministic clean-up of defects the models reliably leave behind.
    /// Cheaper and more reliable than asking the prompt to avoid them.
    static func tidy(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)

        for i in lines.indices {
            var line = lines[i]
            // Trailing spaces — llama leaves them on every list item.
            while line.hasSuffix(" ") || line.hasSuffix("\t") { line.removeLast() }

            // A Spanish clause opened with ¿ must close with ?, not . or !.
            // Observed repeatedly: "¿sabes si ya se envió al cliente!"
            if line.contains("¿"), let last = line.last, "!.".contains(last) {
                line.removeLast()
                line.append("?")
            }
            // Same for ¡ … ? → !
            if line.contains("¡"), !line.contains("¿"), line.hasSuffix("?") {
                line.removeLast()
                line.append("!")
            }
            lines[i] = line
        }

        // Collapse runs of blank lines to exactly one.
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty == true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func call(provider: Provider, key: String?, model: String,
                      base: String, system: String, user: String,
                      timeout: TimeInterval, capped: Bool = true) throws -> String {
        var req = URLRequest(url: provider.endpoint(base: base))
        req.httpMethod = "POST"
        // The per-attempt budget, capped by the user's configured ceiling —
        // except for the warm-up, where nobody is waiting on the load.
        req.timeoutInterval = capped ? min(timeout, max(3, config.cleanup.timeout_seconds)) : timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any]
        if provider.usesAnthropicSchema {
            if let key = key { req.setValue(key, forHTTPHeaderField: "x-api-key") }
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            payload = [
                "model": model,
                "max_tokens": 2048,
                "temperature": 0,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
        } else {
            if let key = key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            var body: [String: Any] = [
                "model": model,
                "temperature": 0,
                "stream": false,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ]
            // Ollama unloads a model after 5 idle minutes, and reloading it
            // costs more than the 12 s cleanup budget — so the first dictation
            // after a coffee break came back uncleaned. Keep it resident for an
            // hour instead. Other OpenAI-compatible servers ignore the field.
            if provider == .local { body["keep_alive"] = "60m" }
            payload = body
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try HTTP.sendSync(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NetworkDiagnostics.error(status: code, body: msg,
                                           provider: provider.rawValue,
                                           host: req.url?.host ?? provider.rawValue)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.emptyResult
        }

        if provider.usesAnthropicSchema {
            guard let content = obj["content"] as? [[String: Any]] else {
                throw TranscriptionError.emptyResult
            }
            let text = content.compactMap { $0["text"] as? String }.joined()
            if text.isEmpty { throw TranscriptionError.emptyResult }
            return text
        } else {
            guard let choices = obj["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String else {
                throw TranscriptionError.emptyResult
            }
            return text
        }
    }
}
