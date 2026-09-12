import Foundation

/// Spoken punctuation → real characters. Runs locally after STT (and after dictionary).
/// No network — does not add transcription lag.
enum SpokenCommands {
    static func apply(_ text: String) -> String {
        var s = text
        let replacements: [(String, String)] = [
            (#"(?i)\bnext[\s-]+line\b"#, "\n"),
            (#"(?i)\bnew[\s-]+line\b"#, "\n"),
            (#"(?i)\bnewline\b"#, "\n"),
            (#"(?i)\bcoma\b"#, ","),
            (#"(?i)\bcomma\b"#, ","),
            (#"(?i)\bquestion\s+mark\b"#, "?"),
            (#"(?i)\bexclamation\s+(?:mark|point)\b"#, "!"),
            (#"(?i)\bfull\s+stop\b"#, "."),
        ]
        for (pattern, replacement) in replacements {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        // "hello ," → "hello,"
        s = s.replacingOccurrences(of: #"\s+([,?.!])"#, with: "$1", options: .regularExpression)
        // "hello,world" → "hello, world"
        s = s.replacingOccurrences(of: #"([,?.!])([^\s\n])"#, with: "$1 $2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s
    }
}
