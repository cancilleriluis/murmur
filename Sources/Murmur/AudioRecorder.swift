import Foundation
import AVFoundation

enum RecorderError: LocalizedError {
    case noInput
    var errorDescription: String? { "No microphone input available" }
}

/// Records the microphone with AVAudioEngine, downmixes to mono, resamples to
/// 16 kHz, and writes a 16-bit PCM WAV — the format whisper.cpp expects and
/// that the Groq/OpenAI APIs accept.
///
/// One instance lives for the whole run. Building a fresh engine on every
/// keypress is what made the pill show up late and clipped the first
/// syllable: creating the HAL input unit is the slow part, so it is built once
/// and only rebuilt when the input device actually changes. All engine work
/// happens on a private queue so the main thread never waits on hardware.
final class AudioRecorder {

    struct Take {
        let url: URL
        let duration: Double
        /// Loudest normalized level seen this take. Used to reject near-silent
        /// recordings before they reach whisper, which invents speech from noise.
        let peakLevel: Float
        /// Fraction of buffers that carried plausible speech energy.
        let voicedFraction: Double
    }

    private var engine = AVAudioEngine()
    private var samples: [Float] = []
    /// Rolling audio from just before the key went down, kept only while the
    /// mic is warm, so the first syllable isn't clipped.
    private var preroll: [Float] = []
    private var prerollUsed = 0
    private var sourceSampleRate: Double = 48000
    private var isRecording = false
    private var tapInstalled = false
    private var needsRebuild = false
    private var warmSeconds: Double = 0
    private var cooldown: DispatchWorkItem?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "murmur.audio", qos: .userInteractive)

    private var peakLevel: Float = 0
    private var voicedBuffers = 0
    private var totalBuffers = 0

    private static let prerollSeconds = 0.25

    /// Normalized 0…1 input level, emitted per captured buffer for the UI meter.
    var onLevel: ((Float) -> Void)?

    init() {
        // Plugging in a headset or switching the default input invalidates the
        // engine's format; rebuild it on the next take instead of crashing.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] note in
            guard let self = self else { return }
            self.queue.async {
                guard (note.object as? AVAudioEngine) === self.engine else { return }
                Log.write("audio device changed — rebuilding input on next take")
                self.needsRebuild = true
            }
        }
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

    /// How long the mic stays open after a take. While open, the next press
    /// starts instantly and includes a short pre-roll; the cost is the orange
    /// mic indicator staying on (and Bluetooth headsets staying in call mode).
    /// 0 closes the mic as soon as you release the key.
    func setWarmSeconds(_ seconds: Double) {
        queue.async {
            self.warmSeconds = max(0, seconds)
            if !self.currentlyRecording { self.scheduleCooldown() }
        }
    }

    /// Starts capturing. `completion` runs on the audio queue with the error, if any.
    func start(_ completion: @escaping (Error?) -> Void) {
        queue.async {
            self.cooldown?.cancel()
            self.cooldown = nil

            self.lock.lock()
            self.samples = self.preroll            // empty unless the mic was warm
            self.prerollUsed = self.preroll.count
            self.preroll.removeAll(keepingCapacity: true)
            self.peakLevel = 0; self.voicedBuffers = 0; self.totalBuffers = 0
            self.isRecording = true
            self.lock.unlock()

            if self.engine.isRunning && !self.needsRebuild {
                completion(nil)
                return
            }
            do {
                try self.startEngine()
                completion(nil)
            } catch {
                self.lock.lock(); self.isRecording = false; self.lock.unlock()
                completion(error)
            }
        }
    }

    /// Stops capturing and writes the take to a temp WAV. `completion` runs on
    /// the audio queue and gets nil when too little audio arrived to be useful.
    func stop(_ completion: @escaping (Take?) -> Void) {
        queue.async {
            self.lock.lock()
            self.isRecording = false
            let captured = self.samples
            let skipped = self.prerollUsed
            let sr = self.sourceSampleRate
            let peak = self.peakLevel
            let voiced = self.totalBuffers == 0 ? 0
                : Double(self.voicedBuffers) / Double(self.totalBuffers)
            self.samples.removeAll(keepingCapacity: true)
            self.lock.unlock()

            self.scheduleCooldown()

            // Pre-roll is extra context for whisper, not time you held the key.
            let duration = Double(captured.count - skipped) / max(sr, 1)
            completion(AudioRecorder.writeTake(captured, rate: sr, duration: duration,
                                               peak: peak, voiced: voiced))
        }
    }

    /// Drops the current take without writing anything.
    func cancel() {
        queue.async {
            self.lock.lock()
            self.isRecording = false
            self.samples.removeAll(keepingCapacity: true)
            self.lock.unlock()
            self.scheduleCooldown()
        }
    }

    // MARK: - Engine

    private var currentlyRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return isRecording
    }

    private func startEngine() throws {
        if needsRebuild {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
            engine = AVAudioEngine()
            tapInstalled = false
            needsRebuild = false
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // A device mid-switch reports 0 Hz / 0 channels, and installing a tap
        // with that format raises an exception rather than throwing.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }

        // Reinstall every cold start: the device format may differ from last time.
        if tapInstalled { input.removeTap(onBus: 0) }
        lock.lock(); sourceSampleRate = format.sampleRate; lock.unlock()
        let channels = Int(format.channelCount)
        // Small buffers keep the pill's meter in step with your voice.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, channels: channels)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
    }

    private func scheduleCooldown() {
        cooldown?.cancel()
        cooldown = nil
        guard warmSeconds > 0 else { shutdown(); return }
        let item = DispatchWorkItem { [weak self] in self?.shutdown() }
        cooldown = item
        queue.asyncAfter(deadline: .now() + warmSeconds, execute: item)
    }

    private func shutdown() {
        cooldown = nil
        lock.lock()
        let busy = isRecording
        if !busy { preroll.removeAll() }
        lock.unlock()
        // The tap stays installed; the next cold start reinstalls it with the
        // current device format.
        if !busy, engine.isRunning { engine.stop() }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, channels: Int) {
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

        lock.lock()
        guard isRecording else {
            // Warm and idle: keep only the last fraction of a second.
            preroll.append(contentsOf: mono)
            let keep = Int(sourceSampleRate * AudioRecorder.prerollSeconds)
            if preroll.count > keep { preroll.removeFirst(preroll.count - keep) }
            lock.unlock()
            return
        }
        samples.append(contentsOf: mono)
        lock.unlock()

        var sumSquares: Float = 0
        for v in mono { sumSquares += v * v }
        let rms = sqrt(sumSquares / Float(frames))
        // Map RMS to a perceptual 0…1 over roughly -50…0 dBFS.
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 50) / 50))

        lock.lock()
        peakLevel = max(peakLevel, level)
        totalBuffers += 1
        // ~-38 dBFS: above room tone and fan noise, below any real speech.
        if level > 0.24 { voicedBuffers += 1 }
        lock.unlock()

        onLevel?(level)
    }

    private static func writeTake(_ captured: [Float], rate: Double, duration: Double,
                                  peak: Float, voiced: Double) -> Take? {
        if captured.count < 400 { return nil }
        let resampled = resampleLinear(captured, from: rate, to: 16000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-\(UUID().uuidString).wav")
        do {
            try writeWav16k(resampled, to: url)
        } catch {
            Log.write("WAV write failed: \(error)")
            return nil
        }
        return Take(url: url, duration: duration, peakLevel: peak, voicedFraction: voiced)
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

        // Convert into one contiguous buffer rather than appending sample by
        // sample — that was the slow part for long takes.
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(clamped * 32767.0).littleEndian
        }
        let dataSize = UInt32(pcm.count * 2)

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
        pcm.withUnsafeBufferPointer { file.append(Data(buffer: $0)) }
        try file.write(to: url, options: .atomic)
    }
}
