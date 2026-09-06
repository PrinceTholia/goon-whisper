import Foundation

/// User-maintained find→replace dictionary for words the STT keeps mis-transcribing.
///
/// Backed by a plain-text file at `~/.whisperapp/dictionary.txt`:
///
///     # comments
///     wrong -> right                 # always replace
///     ~ think | thing | theme        # sound-alikes: AI picks by sentence context
///
/// Used three ways:
///  - `hintForPrompt` / `confusableHintForPrompt`: LLM correction context
///  - `vocabularyHints`: bias Whisper / Gemini toward valid spellings
///  - `apply(to:)`: deterministic replace before paste (rules only — never confusables)
///
/// Matching rules for `wrong -> right`:
///  - `from` is pure ASCII  → `\b`-bounded, case-insensitive regex
///  - `from` has non-ASCII  → exact substring, case-sensitive
final class CorrectionDictionary {
    static let shared = CorrectionDictionary()

    private struct Rule { let from: String; let to: String; let isASCII: Bool }

    /// Built-in English near-homophones the LLM may disambiguate by context.
    /// Never force a single winner — all members are valid vocabulary.
    static let builtInConfusables: [[String]] = [
        ["think", "thing", "theme"],
        ["their", "there", "they're"],
        ["your", "you're"],
        ["its", "it's"],
        ["affect", "effect"],
        ["then", "than"],
        ["weather", "whether"],
        ["accept", "except"],
        ["lose", "loose"],
        ["quiet", "quite"],
        ["principal", "principle"],
        ["STT", "STD"],
        ["Groq", "Grok", "grog"],
    ]

    private static var path: String { KeyStore.dir + "/dictionary.txt" }

    private var rules: [Rule] = []
    private var userConfusables: [[String]] = []
    private var preservedPreamble: [String] = [] // # comments + blank lines before first rule
    private var lastMtime: Date? = nil
    private let lock = NSLock()

    private init() { reload(force: true) }

    // MARK: - Loading (reloads only when the file's mtime changes)

    private func reload(force: Bool) {
        let path = Self.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = attrs?[.modificationDate] as? Date
        if !force, mtime == lastMtime { return }
        lastMtime = mtime

        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let parsed = Self.parse(raw)
        rules = parsed.rules
        userConfusables = parsed.confusables
        preservedPreamble = parsed.preamble
    }

    private struct Parsed {
        var rules: [Rule]
        var confusables: [[String]]
        var preamble: [String]
    }

    private static func parse(_ raw: String) -> Parsed {
        var out = Parsed(rules: [], confusables: [], preamble: [])
        out.rules.reserveCapacity(64)
        var sawContent = false
        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if !sawContent { out.preamble.append(String(line)) }
                continue
            }
            if trimmed.hasPrefix("~") {
                sawContent = true
                let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                let words = body.split(separator: "|").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                if words.count >= 2 { out.confusables.append(words) }
                continue
            }
            guard let arrow = trimmed.range(of: "->") else { continue }
            sawContent = true
            let from = String(trimmed[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            let to   = String(trimmed[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
            if from.isEmpty || to.isEmpty { continue }
            let isASCII = from.unicodeScalars.allSatisfy { $0.isASCII }
            out.rules.append(Rule(from: from, to: to, isASCII: isASCII))
        }
        return out
    }

    private func snapshot() -> (rules: [Rule], confusables: [[String]]) {
        lock.lock(); reload(force: false)
        let r = rules
        let c = userConfusables
        lock.unlock()
        return (r, c)
    }

    /// Built-in + user sound-alike groups (user groups first).
    func confusableGroups() -> [[String]] {
        let snap = snapshot()
        var out = snap.confusables
        var seen = Set(out.map { $0.map { $0.lowercased() }.sorted().joined(separator: "|") })
        for g in Self.builtInConfusables {
            let key = g.map { $0.lowercased() }.sorted().joined(separator: "|")
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(g)
        }
        return out
    }

    // MARK: - Public

    /// Append a rule and persist. Skips empty / identical / duplicate rules.
    @discardableResult
    func addRule(from: String, to: String) -> Bool {
        let f = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !t.isEmpty, f != t else { return false }

        lock.lock()
        defer { lock.unlock() }
        reload(force: true)
        if rules.contains(where: { $0.from.caseInsensitiveCompare(f) == .orderedSame && $0.to == t }) {
            return false
        }
        let isASCII = f.unicodeScalars.allSatisfy { $0.isASCII }
        rules.append(Rule(from: f, to: t, isASCII: isASCII))
        persistLocked()
        return true
    }

    /// Compare pasted text vs user-edited text; add one rule per changed token.
    /// Returns the rules that were newly added.
    @discardableResult
    func learn(from original: String, to edited: String) -> [(from: String, to: String)] {
        let a = tokenize(original)
        let b = tokenize(edited)
        guard !a.isEmpty, !b.isEmpty else { return [] }

        var pairs: [(String, String)] = []
        if a.count == b.count {
            for i in 0..<a.count where a[i] != b[i] {
                // Only learn word-like tokens (skip pure punctuation)
                if looksLearnable(a[i]), looksLearnable(b[i]) {
                    pairs.append((a[i], b[i]))
                }
            }
        } else {
            // Single substitution heuristic: one token removed, one added
            let setA = Set(a)
            let setB = Set(b)
            let removed = a.filter { !setB.contains($0) }
            let added = b.filter { !setA.contains($0) }
            if removed.count == 1, added.count == 1,
               looksLearnable(removed[0]), looksLearnable(added[0]) {
                pairs.append((removed[0], added[0]))
            }
        }

        var added: [(from: String, to: String)] = []
        for (f, t) in pairs {
            if addRule(from: f, to: t) {
                added.append((f, t))
            }
        }
        return added
    }

    private func tokenize(_ text: String) -> [String] {
        text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
    }

    private func looksLearnable(_ token: String) -> Bool {
        let stripped = token.trimmingCharacters(in: .punctuationCharacters)
        guard stripped.count >= 3 else { return false }
        // Never auto-learn ultra-common glue words — those poison dictation.
        let blocked: Set<String> = [
            "a", "an", "the", "and", "or", "but", "if", "to", "of", "in", "on", "at",
            "is", "are", "was", "were", "be", "been", "it", "this", "that", "with",
            "for", "as", "by", "from", "we", "you", "they", "i", "me", "my", "our",
            "only", "also", "just", "like", "have", "has", "had", "do", "does", "did",
            "not", "no", "yes", "ok", "okay", "so", "then", "than", "too", "very",
            "up", "out", "about", "into", "over", "after", "before", "other", "some",
            "good", "check", "keep", "put", "them", "ones", "things", "maybe",
        ]
        return !blocked.contains(stripped.lowercased())
    }

    private func persistLocked() {
        var lines: [String] = []
        if preservedPreamble.isEmpty {
            lines.append("# Personal STT dictionary")
            lines.append("# wrong -> right          = always replace")
            lines.append("# ~ word | word | word    = sound-alikes; AI picks by context")
            lines.append("")
        } else {
            lines.append(contentsOf: preservedPreamble)
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
        }
        for g in userConfusables {
            lines.append("~ " + g.joined(separator: " | "))
        }
        for r in rules {
            lines.append("\(r.from) -> \(r.to)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(atPath: KeyStore.dir, withIntermediateDirectories: true)
        try? text.write(toFile: Self.path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: Self.path)
        lastMtime = Date()
    }

    /// Desired spellings / terms to bias Whisper / Gemini.
    /// Includes dictionary "to" sides and all sound-alike group members.
    func vocabularyHints(limit: Int = 100) -> [String] {
        let snap = snapshot()
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2 else { return }
            let key = t.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            out.append(t)
        }
        // Sound-alikes first so Whisper knows every variant is a real word
        for g in confusableGroups() {
            for w in g { add(w) }
            if out.count >= limit { return out }
        }
        for r in snap.rules {
            add(r.to)
            if r.from.count >= 3, r.from.rangeOfCharacter(from: .letters) != nil {
                add(r.from)
            }
            if out.count >= limit { break }
        }
        return out
    }

    /// Deterministic replacement applied to the final text before paste (rules only).
    func apply(to text: String) -> String {
        let active = snapshot().rules
        guard !active.isEmpty else { return text }
        var result = text
        for r in active {
            if r.isASCII {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: r.from) + "\\b"
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(result.startIndex..., in: result)
                let template = NSRegularExpression.escapedTemplate(for: r.to)
                result = re.stringByReplacingMatches(in: result, range: range, withTemplate: template)
            } else {
                result = result.replacingOccurrences(of: r.from, with: r.to)
            }
        }
        return result
    }

    /// Hint appended to the LLM correction prompt. Empty string when there are no rules.
    var hintForPrompt: String {
        let active = snapshot().rules
        guard !active.isEmpty else { return "" }
        return active.map { "- \($0.from) → \($0.to)" }.joined(separator: "\n")
    }

    /// Sound-alike groups for the LLM — pick by sentence meaning, never force.
    var confusableHintForPrompt: String {
        let groups = confusableGroups()
        guard !groups.isEmpty else { return "" }
        let listed = groups.prefix(20).map { "- " + $0.joined(separator: " / ") }.joined(separator: "\n")
        return """
        Sound-alike / near-homophone sets (STT often picks the wrong one):
        \(listed)
        If the transcript uses a word from a set but sentence meaning clearly wants another from the SAME set, swap it. If ambiguous, leave it unchanged. Do not invent unrelated words.
        """
    }
}
