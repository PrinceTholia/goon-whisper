import Foundation

/// Spoken punctuation → real characters. Local only — no extra API, no added lag.
///
/// Whisper almost always appends a sentence period ("Comma." / "Next line.").
/// That period is consumed with the command so you do not get ",." or a stray ".".
enum SpokenCommands {
    static func apply(_ text: String) -> String {
        var s = text

        // Optional leftover STT period/comma after the command word.
        let replacements: [(String, String)] = [
            (#"(?i)\bnext[\s-]+line\b[[:space:]]*[.,]?"#, "\n"),
            (#"(?i)\bnew[\s-]+line\b[[:space:]]*[.,]?"#, "\n"),
            (#"(?i)\bnewline\b[[:space:]]*[.,]?"#, "\n"),
            (#"(?i)\bcoma\b[[:space:]]*[.,]?"#, ","),
            (#"(?i)\bcomma\b[[:space:]]*[.,]?"#, ","),
            (#"(?i)\bquestion\s+mark\b[[:space:]]*[.,]?"#, "?"),
            (#"(?i)\bexclamation\s+(?:mark|point)\b[[:space:]]*[.,]?"#, "!"),
            (#"(?i)\bfull\s+stop\b[[:space:]]*[.,]?"#, "."),
        ]
        for (pattern, replacement) in replacements {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        // If the whole take was just "comma." / "next line."
        if s.trimmingCharacters(in: .whitespacesAndNewlines) == ",." {
            return ","
        }

        // "hello ," → "hello,"
        s = s.replacingOccurrences(of: #"\s+([,?.!])"#, with: "$1", options: .regularExpression)
        // Do not insert a space before a leftover period we are about to drop
        s = s.replacingOccurrences(of: #",\s*\.(?=\s|$)"#, with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n\s*\.(?=\s|$)"#, with: "\n", options: .regularExpression)
        // "hello,world" → "hello, world" (not before newline)
        s = s.replacingOccurrences(of: #"([,?!])([^\s\n])"#, with: "$1 $2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s
    }
}
