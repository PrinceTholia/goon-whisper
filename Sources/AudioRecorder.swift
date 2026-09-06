import AVFoundation
import Foundation

class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var recordedFileURL: URL?
    @Published var level: Float = 0   // 0...1 real-time audio level for waveform

    /// Optional live PCM sink (16-bit LE mono @ 16 kHz) for Gemini Live STT.
    var onPCMChunk: ((Data) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var tempFileURL: URL?

    // Whisper / Gemini Live require 16kHz mono Int16
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    func startRecording() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            print("❌ Invalid input format (sampleRate = 0) — microphone permission may not be granted")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("❌ Cannot create AVAudioConverter: \(inputFormat) → \(targetFormat)")
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
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        do {
            try engine.start()
            audioEngine = engine
            isRecording = true
            print("✅ Recording started → \(tempURL.lastPathComponent) [in: \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch]")
        } catch {
            print("❌ Failed to start engine: \(error)")
        }
    }

    /// Stop mic and return the WAV URL without publishing via Combine (avoids double-handle).
    func consumeRecordingURL() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
        audioFile = nil
        isRecording = false
        onPCMChunk = nil
        DispatchQueue.main.async { self.level = 0 }

        let url = tempFileURL
        tempFileURL = nil
        if let url {
            print("✅ Recording stopped (consume) → \(url.path)")
        }
        return url
    }

    /// Stop mic. When `publishFile` is false, delete the temp WAV (unused path).
    func stopRecording(publishFile: Bool = true) {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
        audioFile = nil
        isRecording = false
        onPCMChunk = nil
        DispatchQueue.main.async { self.level = 0 }

        if let url = tempFileURL {
            if publishFile {
                print("✅ Recording stopped → \(url.path)")
                DispatchQueue.main.async {
                    self.recordedFileURL = url
                }
            } else {
                try? FileManager.default.removeItem(at: url)
                print("✅ Recording stopped (live STT, file discarded)")
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

        // Live PCM callback (Int16 mono)
        if let sink = onPCMChunk, let ch = outBuffer.int16ChannelData {
            let frames = Int(outBuffer.frameLength)
            let bytes = frames * MemoryLayout<Int16>.size
            let pcm = Data(bytes: ch[0], count: bytes)
            sink(pcm)
        }

        do {
            try file.write(from: outBuffer)
        } catch {
            print("❌ Write buffer error: \(error)")
        }
    }
}
