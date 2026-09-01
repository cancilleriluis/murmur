import Foundation

enum TranscriptionError: LocalizedError {
    case noBackendAvailable(String)
    case whisperFailed(String)
    case apiFailed(String)
    /// The request never reached the provider: DNS, TLS, a VPN, a proxy, or no
    /// network at all. Kept apart from `apiFailed` because the fix is
    /// completely different — nothing about the key or the model is wrong.
    case apiUnreachable(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .noBackendAvailable(let d): return "No transcription backend available. \(d)"
        case .whisperFailed(let d):      return "whisper.cpp failed: \(d)"
        case .apiFailed(let d):          return "API error: \(d)"
        case .apiUnreachable(let d):     return "API unreachable: \(d)"
        case .emptyResult:               return "Transcription returned nothing."
        }
    }

    /// A short, human line for the recording pill, which only has room for a
    /// few words. The full text always goes to murmur.log.
    var pillMessage: String {
        switch self {
        case .noBackendAvailable:        return "No backend"
        case .whisperFailed:             return "whisper.cpp failed"
        case .apiFailed:                 return "API error — see log"
        case .apiUnreachable:            return "API unreachable"
        case .emptyResult:               return "Nothing transcribed"
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

    enum Backend: Equatable {
        case local
        case api(Provider)

        var label: String {
            switch self {
            case .local:            return "local whisper.cpp"
            case .api(let p):       return p.rawValue
            }
        }
    }

    /// Every backend that could serve this dictation, best first.
    ///
    /// The one rule that overrides everything: **audio never starts going over
    /// the network because something local broke.** So a working local model —
    /// whether pinned with `"local"` or found by `"auto"` — is a chain of one.
    /// The README promises that setup makes no network calls at all, and a
    /// silent upload after a whisper.cpp hiccup would quietly break it.
    ///
    /// A hosted backend the user did pick gets the full chain, with local
    /// preferred as the first fallback because it is the one thing a VPN, an
    /// expired key, or a provider outage cannot refuse.
    func backendPlan() -> [Backend] {
        var plan: [Backend] = []
        func add(_ b: Backend) {
            guard !plan.contains(b) else { return }
            switch b {
            case .local:      if localIsAvailable() { plan.append(b) }
            case .api(let p): if Env.get(p.keyName) != nil { plan.append(b) }
            }
        }

        switch config.transcription_backend.lowercased() {
        case "local":
            return localIsAvailable() ? [.local] : []
        case "groq":
            add(.api(.groq)); add(.local); add(.api(.openai))
        case "openai":
            add(.api(.openai)); add(.local); add(.api(.groq))
        default:
            // "auto": local when it's there, otherwise chain the APIs — with
            // no local model there is no privacy promise left to keep.
            if localIsAvailable() { return [.local] }
            add(.api(.groq)); add(.api(.openai))
        }
        return plan
    }

    /// Runs the plan in order, moving on when a backend fails.
    ///
    /// Before this, a single failing provider ended the dictation outright:
    /// Groq answers `403 Access denied` to every VPN and datacenter IP, so
    /// turning on a VPN made Murmur stop working entirely, with nothing in the
    /// pill but a truncated "Transcription API fai…".
    func transcribe(wav: URL) throws -> String {
        let plan = backendPlan()
        guard !plan.isEmpty else {
            throw TranscriptionError.noBackendAvailable(unavailableReason())
        }

        var lastError: Error?
        for (index, backend) in plan.enumerated() {
            do {
                let text: String
                switch backend {
                case .local:      text = try transcribeLocal(wav: wav)
                case .api(let p): text = try transcribeAPI(wav: wav, provider: p)
                }
                if index > 0 {
                    Log.write("transcription fell back to \(backend.label)")
                }
                return text
            } catch {
                lastError = error
                let remaining = plan.count - index - 1
                Log.write("\(backend.label) transcription failed: \(error.localizedDescription)"
                          + (remaining > 0 ? " — trying \(plan[index + 1].label)" : ""))
            }
        }
        throw lastError ?? TranscriptionError.emptyResult
    }

    /// Why nothing could run — specific enough to act on, since this is what
    /// the user sees when dictation does nothing at all.
    private func unavailableReason() -> String {
        let pinned = config.transcription_backend.lowercased()
        if pinned == "local" {
            if resolvedWhisperCLI() == nil {
                return "transcription_backend is \"local\" but whisper-cli was not found (brew install whisper-cpp)."
            }
            return "transcription_backend is \"local\" but no ggml-*.bin model was found in \(Paths.modelsDir.path)."
        }
        return "Install whisper.cpp + a model, or add GROQ_API_KEY / OPENAI_API_KEY to \(Paths.envFile.path)"
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
        // The formula has renamed this binary twice (main -> whisper-cpp ->
        // whisper-cli), and Homebrew lives in a different prefix on Intel. A
        // miss here is invisible: local silently drops out of the plan and the
        // dictation goes to a hosted API instead. ("main", whisper.cpp's
        // original name, is deliberately not in this list — it is far too
        // generic to run whatever it happens to find on $PATH.)
        let names = ["whisper-cli", "whisper-cpp", "whisper"]
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
                    (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")]
        // A GUI app launched from Finder inherits no shell PATH, but one
        // launched from a terminal does — use it when it's there.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        for dir in dirs {
            for name in names {
                let p = (dir as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    func resolvedModel() -> String? {
        let fm = FileManager.default
        if !config.whisper_model_path.isEmpty {
            let p = (config.whisper_model_path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { return nil }
            if !isDir.boolValue { return p }
            return Transcriber.bestModel(in: URL(fileURLWithPath: p))
        }
        return Transcriber.bestModel(in: Paths.modelsDir)
    }

    /// The best `ggml-*.bin` in `dir`, or nil if there is none.
    ///
    /// This used to be a list of six exact filenames, which meant a model the
    /// user actually downloaded — `ggml-large-v3-turbo.bin`, any quantized
    /// `-q5_1` build, a `distil-` build — was not seen at all, local dropped
    /// out of the backend plan without a word, and dictation went to a hosted
    /// API that then needed a working key and an unblocked network.
    static func bestModel(in dir: URL) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        let models = names.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }
        guard !models.isEmpty else { return nil }

        func size(_ name: String) -> Int64 {
            let path = dir.appendingPathComponent(name).path
            let attrs = try? fm.attributesOfItem(atPath: path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        // Size class first (bigger is more accurate), then bytes — which within
        // one class picks the unquantized build, since it is the larger file.
        // The 1 MB floor drops a half-finished download, which would otherwise
        // outrank a complete model and make whisper fail on every dictation.
        // Pin `whisper_model_path` in config.json to override all of this.
        let best = models
            .map { (name: $0, score: modelScore($0), bytes: size($0)) }
            .filter { $0.bytes > 1_000_000 }   // ignore truncated downloads
            .sorted { ($0.score, $0.bytes) > ($1.score, $1.bytes) }
            .first
        guard let best = best else { return nil }
        return dir.appendingPathComponent(best.name).path
    }

    /// Size class, largest first. Unknown names score 0 and lose to any known
    /// class, but still beat nothing at all.
    static func modelScore(_ filename: String) -> Int {
        let name = filename.lowercased()
        let classes: [(String, Int)] = [("large", 5), ("medium", 4), ("small", 3),
                                        ("base", 2), ("tiny", 1)]
        for (keyword, rank) in classes where name.contains(keyword) { return rank }
        return 0
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

    enum Provider: String {
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
        var host: String { endpoint.host ?? rawValue }
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
            throw NetworkDiagnostics.error(status: code, body: msg,
                                           provider: provider.rawValue, host: provider.host)
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

// MARK: - Turning failures into something actionable

/// Foundation's own messages for a blocked request are famously unhelpful
/// ("The operation couldn't be completed"), and every hosted-API failure ends
/// up looking the same to the user. These turn each one into a line that names
/// the actual fix.
enum NetworkDiagnostics {

    /// Transport-level failure — the request never got an HTTP response.
    static func error(transport: Error, host: String) -> TranscriptionError {
        let ns = transport as NSError
        guard ns.domain == NSURLErrorDomain else {
            return .apiUnreachable("\(host): \(ns.localizedDescription)")
        }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet:
            return .apiUnreachable("no internet connection")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .apiUnreachable("cannot resolve \(host) — DNS is failing, usually a VPN or a custom resolver")
        case NSURLErrorCannotConnectToHost:
            return .apiUnreachable("\(host) refused the connection — a firewall, proxy or VPN is blocking it")
        case NSURLErrorTimedOut:
            return .apiUnreachable("\(host) timed out")
        case NSURLErrorNetworkConnectionLost:
            return .apiUnreachable("connection to \(host) dropped mid-request")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected:
            return .apiUnreachable("TLS to \(host) failed — something is intercepting HTTPS (corporate proxy, filtering VPN, or antivirus)")
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return .apiUnreachable("plain HTTP is blocked by App Transport Security — use an https:// base_url")
        default:
            return .apiUnreachable("\(host): \(ns.localizedDescription) [URLError \(ns.code)]")
        }
    }

    /// A real HTTP response that wasn't 2xx.
    static func error(status: Int, body: String, provider: String, host: String) -> TranscriptionError {
        let detail = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
        switch status {
        case 401:
            return .apiFailed("\(provider) rejected the API key (401) — the key in \(Paths.envFile.path) is wrong, expired, or was pasted with a stray character. `--doctor` prints its length.")
        case 403:
            // Groq's 403 is not about the key at all, which is why it wastes so
            // much time: /v1/models still answers, so the key tests fine.
            if provider == "groq" {
                return .apiUnreachable("Groq refused this IP address (403). It blocks VPN and datacenter addresses — turn the VPN off, or let Murmur fall back to another backend.")
            }
            return .apiFailed("\(provider) refused the request (403): \(detail)")
        case 404:
            return .apiFailed("\(host) has no such endpoint (404) — check cleanup.base_url and the model name.")
        case 413:
            return .apiFailed("\(provider) rejected the request as too large (413) — record a shorter take.")
        case 429:
            return .apiFailed("\(provider) rate-limited or out of quota (429): \(detail)")
        case 500...599:
            return .apiUnreachable("\(provider) is having an outage (HTTP \(status)).")
        default:
            return .apiFailed("\(provider) HTTP \(status): \(detail)")
        }
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

        let host = request.url?.host ?? "the API"
        let sem = DispatchSemaphore(value: 0)
        // Written on URLSession's delegate queue, read here only after the
        // semaphore has been signalled, which orders the two.
        let box = ResultBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error { box.failure = error }
            else if let data = data, let response = response { box.result = (data, response) }
            sem.signal()
        }
        task.resume()

        // The wall-clock ceiling sits above the request's own timeoutInterval so
        // URLSession normally reports the real reason first; this only catches a
        // task that never calls back at all.
        let ceiling = request.timeoutInterval > 0 ? request.timeoutInterval + 30 : 90
        if sem.wait(timeout: .now() + ceiling) == .timedOut {
            // Without this the request keeps running (and holding the
            // connection) long after we've given up on it.
            task.cancel()
            throw TranscriptionError.apiUnreachable("\(host) did not answer within \(Int(ceiling))s")
        }
        if let failure = box.failure { throw NetworkDiagnostics.error(transport: failure, host: host) }
        guard let result = box.result else {
            throw TranscriptionError.apiUnreachable("\(host) returned neither data nor an error")
        }
        return result
    }

    /// A reference box so the completion handler doesn't capture `inout`-style
    /// locals across threads.
    private final class ResultBox {
        var result: (Data, URLResponse)?
        var failure: Error?
    }
}
