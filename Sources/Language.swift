import Foundation

/// A language the STT + LLM can transcribe/correct in.
/// `code` = ISO 639-1 (sent to Whisper/Groq as `language`),
/// `iso3` = ISO 639-3 (sent to ElevenLabs Scribe as `language_code`).
struct Language {
    let code: String
    let name: String
    let iso3: String
}

/// Registry of supported languages for the Language submenu.
/// Whisper large-v3 / Groq `whisper-large-v3-turbo` and `llama-3.3-70b-versatile`
/// are both multilingual; this list covers the most common ones.
enum Languages {
    /// Pseudo-entry: auto-detection (no language code sent to the STT).
    static let auto = Language(code: "auto", name: "Auto-detect", iso3: "")

    static let all: [Language] = [
        .init(code: "en", name: "English",     iso3: "eng"),
        .init(code: "th", name: "Thai",        iso3: "tha"),
        .init(code: "zh", name: "Chinese",     iso3: "zho"),
        .init(code: "ja", name: "Japanese",    iso3: "jpn"),
        .init(code: "ko", name: "Korean",      iso3: "kor"),
        .init(code: "vi", name: "Vietnamese",  iso3: "vie"),
        .init(code: "id", name: "Indonesian",  iso3: "ind"),
        .init(code: "ms", name: "Malay",       iso3: "msa"),
        .init(code: "es", name: "Spanish",     iso3: "spa"),
        .init(code: "fr", name: "French",      iso3: "fra"),
        .init(code: "de", name: "German",      iso3: "deu"),
        .init(code: "it", name: "Italian",     iso3: "ita"),
        .init(code: "pt", name: "Portuguese",  iso3: "por"),
        .init(code: "ru", name: "Russian",     iso3: "rus"),
        .init(code: "ar", name: "Arabic",      iso3: "ara"),
        .init(code: "hi", name: "Hindi",       iso3: "hin"),
    ]

    /// Look up by app code; "auto" resolves to the auto-detect pseudo-entry.
    static func find(_ code: String) -> Language? {
        if code == "auto" { return auto }
        return all.first { $0.code == code }
    }
}
