import Foundation

/// Lightweight on-device cleanup shared by Mac (whisper-cli) and iOS (embedded whisper.cpp).
/// Drops filler words, collapses repeats and spacing, capitalises sentences.
public enum TranscriptionCleanup {
    public static func localCleanup(_ text: String) -> String {
        var s = text
        let fillers = ["um+", "uh+", "erm+", "er", "ah+", "hmm+", "mm+", "you know", "I mean", "sort of", "kind of"]
        for f in fillers {
            let pattern = #"(?i)(^|[\s,])"# + f + #"[,.]?(?=\s|$)"#
            s = s.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"(?i)\b(\w+)( \1\b)+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: ",{2,}", with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
        var result = ""
        var capNext = true
        for ch in s {
            if capNext, ch.isLetter {
                result.append(contentsOf: ch.uppercased())
                capNext = false
            } else {
                result.append(ch)
            }
            if ".!?।".contains(ch) { capNext = true }
        }
        return result
    }
}


extension TranscriptionCleanup {
    /// System prompt for optional Ollama "Enhance transcript" polish (Hinglish-aware).
    public static func enhanceSystemPrompt(languageHint: String) -> String {
        """
        You polish speech-to-text transcripts of Hindi/English (Hinglish) meetings.
        Keep the speaker's meaning and wording. Fix punctuation, casing, and obvious ASR errors.
        Preserve Hindi in Devanagari when the source used Devanagari; keep Roman Hinglish when the source was Roman.
        Do not summarize, invent content, or translate wholesale. Language context: \(languageHint).
        Return ONLY the polished transcript text — no preamble, no quotes, no markdown.
        """
    }

    public static func enhanceUserPrompt(_ transcript: String) -> String {
        "Polish this transcript:\n\n" + transcript
    }
}
