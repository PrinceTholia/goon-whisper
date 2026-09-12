import Foundation

/// Spoken symbol names → characters. Local backup after STT / LLM.
/// Longer phrases first. Optional Whisper period after the command is eaten.
enum SpokenCommands {
    static func apply(_ text: String) -> String {
        var s = text
        let tail = #"[[:space:]]*[.,]?"#
        let replacements: [(String, String)] = [
            (#"(?i)\bnext[\s-]+line\b"# + tail, "\n"),
            (#"(?i)\bnew[\s-]+line\b"# + tail, "\n"),
            (#"(?i)\bnewline\b"# + tail, "\n"),
            (#"(?i)\bat[\s-]+the[\s-]+rate(?:\s+sign)?\b"# + tail, "@"),
            (#"(?i)\bat[\s-]+sign\b"# + tail, "@"),
            (#"(?i)\bdollar\s+sign\b"# + tail, "$"),
            (#"(?i)\bpercentage\s+sign\b"# + tail, "%"),
            (#"(?i)\bpercent\s+sign\b"# + tail, "%"),
            (#"(?i)\bampersand(?:\s+sign)?\b"# + tail, "&"),
            (#"(?i)\basterisk(?:\s+sign)?\b"# + tail, "*"),
            (#"(?i)\bquestion\s+mark\b"# + tail, "?"),
            (#"(?i)\bexclamation\s+(?:mark|point)\b"# + tail, "!"),
            (#"(?i)\bfull\s+stop\b"# + tail, "."),
            (#"(?i)\bforward\s+slash\b"# + tail, "/"),
            (#"(?i)\bback\s*slash\b"# + tail, "\\"),
            (#"(?i)\bslash\b"# + tail, "/"),
            (#"(?i)\bhyphen\b"# + tail, "-"),
            (#"(?i)\bdash\b"# + tail, "-"),
            (#"(?i)\bequals?(?:\s+sign)?\b"# + tail, "="),
            (#"(?i)\bplus(?:\s+sign)?\b"# + tail, "+"),
            (#"(?i)\bminus(?:\s+sign)?\b"# + tail, "-"),
            (#"(?i)\bstar\b"# + tail, "*"),
            (#"(?i)\bcoma\b"# + tail, ","),
            (#"(?i)\bcomma\b"# + tail, ","),
            (#"(?i)\bcolon\b"# + tail, ":"),
            (#"(?i)\bsemicolon\b"# + tail, ";"),
        ]
        for (pattern, replacement) in replacements {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        if s.trimmingCharacters(in: .whitespacesAndNewlines) == ",." {
            return ","
        }

        s = s.replacingOccurrences(of: #"\s+([,?.!])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #",\s*\.(?=\s|$)"#, with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n\s*\.(?=\s|$)"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([,?!])([^\s\n])"#, with: "$1 $2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return s
    }
}
