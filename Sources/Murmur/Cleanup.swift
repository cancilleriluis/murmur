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

    /// Returns cleaned text, or the input unchanged if cleanup is off/unavailable.
    func polish(_ transcript: String) -> String {
        guard config.cleanup.enabled else { return transcript }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return transcript }

        guard let provider = resolveProvider() else { return transcript }
        let model = config.cleanup.model.isEmpty ? provider.defaultModel : config.cleanup.model
        let system = config.cleanup.prompt.isEmpty
            ? Config.cleanupPrompt(style: config.cleanup.style)
            : config.cleanup.prompt

        // Primary, then the configured fallback. Groq refuses VPN and
        // datacenter source IPs, so without this a VPN toggle silently drops
        // you back to raw, unstructured transcripts with no visible error.
        // `base_url` belongs to the primary provider only — pointing the
        // fallback at the primary's host would just fail the same way.
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
            if let out = attemptPolish(provider: attempt.provider, key: key,
                                       model: attempt.model, base: attempt.base,
                                       system: system, original: trimmed) {
                // Logged on every dictation, not just fallbacks: "is my cleanup
                // actually hitting Groq?" is otherwise unanswerable from the log.
                Log.write(index == 0
                    ? "cleanup via \(attempt.provider.rawValue)/\(attempt.model)"
                    : "cleanup fell back to \(attempt.provider.rawValue)/\(attempt.model)")
                return out
            }
        }
        return transcript
    }

    /// One provider attempt. Returns nil when it failed or produced output the
    /// guard rejects, so the caller can move on to the next provider.
    private func attemptPolish(provider: Provider, key: String?, model: String,
                               base: String, system: String,
                               original trimmed: String) -> String? {
        do {
            let out = try call(provider: provider, key: key, model: model,
                               base: base, system: system, user: trimmed)
            let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty { return nil }
            // Guard against a model that ignored instructions and answered the
            // text instead of cleaning it: a wild length change means bail out.
            // Structuring legitimately adds a title, numbers and newlines, so
            // it gets more headroom before we call the output suspicious.
            let ratio = Double(cleaned.count) / Double(max(trimmed.count, 1))
            let upper = config.cleanup.style.lowercased() == "clean" ? 2.5 : 3.5
            if ratio > upper || ratio < 0.25 {
                Log.write("\(provider.rawValue) output ratio \(String(format: "%.2f", ratio)) — rejected.")
                return nil
            }
            return Cleanup.tidy(cleaned)
        } catch {
            Log.write("\(provider.rawValue) cleanup failed: \(error.localizedDescription)")
            return nil
        }
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
                      base: String, system: String, user: String) throws -> String {
        var req = URLRequest(url: provider.endpoint(base: base))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
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
            payload = [
                "model": model,
                "temperature": 0,
                "stream": false,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try HTTP.sendSync(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.apiFailed("HTTP \(code): \(String(msg.prefix(300)))")
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
