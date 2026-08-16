import Foundation

enum TranscriptionError: LocalizedError {
    case noBackendAvailable(String)
    case whisperFailed(String)
    case apiFailed(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .noBackendAvailable(let d): return "No transcription backend available. \(d)"
        case .whisperFailed(let d):      return "whisper.cpp failed: \(d)"
        case .apiFailed(let d):          return "Transcription API failed: \(d)"
        case .emptyResult:               return "Transcription returned nothing."
        }
    }
}

/// Turns a 16 kHz mono WAV into text, either locally via whisper.cpp or through
/// a Groq / OpenAI Whisper endpoint.
struct Transcriber {
    let config: Config

    /// Language of the last successful transcription ("es", "en", …) or "" if
    /// unknown. Read after `transcribe` for history/logging.
    final class Result {
        var language: String = ""
    }
    let result = Result()

    /// Languages the user actually speaks. Empty = accept anything.
    private var allowed: [String] {
        config.languages.map { $0.lowercased() }.filter { !$0.isEmpty }
    }

    private var fallbackLanguage: String { allowed.first ?? "en" }

    /// Resolution order for `transcription_backend == "auto"`:
    /// local whisper.cpp (if binary + model present) -> Groq -> OpenAI.
    func transcribe(wav: URL) throws -> String {
        switch config.transcription_backend.lowercased() {
        case "local":
            return try transcribeLocal(wav: wav)
        case "groq":
            return try transcribeAPI(wav: wav, provider: .groq)
        case "openai":
            return try transcribeAPI(wav: wav, provider: .openai)
        default:
            if localIsAvailable() {
                return try transcribeLocal(wav: wav)
            }
            if Env.get("GROQ_API_KEY") != nil {
                return try transcribeAPI(wav: wav, provider: .groq)
            }
            if Env.get("OPENAI_API_KEY") != nil {
                return try transcribeAPI(wav: wav, provider: .openai)
            }
            throw TranscriptionError.noBackendAvailable(
                "Install whisper.cpp + a model, or add GROQ_API_KEY / OPENAI_API_KEY to ~/.config/murmur/.env")
        }
    }

    // MARK: - Local whisper.cpp

    func localIsAvailable() -> Bool {
        resolvedWhisperCLI() != nil && resolvedModel() != nil
    }

    func resolvedWhisperCLI() -> String? {
        let fm = FileManager.default
        if !config.whisper_cli_path.isEmpty {
            let p = (config.whisper_cli_path as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: p) ? p : nil
        }
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    func resolvedModel() -> String? {
        let fm = FileManager.default
        if !config.whisper_model_path.isEmpty {
            let p = (config.whisper_model_path as NSString).expandingTildeInPath
            return fm.fileExists(atPath: p) ? p : nil
        }
        // Prefer bigger models when several are present.
        let preferred = ["ggml-medium.en.bin", "ggml-medium.bin",
                         "ggml-small.en.bin", "ggml-small.bin",
                         "ggml-base.en.bin", "ggml-base.bin"]
        for name in preferred {
            let p = Paths.modelsDir.appendingPathComponent(name).path
            if fm.fileExists(atPath: p) { return p }
        }
        return nil
    }

    private func transcribeLocal(wav: URL) throws -> String {
        let pinned = config.language.lowercased()
        if pinned != "auto" {
            result.language = pinned
            return try runWhisper(wav: wav, language: pinned).text
        }

        // Auto: transcribe once, then sanity-check the detected language.
        let first = try runWhisper(wav: wav, language: "auto")
        let detected = first.detected.lowercased()
        result.language = detected

        if allowed.isEmpty || detected.isEmpty || allowed.contains(detected) {
            return first.text
        }

        // Detected a language the user doesn't speak — almost always a
        // misdetection on short or noisy audio. Redo it in their main language
        // rather than handing back Korean.
        Log.write("detected '\(detected)' outside \(allowed) — retrying as '\(fallbackLanguage)'")
        let second = try runWhisper(wav: wav, language: fallbackLanguage)
        result.language = fallbackLanguage
        return second.text
    }

    private struct WhisperRun {
        let text: String
        let detected: String
    }

    private func runWhisper(wav: URL, language: String) throws -> WhisperRun {
        guard let cli = resolvedWhisperCLI() else {
            throw TranscriptionError.noBackendAvailable("whisper-cli not found (brew install whisper-cpp)")
        }
        guard let model = resolvedModel() else {
            throw TranscriptionError.noBackendAvailable("No ggml model in \(Paths.modelsDir.path)")
        }

        // Note: `--no-prints` is deliberately absent — it also suppresses the
        // "auto-detected language:" line we need to parse.
        let args = [
            "-m", model,
            "-f", wav.path,
            "--no-timestamps",
            "-t", String(max(4, ProcessInfo.processInfo.activeProcessorCount - 2)),
            "-l", language,
            "-otxt", "-of", wav.deletingPathExtension().path,
        ]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        try proc.run()
        // Drain before waiting: whisper is chatty on stderr and a full pipe
        // buffer would deadlock the process.
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let txtURL = wav.deletingPathExtension().appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: txtURL) }

        let err = String(data: errData, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            throw TranscriptionError.whisperFailed(String(err.suffix(400)))
        }
        guard let text = try? String(contentsOf: txtURL, encoding: .utf8) else {
            throw TranscriptionError.emptyResult
        }
        return WhisperRun(text: Transcriber.scrub(text),
                          detected: Transcriber.parseDetectedLanguage(err) ?? language)
    }

    /// Pulls "es" out of `whisper_full_with_state: auto-detected language: es (p = 0.98)`.
    static func parseDetectedLanguage(_ stderr: String) -> String? {
        guard let r = stderr.range(of: "auto-detected language: ") else { return nil }
        let tail = stderr[r.upperBound...]
        let code = tail.prefix { $0.isLetter || $0 == "-" }
        return code.isEmpty ? nil : String(code)
    }

    // MARK: - Hosted Whisper (Groq / OpenAI)

    enum Provider {
        case groq, openai
        var endpoint: URL {
            switch self {
            case .groq:   return URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
            case .openai: return URL(string: "https://api.openai.com/v1/audio/transcriptions")!
            }
        }
        var model: String {
            switch self {
            case .groq:   return "whisper-large-v3-turbo"
            case .openai: return "whisper-1"
            }
        }
        var keyName: String {
            switch self {
            case .groq:   return "GROQ_API_KEY"
            case .openai: return "OPENAI_API_KEY"
            }
        }
    }

    private func transcribeAPI(wav: URL, provider: Provider) throws -> String {
        let pinned = config.language.lowercased()
        let first = try callAPI(wav: wav, provider: provider,
                                language: pinned == "auto" ? nil : pinned)
        result.language = first.detected

        if pinned != "auto" { return first.text }
        let detected = first.detected.lowercased()
        if allowed.isEmpty || detected.isEmpty || allowed.contains(detected) {
            return first.text
        }
        Log.write("API detected '\(detected)' outside \(allowed) — retrying as '\(fallbackLanguage)'")
        let second = try callAPI(wav: wav, provider: provider, language: fallbackLanguage)
        result.language = fallbackLanguage
        return second.text
    }

    private func callAPI(wav: URL, provider: Provider, language: String?) throws -> WhisperRun {
        guard let key = Env.get(provider.keyName) else {
            throw TranscriptionError.noBackendAvailable("\(provider.keyName) not set in ~/.config/murmur/.env")
        }
        let audio = try Data(contentsOf: wav)

        let boundary = "murmur-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("model", provider.model)
        // verbose_json also reports which language the model heard.
        field("response_format", "verbose_json")
        if let language = language, !language.isEmpty { field("language", language) }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: provider.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try HTTP.sendSync(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.apiFailed("HTTP \(code): \(String(msg.prefix(300)))")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            throw TranscriptionError.emptyResult
        }
        // Whisper APIs report language as a name ("spanish") or a code ("es").
        let raw = (obj["language"] as? String ?? "").lowercased()
        return WhisperRun(text: Transcriber.scrub(text),
                          detected: Transcriber.normalizeLanguage(raw))
    }

    private static let languageNames: [String: String] = [
        "spanish": "es", "english": "en", "italian": "it", "portuguese": "pt",
        "french": "fr", "german": "de", "catalan": "ca", "galician": "gl",
    ]

    static func normalizeLanguage(_ value: String) -> String {
        if value.isEmpty { return "" }
        if let code = languageNames[value] { return code }
        return String(value.prefix(2))
    }

    // MARK: - Cleanup of raw model output

    /// Phrases whisper famously invents out of silence or noise — they come
    /// from subtitle files in its training data. If a short transcript is
    /// *only* one of these, it is not something the user said.
    private static let hallucinationPhrases: Set<String> = [
        // Spanish
        "gracias", "gracias por ver el video", "gracias por ver este video",
        "suscríbete al canal", "suscríbete", "subtítulos realizados por la comunidad de amara.org",
        "más información en www.alimmenta.com", "¡suscríbete!", "hasta la próxima",
        "no olvides suscribirte", "muchas gracias",
        // English
        "thank you", "thanks for watching", "thank you for watching",
        "thanks for watching!", "please subscribe", "subscribe to my channel",
        "you", "bye", "bye.", "okay", "so", "the end",
        // Portuguese / Italian
        "obrigado", "obrigada", "inscreva-se no canal",
        "grazie", "grazie per aver guardato il video", "sottotitoli e revisione a cura di qtss",
        // Generic
        "amara.org", "♪", "♪♪", "…",
    ]

    /// True when the text is nothing but a known hallucination artifact.
    /// Only applied to short transcripts — a long one that happens to end with
    /// "gracias" is real speech.
    static func isLikelyHallucination(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[.!?¡¿,\"'”“]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return true }
        // Long output is real speech even if it contains a stock phrase.
        guard normalized.count <= 60 else { return false }
        if hallucinationPhrases.contains(normalized) { return true }
        // A single repeated token ("you you you", "gracias gracias gracias").
        let words = normalized.split(separator: " ").map(String.init)
        if words.count >= 3, Set(words).count == 1 { return true }
        return false
    }

    /// Strips bracketed non-speech annotations whisper likes to emit
    /// ([BLANK_AUDIO], (music), [Music]) and normalizes whitespace.
    static func scrub(_ raw: String) -> String {
        var s = raw
        // Whisper's non-speech annotations can be long — silence has produced
        // "[Locución de la Iglesia de Jesucristo de los Santos de los Últimos
        // días]" (84 chars), so a short cap leaves the worst ones in place.
        let patterns = [
            #"\[[^\]]{0,160}\]"#,      // [BLANK_AUDIO], [Music], [ Silence ], …
            #"\([^\)]{0,160}\)"#,      // (upbeat music)
            #"\*[^\*]{0,80}\*"#,       // *sighs*
            #"♪[^♪]{0,160}♪"#,         // ♪ lyrics ♪
        ]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Synchronous HTTP helper

enum HTTP {
    /// Blocking request — callers already run on a background queue.
    static func sendSync(_ request: URLRequest) throws -> (Data, URLResponse) {
        var request = request
        // A conventional User-Agent, since some providers reject clients that
        // send none. (Note: Groq's "Access denied. Please check your network
        // settings." 403 is *not* this — that one is Groq refusing VPN and
        // datacenter source IPs, and no header will get past it.)
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Murmur/1.0 (macOS; +https://github.com/murmur)",
                             forHTTPHeaderField: "User-Agent")
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        let sem = DispatchSemaphore(value: 0)
        var result: (Data, URLResponse)?
        var failure: Error?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error { failure = error }
            else if let data = data, let response = response { result = (data, response) }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 90)
        if let failure = failure { throw failure }
        guard let result = result else {
            throw TranscriptionError.apiFailed("request timed out")
        }
        return result
    }
}
