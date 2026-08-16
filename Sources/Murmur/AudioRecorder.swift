import Foundation
import AVFoundation

/// Records the microphone with AVAudioEngine, downmixes to mono, resamples to
/// 16 kHz, and writes a 16-bit PCM WAV — the format whisper.cpp expects and
/// that the Groq/OpenAI APIs accept.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var sourceSampleRate: Double = 48000
    private var isRecording = false
    private let lock = NSLock()

    /// Normalized 0…1 input level, emitted per captured buffer for the UI meter.
    var onLevel: ((Float) -> Void)?

    /// Loudest normalized level seen this take. Used to reject near-silent
    /// recordings before they reach whisper, which invents speech from noise.
    private(set) var peakLevel: Float = 0
    /// Fraction of buffers that carried plausible speech energy.
    private var voicedBuffers = 0
    private var totalBuffers = 0
    var voicedFraction: Double {
        totalBuffers == 0 ? 0 : Double(voicedBuffers) / Double(totalBuffers)
    }

    var recordingDuration: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / max(sourceSampleRate, 1)
    }

    /// Requests mic access; completion runs on an arbitrary queue.
    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { completion($0) }
        default: completion(false)
        }
    }

    static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func start() throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        peakLevel = 0; voicedBuffers = 0; totalBuffers = 0
        lock.unlock()
        isRecording = true

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        sourceSampleRate = format.sampleRate > 0 ? format.sampleRate : 48000
        let channels = Int(format.channelCount)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            guard let chans = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            if frames == 0 { return }
            var mono = [Float](repeating: 0, count: frames)
            if channels <= 1 {
                let p = chans[0]
                for i in 0..<frames { mono[i] = p[i] }
            } else {
                for i in 0..<frames {
                    var acc: Float = 0
                    for c in 0..<channels { acc += chans[c][i] }
                    mono[i] = acc / Float(channels)
                }
            }
            self.lock.lock(); self.samples.append(contentsOf: mono); self.lock.unlock()

            var sumSquares: Float = 0
            for v in mono { sumSquares += v * v }
            let rms = sqrt(sumSquares / Float(frames))
            // Map RMS to a perceptual 0…1 over roughly -50…0 dBFS.
            let db = 20 * log10(max(rms, 1e-7))
            let level = max(0, min(1, (db + 50) / 50))

            self.lock.lock()
            self.peakLevel = max(self.peakLevel, level)
            self.totalBuffers += 1
            // ~-38 dBFS: above room tone and fan noise, below any real speech.
            if level > 0.24 { self.voicedBuffers += 1 }
            self.lock.unlock()

            self.onLevel?(level)
        }

        engine.prepare()
        try engine.start()
    }

    /// Stops and writes a WAV to a temp file. Returns (url, duration) or nil if too little audio.
    func stop() -> (url: URL, duration: Double)? {
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock(); let captured = samples; let sr = sourceSampleRate; lock.unlock()
        let duration = Double(captured.count) / max(sr, 1)
        if captured.count < 400 { return nil }

        let resampled = AudioRecorder.resampleLinear(captured, from: sr, to: 16000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-\(UUID().uuidString).wav")
        do {
            try AudioRecorder.writeWav16k(resampled, to: url)
        } catch {
            Log.write("WAV write failed: \(error)")
            return nil
        }
        return (url, duration)
    }

    // MARK: - DSP helpers

    static func resampleLinear(_ input: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        if abs(srcRate - dstRate) < 1 { return input }
        let ratio = dstRate / srcRate
        let outCount = Int(Double(input.count) * ratio)
        if outCount <= 0 { return [] }
        var out = [Float](repeating: 0, count: outCount)
        let step = srcRate / dstRate
        var pos = 0.0
        for i in 0..<outCount {
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let a = input[min(idx, input.count - 1)]
            let b = input[min(idx + 1, input.count - 1)]
            out[i] = a + (b - a) * frac
            pos += step
        }
        return out
    }

    static func writeWav16k(_ samples: [Float], to url: URL) throws {
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let v = Int16(clamped * 32767.0)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let dataSize = UInt32(pcm.count)

        var header = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append("RIFF".data(using: .ascii)!)
        le(UInt32(36) + dataSize)
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        le(UInt32(16))                 // PCM fmt chunk size
        le(UInt16(1))                  // audio format = PCM
        le(channels)
        le(sampleRate)
        le(byteRate)
        le(blockAlign)
        le(bitsPerSample)
        header.append("data".data(using: .ascii)!)
        le(dataSize)

        var file = header
        file.append(pcm)
        try file.write(to: url, options: .atomic)
    }
}
