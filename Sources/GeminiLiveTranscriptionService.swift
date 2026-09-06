import Foundation

/// Real-time STT via Gemini Live API (`gemini-3.5-transcribe-live`).
/// Streams 16 kHz mono PCM over WebSocket; SMART mode + optional vocabulary.
final class GeminiLiveTranscriptionService {
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private let sync = DispatchQueue(label: "goon.gemini.live")
    private var setupComplete = false
    private var pendingPCM: [Data] = []
    private var lastInterim = ""
    private var finals: [String] = []
    private var finishCompletion: ((Result<String, DictationAPIError>) -> Void)?
    private var startCompletion: ((Result<Void, DictationAPIError>) -> Void)?
    private var closed = false
    private var receiveLoopStarted = false

    func start(apiKey: String, vocabulary: [String],
               completion: @escaping (Result<Void, DictationAPIError>) -> Void) {
        sync.async {
            self.resetState()
            self.startCompletion = completion

            var comps = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
            comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            guard let url = comps.url else {
                completion(.failure(.network("Invalid Live API URL")))
                return
            }

            let session = URLSession(configuration: .default)
            self.session = session
            let task = session.webSocketTask(with: url)
            self.socket = task
            task.resume()
            self.startReceiveLoop()

            var transcription: [String: Any] = ["mode": "SMART"]
            if !vocabulary.isEmpty {
                transcription["customVocabulary"] = Array(vocabulary.prefix(100))
            }
            let setup: [String: Any] = [
                "setup": [
                    "model": "models/gemini-3.5-transcribe-live",
                    "generationConfig": [
                        "responseModalities": ["TEXT"]
                    ],
                    "inputAudioTranscription": transcription
                ]
            ]
            self.sendJSON(setup)
        }

        // Fail start if setup never completes
        DispatchQueue.global().asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.sync.async {
                guard let self, !self.setupComplete, let c = self.startCompletion else { return }
                self.startCompletion = nil
                self.teardown()
                c(.failure(.network("Live STT setup timed out")))
            }
        }
    }

    /// Append 16-bit little-endian mono PCM @ 16 kHz.
    func sendPCM(_ data: Data) {
        guard !data.isEmpty else { return }
        sync.async {
            if self.setupComplete {
                self.emitPCM(data)
            } else {
                self.pendingPCM.append(data)
            }
        }
    }

    func finish(completion: @escaping (Result<String, DictationAPIError>) -> Void) {
        sync.async {
            self.finishCompletion = completion
            if self.setupComplete {
                self.sendJSON(["realtimeInput": ["audioStreamEnd": true]])
            } else {
                // Never got setup — fail so caller can fall back to batch
                self.finishCompletion = nil
                completion(.failure(.network("Live STT not ready")))
                self.teardown()
                return
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.sync.async {
                guard let self, let c = self.finishCompletion else { return }
                self.finishCompletion = nil
                let text = self.bestTranscript()
                self.teardown()
                if text.isEmpty {
                    c(.failure(.emptyResponse))
                } else {
                    c(.success(text))
                }
            }
        }
    }

    func cancel() {
        sync.async {
            self.finishCompletion = nil
            self.startCompletion = nil
            self.teardown()
        }
    }

    // MARK: - Internals

    private func resetState() {
        setupComplete = false
        pendingPCM.removeAll()
        lastInterim = ""
        finals.removeAll()
        closed = false
        receiveLoopStarted = false
        finishCompletion = nil
    }

    private func bestTranscript() -> String {
        if let last = finals.last, !last.isEmpty { return last }
        return lastInterim.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func emitPCM(_ data: Data) {
        let b64 = data.base64EncodedString()
        sendJSON([
            "realtimeInput": [
                "audio": [
                    "data": b64,
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ])
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(str)) { err in
            if let err {
                print("⚠️ Live WS send: \(err.localizedDescription)")
            }
        }
    }

    private func startReceiveLoop() {
        guard !receiveLoopStarted, let socket else { return }
        receiveLoopStarted = true
        receiveNext(socket)
    }

    private func receiveNext(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.sync.async {
                    if !self.closed {
                        print("⚠️ Live WS receive: \(err.localizedDescription)")
                        if let c = self.startCompletion, !self.setupComplete {
                            self.startCompletion = nil
                            c(.failure(.network(err.localizedDescription)))
                        } else if let c = self.finishCompletion {
                            self.finishCompletion = nil
                            let text = self.bestTranscript()
                            c(text.isEmpty ? .failure(.network(err.localizedDescription)) : .success(text))
                        }
                        self.teardown()
                    }
                }
            case .success(let message):
                let text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text { self.handleMessage(text) }
                self.sync.async {
                    if !self.closed, let s = self.socket {
                        self.receiveNext(s)
                    }
                }
            }
        }
    }

    private func handleMessage(_ raw: String) {
        sync.async {
            guard let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            if json["setupComplete"] != nil {
                self.setupComplete = true
                let pending = self.pendingPCM
                self.pendingPCM.removeAll()
                for chunk in pending { self.emitPCM(chunk) }
                if let c = self.startCompletion {
                    self.startCompletion = nil
                    DispatchQueue.main.async { c(.success(())) }
                }
                return
            }

            if let err = json["error"] as? [String: Any] {
                let msg = (err["message"] as? String) ?? "Live API error"
                print("❌ Live API: \(msg)")
                if let c = self.startCompletion {
                    self.startCompletion = nil
                    c(.failure(.network(msg)))
                } else if let c = self.finishCompletion {
                    self.finishCompletion = nil
                    c(.failure(.network(msg)))
                }
                self.teardown()
                return
            }

            guard let sc = json["serverContent"] as? [String: Any] else { return }

            if let interim = sc["interimInputTranscription"] as? [String: Any],
               let t = interim["text"] as? String, !t.isEmpty {
                self.lastInterim = t
            }
            if let final = sc["inputTranscription"] as? [String: Any],
               let t = final["text"] as? String, !t.isEmpty {
                self.finals.append(t)
                self.lastInterim = t
            }

            let genDone = (sc["generationComplete"] as? Bool) == true
            let turnDone = (sc["turnComplete"] as? Bool) == true
            if genDone || turnDone, let c = self.finishCompletion {
                self.finishCompletion = nil
                let text = self.bestTranscript()
                self.teardown()
                c(text.isEmpty ? .failure(.emptyResponse) : .success(text))
            }
        }
    }

    private func teardown() {
        closed = true
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        pendingPCM.removeAll()
    }
}
