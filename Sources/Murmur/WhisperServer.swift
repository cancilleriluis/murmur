import Foundation
import Darwin

/// Keeps one `whisper-server` (it ships with `brew install whisper-cpp`)
/// running with the model already in memory, so a dictation only pays for
/// inference.
///
/// Spawning `whisper-cli` per dictation reloads ~0.5 GB of weights and
/// re-initializes Metal every time — routinely a second or more before
/// decoding even starts, and the bulk of the wait after releasing the key.
/// If the server can't start or stops answering, Transcriber falls back to
/// the one-shot CLI, so this is purely a speed-up and never a new way to fail.
final class WhisperServer {
    static let shared = WhisperServer()

    private struct Target: Equatable {
        let binary: String
        let model: String
        let port: Int
        let threads: Int
    }

    private let queue = DispatchQueue(label: "murmur.whisper-server", qos: .utility)
    private let lock = NSLock()
    // Guarded by `lock` — read from the pipeline and from app termination.
    private var process: Process?
    private var readyPort: Int?
    // Only touched on `queue`.
    private var config: Config?
    private var running: Target?
    private var launchFailures = 0

    private static var pidFile: URL { Paths.configDir.appendingPathComponent("whisper-server.pid") }
    private static var logFile: URL { Paths.configDir.appendingPathComponent("whisper-server.log") }

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return readyPort != nil
    }

    /// Starts, restarts or stops the server to match `config`. Returns
    /// immediately; loading the model happens in the background.
    func configure(_ config: Config) {
        queue.async {
            self.config = config
            self.launchFailures = 0
            self.reconcile()
        }
    }

    /// Same as `configure`, but blocks until the server is up or has failed.
    @discardableResult
    func configureAndWait(_ config: Config) -> Bool {
        queue.sync {
            self.config = config
            self.launchFailures = 0
            self.reconcile()
        }
        return isReady
    }

    /// Called after a failed request: dictation falls back to the CLI right
    /// away while the server is relaunched in the background.
    func recover() {
        setReady(nil)
        queue.async {
            self.launchFailures += 1      // a server that keeps failing stays off
            self.stopProcess()
            self.reconcile()
        }
    }

    /// Synchronous and queue-free, so quitting never waits on a model load.
    func stop() {
        lock.lock()
        let proc = process
        process = nil
        readyPort = nil
        lock.unlock()
        proc?.terminate()
        try? FileManager.default.removeItem(at: WhisperServer.pidFile)
    }

    // MARK: - Inference

    func transcribe(wav: URL, language: String, beamSize: Int,
                    prompt: String? = nil) throws -> (text: String, detected: String) {
        lock.lock(); let port = readyPort; lock.unlock()
        guard let port = port else { throw TranscriptionError.whisperFailed("whisper-server not running") }
        return try WhisperServer.request(wav: wav, port: port, language: language,
                                         beamSize: beamSize, prompt: prompt)
    }

    private static func request(wav: URL, port: Int, language: String, beamSize: Int,
                                prompt: String? = nil) throws -> (text: String, detected: String) {
        var form = MultipartForm()
        form.field("response_format", "verbose_json")
        form.field("temperature", "0.0")
        form.field("language", language)
        form.field("beam_size", String(max(1, beamSize)))
        if let prompt = prompt { form.field("prompt", prompt) }
        form.file("file", filename: "audio.wav", type: "audio/wav", data: try Data(contentsOf: wav))

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finalized()

        let (data, response) = try HTTP.sendSync(req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.whisperFailed("server HTTP \(code): \(String(msg.prefix(200)))")
        }
        if let err = obj["error"] as? String { throw TranscriptionError.whisperFailed(err) }
        guard let text = obj["text"] as? String else { throw TranscriptionError.emptyResult }
        // verbose_json reports the language by name ("spanish").
        let detected = Transcriber.normalizeLanguage((obj["language"] as? String ?? "").lowercased())
        return (text, detected)
    }

    // MARK: - Lifecycle (on `queue`)

    private func reconcile() {
        guard let config = config, let target = WhisperServer.target(for: config) else {
            stopProcess()
            return
        }
        lock.lock(); let alive = process?.isRunning == true; lock.unlock()
        if alive, running == target { return }

        stopProcess()
        guard launchFailures < 3 else { return }
        launch(target)
    }

    private static func target(for config: Config) -> Target? {
        guard config.whisper_server else { return nil }
        let t = Transcriber(config: config)
        switch config.transcription_backend.lowercased() {
        case "local": break
        case "groq", "openai": return nil
        default: guard t.localIsAvailable() else { return nil }   // auto → local only if present
        }
        guard let binary = t.resolvedWhisperServer(), let model = t.resolvedModel() else { return nil }
        return Target(binary: binary, model: model,
                      port: config.whisper_server_port, threads: Transcriber.threadCount(config: config))
    }

    private func launch(_ target: Target) {
        killOrphan()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: target.binary)
        proc.arguments = [
            "-m", target.model,
            "--host", "127.0.0.1",
            "--port", String(target.port),
            "-t", String(target.threads),
        ]
        // A file, not a pipe: nobody drains a pipe, and a full one would
        // stall the server mid-request.
        FileManager.default.createFile(atPath: WhisperServer.logFile.path, contents: nil)
        let out = (try? FileHandle(forWritingTo: WhisperServer.logFile)) ?? FileHandle.nullDevice
        proc.standardOutput = out
        proc.standardError = out
        proc.terminationHandler = { [weak self] p in
            guard let self = self else { return }
            self.lock.lock()
            let current = self.process === p
            if current { self.process = nil; self.readyPort = nil }
            self.lock.unlock()
            if current { Log.write("whisper-server exited (status \(p.terminationStatus))") }
        }

        do {
            try proc.run()
        } catch {
            Log.write("whisper-server failed to launch: \(error.localizedDescription) — using whisper-cli")
            launchFailures += 1
            return
        }
        lock.lock(); process = proc; lock.unlock()
        try? String(proc.processIdentifier).write(to: WhisperServer.pidFile,
                                                  atomically: true, encoding: .utf8)
        Log.write("whisper-server starting on 127.0.0.1:\(target.port) with \((target.model as NSString).lastPathComponent)")

        let started = Date()
        while proc.isRunning, Date().timeIntervalSince(started) < 60 {
            if WhisperServer.isHealthy(port: target.port) {
                running = target
                warmUp(port: target.port)
                setReady(target.port)
                Log.write(String(format: "whisper-server ready in %.1fs — model stays loaded",
                                 Date().timeIntervalSince(started)))
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        Log.write("whisper-server never became ready (see whisper-server.log) — using whisper-cli")
        launchFailures += 1
        stopProcess()
    }

    private func stopProcess() {
        running = nil
        stop()
    }

    private func setReady(_ port: Int?) {
        lock.lock(); readyPort = port; lock.unlock()
    }

    private static func isHealthy(port: Int) -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 1
        guard let result = try? HTTP.sendSync(req),
              let http = result.1 as? HTTPURLResponse else { return false }
        // 503 while the model loads. Older builds have no /health and answer
        // 404, but they only start listening once the model is loaded.
        return http.statusCode == 200 || http.statusCode == 404
    }

    /// The first inference after launch pays for Metal pipeline setup; spend
    /// that on a throwaway clip instead of your first dictation.
    private func warmUp(port: Int) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-warmup.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? AudioRecorder.writeWav16k([Float](repeating: 0, count: 16000), to: url)) != nil
        else { return }
        _ = try? WhisperServer.request(wav: url, port: port, language: "en", beamSize: 1)
    }

    /// A crash leaves the previous server running with the model in RAM and
    /// the port taken; reap it before starting a new one.
    private func killOrphan() {
        guard let text = try? String(contentsOf: WhisperServer.pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return }
        defer { try? FileManager.default.removeItem(at: WhisperServer.pidFile) }

        // PIDs get reused — only kill it if it is still a whisper-server.
        var name = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &name, UInt32(name.count)) > 0,
              String(cString: name).hasPrefix("whisper-server") else { return }
        kill(pid, SIGTERM)
        Log.write("stopped orphaned whisper-server (pid \(pid))")
        for _ in 0..<20 where kill(pid, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

// MARK: - Multipart

/// Minimal multipart/form-data body for the Whisper-style endpoints.
struct MultipartForm {
    let boundary = "murmur-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func file(_ name: String, filename: String, type: String, data: Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(type)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    func finalized() -> Data {
        var out = body
        out.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return out
    }
}
