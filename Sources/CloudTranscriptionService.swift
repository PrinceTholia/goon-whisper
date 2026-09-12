import Foundation

/// Transcribe audio via cloud STT — Groq Whisper (OpenAI-compatible multipart).
class CloudTranscriptionService {
    private var provider: STTProvider { STTSettings.current }
    private var currentTask: URLSessionDataTask?

    var isAvailable: Bool { STTSettings.key(for: provider) != nil }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    private func langCode(_ language: String, style: STTProvider.Style) -> String? {
        guard let lang = Languages.find(language) else { return nil }
        if lang.code == "auto" { return nil }
        return (style == .elevenlabs) ? lang.iso3 : lang.code
    }

    func transcribe(fileURL: URL, language: String,
                    completion: @escaping (Result<String, DictationAPIError>) -> Void) {
        let p = provider
        guard let key = STTSettings.key(for: p) else {
            completion(.failure(.noAPIKey(provider: p.name))); return
        }
        guard let fileData = try? Data(contentsOf: fileURL), !fileData.isEmpty else {
            completion(.failure(.emptyResponse)); return
        }

        transcribeMultipart(fileData: fileData, key: key, language: language,
                            provider: p, completion: completion)
    }

    // MARK: - OpenAI / Groq / ElevenLabs multipart

    private func transcribeMultipart(fileData: Data, key: String, language: String,
                                     provider p: STTProvider,
                                     completion: @escaping (Result<String, DictationAPIError>) -> Void) {
        guard let endpoint = STTSettings.endpoint(for: p) else {
            completion(.failure(.network("Invalid endpoint"))); return
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 120

        switch p.style {
        case .elevenlabs:
            req.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .openAI:
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        let modelField = (p.style == .elevenlabs) ? "model_id" : "model"
        let langField  = (p.style == .elevenlabs) ? "language_code" : "language"

        field(modelField, STTSettings.model(for: p))
        if let lang = langCode(language, style: p.style) {
            field(langField, lang)
        }

        // Groq / OpenAI Whisper: lower temperature + vocabulary prompt cuts random mishears
        if p.style == .openAI {
            field("temperature", "0")
            if let prompt = Self.whisperBiasPrompt(for: p) {
                field("prompt", prompt)
            }
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        currentTask?.cancel()
        let task = URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            if self?.currentTask === nil { return }
            if let error = error {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
                completion(.failure(.network(error.localizedDescription))); return
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 0 {
                completion(.failure(.network("No response"))); return
            }
            if !(200...299).contains(status) {
                completion(.failure(.fromHTTP(status: status, data: data, headers: http?.allHeaderFields)))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(.emptyResponse)); return
            }
            if let text = json["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(trimmed.isEmpty ? .failure(.emptyResponse) : .success(trimmed))
            } else {
                print("❌ \(p.name) response: \(json)")
                completion(.failure(.fromHTTP(status: status, data: data, headers: http?.allHeaderFields)))
            }
        }
        currentTask = task
        task.resume()
    }

    /// Whisper `prompt` biases toward dictionary terms and discourages filler hallucination.
    /// Do NOT list near-homophone acronyms (e.g. STT) — Whisper will force them over STD/etc.
    private static func whisperBiasPrompt(for p: STTProvider) -> String? {
        var bits: [String] = []
        if p.id == "groq" || p.id == "openai" {
            bits.append("Clean dictation. Prefer exact words spoken; do not add filler like good, yeah, um.")
            bits.append("Never invent credits, subtitles, channel plugs, or 'Subtitles by the Amara.org community'.")
            bits.append("Keep acronyms exactly as spoken; do not substitute similar letter sequences.")
            bits.append("Product names: Groq, Whisper.")
            bits.append("If the speaker says comma, coma, next line, or new line, keep those words as spoken.")
        }
        var vocab = CorrectionDictionary.shared.vocabularyHints(limit: 50)
        for term in ["Groq", "Whisper", "API"] {
            if !vocab.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
                vocab.append(term)
            }
        }
        if let app = FocusMemory.lastAppName, !app.isEmpty {
            vocab.insert(app, at: 0)
        }
        if !vocab.isEmpty {
            bits.append("Vocabulary: " + vocab.joined(separator: ", ") + ".")
        }
        let prompt = bits.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : String(prompt.prefix(800))
    }
}
