import Foundation

/// Transcribe audio via cloud STT — supports multiple providers via STTSettings.
class CloudTranscriptionService {
    private var provider: STTProvider { STTSettings.current }

    var isAvailable: Bool { STTSettings.key(for: provider) != nil }

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

        switch p.style {
        case .gemini:
            transcribeGemini(fileData: fileData, key: key, language: language, completion: completion)
        case .elevenlabs, .openAI:
            transcribeMultipart(fileData: fileData, key: key, language: language,
                                provider: p, completion: completion)
        }
    }

    // MARK: - Gemini 3.5 Transcribe (inline WAV)

    private func transcribeGemini(fileData: Data, key: String, language: String,
                                  completion: @escaping (Result<String, DictationAPIError>) -> Void) {
        // ~20MB safety for inline JSON; dictation clips are far smaller
        if fileData.count > 20 * 1024 * 1024 {
            completion(.failure(.network("Audio too large for inline Gemini upload"))); return
        }

        let model = STTSettings.model(for: STTRegistry.provider(id: "gemini"))
        let endpointString = STTSettings.endpointString(for: STTRegistry.provider(id: "gemini"))
        // Endpoint may be the full :generateContent URL; rebuild from model if customized oddly
        let urlString: String
        if endpointString.contains(":generateContent") {
            urlString = endpointString
        } else {
            urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        }
        guard let url = URL(string: urlString) else {
            completion(.failure(.network("Invalid Gemini endpoint"))); return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var transcriptionConfig: [String: Any] = [
            "mode": "SMART"
        ]
        // Auto language detection unless user picked a specific language.
        if let code = langCode(language, style: .gemini) {
            let locale: String
            switch code {
            case "en": locale = "en-US"
            case "hi": locale = "hi-IN"
            case "ja": locale = "ja-JP"
            case "zh": locale = "zh-CN"
            default: locale = code
            }
            transcriptionConfig["languageCodes"] = [locale]
        } else {
            transcriptionConfig["languageCodes"] = [] as [String]
        }

        var vocab = CorrectionDictionary.shared.vocabularyHints(limit: 80)
        if let app = FocusMemory.lastAppName, !app.isEmpty {
            vocab.insert(app, at: 0)
        }
        if !vocab.isEmpty {
            transcriptionConfig["customVocabulary"] = Array(vocab.prefix(100))
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "inlineData": [
                                "mimeType": "audio/wav",
                                "data": fileData.base64EncodedString()
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "audioTranscriptionConfig": transcriptionConfig
            ]
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(.network("Failed to encode request"))); return
        }

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(.network(error.localizedDescription))); return
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 0 {
                completion(.failure(.network("No response"))); return
            }
            if !(200...299).contains(status) {
                // Retry once without generationConfig if the preview rejects it
                if status == 400, let data, Self.geminiConfigRejected(data) {
                    self.transcribeGeminiSimple(fileData: fileData, key: key, url: url, completion: completion)
                    return
                }
                completion(.failure(.fromHTTP(status: status, data: data, headers: http?.allHeaderFields)))
                return
            }
            completion(Self.parseGeminiTranscript(data))
        }.resume()
    }

    /// Fallback: model + audio only (no SMART / language config).
    private func transcribeGeminiSimple(fileData: Data, key: String, url: URL,
                                        completion: @escaping (Result<String, DictationAPIError>) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "inlineData": [
                                "mimeType": "audio/wav",
                                "data": fileData.base64EncodedString()
                            ]
                        ]
                    ]
                ]
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(.network(error.localizedDescription))); return
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if !(200...299).contains(status) {
                completion(.failure(.fromHTTP(status: status, data: data, headers: http?.allHeaderFields)))
                return
            }
            completion(Self.parseGeminiTranscript(data))
        }.resume()
    }

    private static func geminiConfigRejected(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any],
              let msg = (err["message"] as? String)?.lowercased() else { return false }
        return msg.contains("audiotranscription") || msg.contains("unknown name")
            || msg.contains("invalid") || msg.contains("generationconfig")
    }

    private static func parseGeminiTranscript(_ data: Data?) -> Result<String, DictationAPIError> {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.emptyResponse)
        }
        if let err = json["error"] as? [String: Any] {
            let code = err["code"] as? Int ?? 400
            return .failure(.fromHTTP(status: code, data: data, headers: nil))
        }
        // gemini-3.5-transcribe returns parts[].audioTranscription.text (not parts[].text)
        if let candidates = json["candidates"] as? [[String: Any]] {
            var chunks: [String] = []
            for c in candidates {
                guard let content = c["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else { continue }
                for part in parts {
                    if let t = part["text"] as? String, !t.isEmpty {
                        chunks.append(t)
                    } else if let at = part["audioTranscription"] as? [String: Any],
                              let t = at["text"] as? String, !t.isEmpty {
                        chunks.append(t)
                    }
                }
            }
            let text = chunks.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return .success(text) }
        }
        if let text = json["text"] as? String {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return .success(t) }
        }
        print("❌ Gemini response: \(json)")
        return .failure(.emptyResponse)
    }

    // MARK: - OpenAI / ElevenLabs multipart

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
        case .gemini:
            break
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

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
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
        }.resume()
    }

    /// Whisper `prompt` biases toward dictionary terms and discourages filler hallucination.
    private static func whisperBiasPrompt(for p: STTProvider) -> String? {
        var bits: [String] = []
        if p.id == "groq" || p.id == "openai" {
            bits.append("Clean dictation. Prefer exact words spoken; do not add filler like good, yeah, um.")
            bits.append("Acronyms: STT, API, Groq, Gemini, Whisper.")
        }
        var vocab = CorrectionDictionary.shared.vocabularyHints(limit: 50)
        // Always bias common app terms even if dictionary is empty
        for term in ["STT", "Groq", "Gemini", "Whisper", "API"] {
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
