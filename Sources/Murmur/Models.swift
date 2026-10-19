import Foundation

/// The whisper models in ~/.config/murmur/models, and the one bigger model
/// worth offering from the menu.
enum ModelLibrary {
    /// large-v3-turbo, 5-bit quantized (~550 MB): far more accurate than
    /// `small` on accents and mixed languages; with the model kept loaded by
    /// whisper-server the extra time is a fraction of a second per dictation.
    static let turboName = "ggml-large-v3-turbo-q5_0.bin"
    static let turboURL = URL(string:
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!

    static func installed() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Paths.modelsDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static var hasTurbo: Bool {
        FileManager.default.fileExists(atPath: Paths.modelsDir.appendingPathComponent(turboName).path)
    }

    /// "ggml-large-v3-turbo-q5_0.bin" → "large-v3-turbo-q5_0"
    static func label(_ url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("ggml-") { name.removeFirst(5) }
        return name
    }
}

/// Downloads large-v3-turbo into the models folder, reporting progress.
final class ModelDownloader {
    static let shared = ModelDownloader()

    /// 0…1 while downloading, nil when idle. Main thread only.
    private(set) var progress: Double?
    var onProgress: (() -> Void)?

    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    /// `completion` runs on the main thread with the error, if any.
    func downloadTurbo(completion: @escaping (Error?) -> Void) {
        guard task == nil else { return }
        let dest = Paths.modelsDir.appendingPathComponent(ModelLibrary.turboName)
        let task = URLSession.shared.downloadTask(with: ModelLibrary.turboURL) { [weak self] tmp, response, error in
            var failure = error
            if failure == nil {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                if code != 200 || tmp == nil {
                    failure = TranscriptionError.apiFailed("download HTTP \(code)")
                } else if let tmp = tmp {
                    // The temp file is deleted when this handler returns; move it now.
                    do {
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.moveItem(at: tmp, to: dest)
                    } catch {
                        failure = error
                    }
                }
            }
            DispatchQueue.main.async {
                self?.task = nil
                self?.observation = nil
                self?.progress = nil
                self?.onProgress?()
                completion(failure)
            }
        }
        observation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let value = p.fractionCompleted
            DispatchQueue.main.async {
                guard let self = self, self.task != nil else { return }
                // Repaint only on whole-percent changes.
                if Int(value * 100) != Int((self.progress ?? 0) * 100) {
                    self.progress = value
                    self.onProgress?()
                }
            }
        }
        progress = 0
        self.task = task
        task.resume()
        Log.write("downloading \(ModelLibrary.turboName)…")
    }
}
