import Foundation

/// English/Hindi auto-detect helpers, hallucination scrubbing, and transcript quality checks
/// shared by Mac (whisper-cli) and iOS (embedded whisper.cpp).
public enum WhisperLanguageSupport: Sendable {
    public static let autoPair: [SupportedLanguage] = [.english, .hindi]

    /// Patterns Whisper emits when it fails to decode (Hinglish / wrong language / silence).
    private static let hallucinationPatterns: [NSRegularExpression] = {
        let raw = [
            #"\(\s*speaking\s+in\s+foreign\s+language\s*\)"#,
            #"\[\s*speaking\s+in\s+foreign\s+language\s*\]"#,
            #"\(\s*foreign\s+language\s*\)"#,
            #"\[\s*foreign\s+language\s*\]"#,
            #"\(\s*inaudible\s*\)"#,
            #"\[\s*inaudible\s*\]"#,
            #"\(\s*music\s*\)"#,
            #"\[\s*music\s*\]"#,
            #"\(\s*blank_audio\s*\)"#,
            #"\[\s*blank_audio\s*\]"#,
            #"\(\s*silence\s*\)"#,
            #"\[\s*silence\s*\]"#,
            #"<\|nospeech\|>"#,
            #"<\|notimestamps\|>"#
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    /// Prefer Hindi for mixed / ambiguous Hinglish; otherwise pick the stronger of en/hi.
    public static func resolveAuto(detectedCode: String?, enProbability: Double? = nil, hiProbability: Double? = nil) -> SupportedLanguage {
        let code = (detectedCode ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let enP = enProbability ?? (code == "en" || code.hasPrefix("en") ? 1.0 : 0.0)
        let hiP = hiProbability ?? (code == "hi" || code.hasPrefix("hi") ? 1.0 : 0.0)

        if let enProbability, let hiProbability {
            let delta = abs(enProbability - hiProbability)
            // Close scores → mixed / Hinglish → Hindi handles Devanagari + Latin better.
            if delta < 0.15 {
                return .hindi
            }
            return hiProbability >= enProbability ? .hindi : .english
        }

        switch code {
        case "hi", "hin", "hindi": return .hindi
        case "en", "eng", "english": return .english
        case "auto", "":
            // Unknown — default to Hindi so Hinglish meetings don't collapse to English placeholders.
            return .hindi
        default:
            // Other codes (ur, bn, …) — prefer Hindi for South Asian meetings.
            if hiP >= enP { return .hindi }
            return .english
        }
    }

    /// Parse whisper-cli stderr / stdout line:
    /// `whisper_full_with_state: auto-detected language: en (p = 0.545246)`
    public static func parseDetectedLanguage(from cliOutput: String) -> (code: String, probability: Double)? {
        let pattern = #"auto-detected language:\s*([a-zA-Z]+)(?:\s*\(p\s*=\s*([0-9.]+)\))?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(cliOutput.startIndex..<cliOutput.endIndex, in: cliOutput)
        guard let match = re.firstMatch(in: cliOutput, options: [], range: range),
              let codeRange = Range(match.range(at: 1), in: cliOutput) else { return nil }
        let code = String(cliOutput[codeRange]).lowercased()
        var p = 0.0
        if match.numberOfRanges > 2, let pRange = Range(match.range(at: 2), in: cliOutput) {
            p = Double(cliOutput[pRange]) ?? 0
        }
        return (code, p)
    }

    /// Drop bracketed / parenthetical Whisper placeholder lines and scrub inline hallucinations.
    public static func filterHallucinations(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let kept = lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if isPlaceholderLine(trimmed) { return nil }
            return scrubInlinePlaceholders(trimmed)
        }
        return kept
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isPlaceholderLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        // Entire line is a bracketed / parenthetical tag.
        if t.hasPrefix("["), t.hasSuffix("]"), t.count < 80 { return true }
        if t.hasPrefix("("), t.hasSuffix(")"), t.count < 80,
           t.lowercased().contains("foreign") || t.lowercased().contains("inaudible")
            || t.lowercased().contains("music") || t.lowercased().contains("silence")
            || t.lowercased().contains("speaking") {
            return true
        }
        let lower = t.lowercased()
        if lower.contains("speaking in foreign language") { return true }
        if lower == "[foreign language]" || lower == "(foreign language)" { return true }
        return false
    }

    public static func scrubInlinePlaceholders(_ text: String) -> String {
        var s = text
        for re in hallucinationPatterns {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: " ")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the transcript is mostly hallucination placeholders.
    public static func isMostlyPlaceholders(_ text: String) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return true }
        let filtered = filterHallucinations(raw)
        if filtered.isEmpty { return true }
        // If filtering removed most of the content, treat as bad.
        if Double(filtered.count) / Double(max(1, raw.count)) < 0.35 { return true }
        let lower = raw.lowercased()
        let hits = ["foreign language", "speaking in foreign", "[music]", "(music)"].filter { lower.contains($0) }.count
        return hits >= 1 && filtered.count < 40
    }

    /// Heuristic: ~2+ characters of real speech per second of audio for short clips;
    /// softer floor for long meetings (silence / pauses).
    public static func isTooShortRelativeToDuration(_ text: String, durationSeconds: Double) -> Bool {
        let filtered = filterHallucinations(text)
        let chars = filtered.count
        guard durationSeconds > 3 else { return chars == 0 }
        let expectedMin: Double
        if durationSeconds < 60 {
            expectedMin = max(12, durationSeconds * 2.0)
        } else {
            expectedMin = max(40, durationSeconds * 0.8)
        }
        return Double(chars) < expectedMin
    }

    public static func needsRetry(text: String, durationSeconds: Double) -> Bool {
        isMostlyPlaceholders(text) || isTooShortRelativeToDuration(text, durationSeconds: durationSeconds)
    }

    public static func otherAutoLanguage(than language: SupportedLanguage) -> SupportedLanguage {
        language == .hindi ? .english : .hindi
    }

    /// Map a picker selection into an explicit whisper language code (`en` / `hi` / …).
    /// `.auto` is resolved separately via detect.
    public static func whisperCode(for language: SupportedLanguage) -> String {
        language == .auto ? "auto" : language.rawValue
    }
}
