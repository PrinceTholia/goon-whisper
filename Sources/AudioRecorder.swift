import AVFoundation
import Foundation

class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var recordedFileURL: URL?
    @Published var level: Float = 0   // 0...1 real-time audio level for waveform

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var tempFileURL: URL?
    /// Invalidates an in-flight `engine.start()` if stop/cancel wins the race.
    private var startEpoch: UInt64 = 0
    private let audioQueue = DispatchQueue(label: "goon.audio.engine")

    // Whisper requires 16kHz mono Int16
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Start the mic without blocking the caller. Completion is on an arbitrary queue.
    func startRecording(completion: ((Bool) -> Void)? = nil) {
        startEpoch &+= 1
        let epoch = startEpoch

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            print("❌ Invalid input format (sampleRate = 0) — microphone permission may not be granted")
            completion?(false)
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("❌ Cannot create AVAudioConverter: \(inputFormat) → \(targetFormat)")
            completion?(false)
            return
        }
        self.converter = converter

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper_\(UUID().uuidString)")
            .appendingPathExtension("wav")
        tempFileURL = tempURL

        do {
            audioFile = try AVAudioFile(
                forWriting: tempURL,
                settings: targetFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
        } catch {
            print("❌ Failed to create audio file: \(error)")
            completion?(false)
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        audioEngine = engine
        // engine.start() can block — do not run it on the Fn-up critical path.
        audioQueue.async { [weak self] in
            do {
                try engine.start()
                DispatchQueue.main.async {
                    guard let self else {
                        engine.stop()
                        completion?(false)
                        return
                    }
                    guard self.startEpoch == epoch else {
                        engine.stop()
                        completion?(false)
                        return
                    }
                    self.isRecording = true
                    print("✅ Recording started → \(tempURL.lastPathComponent) [in: \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch]")
                    completion?(true)
                }
            } catch {
                print("❌ Failed to start engine: \(error)")
                DispatchQueue.main.async {
                    completion?(false)
                }
            }
        }
    }

    /// Stop mic and return the WAV URL without publishing via Combine (avoids double-handle).
    func consumeRecordingURL() -> URL? {
        startEpoch &+= 1
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
        audioFile = nil
        isRecording = false
        DispatchQueue.main.async { self.level = 0 }

        let url = tempFileURL
        tempFileURL = nil
        if let url {
            print("✅ Recording stopped (consume) → \(url.path)")
        }
        return url
    }

    /// Stop mic. When `publishFile` is false, delete the temp WAV (cancel).
    func stopRecording(publishFile: Bool = true) {
        startEpoch &+= 1
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
        audioFile = nil
        isRecording = false
        DispatchQueue.main.async { self.level = 0 }

        if let url = tempFileURL {
            if publishFile {
                print("✅ Recording stopped → \(url.path)")
                DispatchQueue.main.async {
                    self.recordedFileURL = url
                }
            } else {
                try? FileManager.default.removeItem(at: url)
                print("✅ Recording stopped (cancelled, file discarded)")
            }
        }
        tempFileURL = nil
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        if let ch = buffer.floatChannelData {
            let n = Int(buffer.frameLength)
            if n > 0 {
                var sum: Float = 0
                let p = ch[0]
                for i in 0..<n { sum += p[i] * p[i] }
                let rms = (sum / Float(n)).squareRoot()
                let lvl = min(1, rms * 8)
                DispatchQueue.main.async { self.level = lvl }
            }
        }

        guard let converter = converter, let file = audioFile else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outFrameCapacity
        ) else { return }

        var fedInput = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if fedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            fedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)

        if status == .error {
            print("❌ Convert error: \(error?.localizedDescription ?? "unknown")")
            return
        }
        guard outBuffer.frameLength > 0 else { return }

        do {
            try file.write(from: outBuffer)
        } catch {
            print("❌ Write buffer error: \(error)")
        }
    }
}
