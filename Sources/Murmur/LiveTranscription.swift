import Foundation

/// Transcribes a take in pieces while it is still being recorded: each time
/// you pause after a few seconds of speech, that stretch goes to whisper, so
/// on release only the last few seconds are left to transcribe.
///
/// Pieces run one at a time on a private queue, in order. If any piece fails,
/// `finish` returns nil and the caller transcribes the full recording instead,
/// so this can only make a dictation faster, never lose one.
final class LiveSession {
    private let config: Config
    private let queue = DispatchQueue(label: "murmur.live", qos: .userInitiated)
    // Only touched on `queue`.
    private var parts: [String] = []
    private var language = ""
    private var failed = false

    init(config: Config) {
        self.config = config
    }

    /// Safe from any thread; returns immediately.
    func submit(_ samples: [Float], rate: Double) {
        queue.async { self.transcribe(samples, rate: rate) }
    }

    /// Transcribes `tail` (if any), waits for every earlier piece, and returns
    /// the joined text — or nil if a piece failed. Blocking.
    func finish(tail: [Float], rate: Double) -> (text: String, language: String)? {
        return queue.sync { () -> (text: String, language: String)? in
            if !tail.isEmpty { transcribe(tail, rate: rate) }
            if failed { return nil }
            let text = parts.joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text, language)
        }
    }

    private func transcribe(_ samples: [Float], rate: Double) {
        guard !failed else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-piece-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try AudioRecorder.writeWav16k(AudioRecorder.resample(samples, from: rate), to: url)
            // Later pieces keep the language the first one was heard in, so a
            // short piece can't flip a Spanish dictation into another language.
            var cfg = config
            if !language.isEmpty && language != "auto" { cfg.language = language }
            let transcriber = Transcriber(config: cfg)
            let text = try transcriber.transcribe(wav: url)
            if language.isEmpty { language = transcriber.result.language }
            if !text.isEmpty { parts.append(text) }
            Log.write(String(format: "live piece %d (%.1fs): %@", parts.count,
                             Double(samples.count) / max(rate, 1), String(text.prefix(60))))
        } catch {
            Log.write("live piece failed (\(error.localizedDescription)) — will transcribe the whole take")
            failed = true
        }
    }
}
