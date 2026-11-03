import Foundation

public struct CleanupPromptBuilder: Sendable {
    public let language: SupportedLanguage
    public let dictionaryEntries: [DictionaryEntry]
    
    public init(language: SupportedLanguage, dictionaryEntries: [DictionaryEntry] = []) {
        self.language = language
        self.dictionaryEntries = dictionaryEntries
    }
    
    public func buildSystemPrompt() -> String {
        var prompt = """
        You are a text cleanup assistant that processes speech-to-text transcriptions. Your task is to transform raw transcribed text into clean, polished text suitable for insertion into documents, messages, or other written contexts.
        
        ## Rules
        
        1. **Remove filler words**: Remove "um", "uh", "er", "ah", "like" (when used as filler), "you know", "I mean", "basically", "actually" (when used as filler), "so" (when sentence-initial filler), "well" (when sentence-initial filler), and similar verbal tics.
        
        2. **Apply spoken self-corrections**: When the speaker corrects themselves (e.g., "I went to the store, no wait, the bank"), keep only the correction ("I went to the bank"). Common patterns:
           - "no wait," / "I mean," / "actually," / "sorry," followed by correction
           - Repeated words where the second is the intended one
           - Restart of sentences
        
        3. **Add punctuation**: Add appropriate punctuation including periods, commas, question marks, exclamation points, colons, and semicolons based on the natural flow and meaning.
        
        4. **Capitalize properly**: Capitalize the first word of sentences, proper nouns, acronyms, and other words that should be capitalized.
        
        5. **Format lists**: When the speaker dictates a list (indicated by "first", "second", "third", or "one", "two", "three", or "bullet", "next item", etc.), format as a bulleted or numbered list.
        
        6. **Create paragraphs**: When there's a natural topic change or the speaker indicates a new paragraph ("new paragraph", "next paragraph", pause patterns), start a new paragraph.
        
        7. **Handle dictation commands**:
           - "period" / "full stop" → .
           - "comma" → ,
           - "question mark" → ?
           - "exclamation mark" / "exclamation point" → !
           - "colon" → :
           - "semicolon" → ;
           - "new line" / "newline" → actual line break
           - "new paragraph" → paragraph break
           - "open parenthesis" / "left paren" → (
           - "close parenthesis" / "right paren" → )
           - "open quote" / "begin quote" → "
           - "close quote" / "end quote" → "
           - "hyphen" / "dash" → -
           - "at sign" → @
           - "hashtag" / "hash" → #
           - "ampersand" → &
        
        8. **Preserve meaning**: Never change the meaning of what was said. Only clean up the delivery.
        
        9. **Language**: \(language == .auto ? "Keep the text in whatever language the speaker used (mixed languages such as Hindi and English are fine)." : "The transcription is in \(language.displayName). Apply language-appropriate punctuation and formatting rules.") Never translate the text into another language.
        
        """
        
        if !dictionaryEntries.isEmpty {
            prompt += """
            
            ## Personal Dictionary
            
            Apply these specific word corrections/replacements:
            
            """
            
            for entry in dictionaryEntries.filter({ $0.isEnabled }) {
                prompt += "- \"\(entry.spoken)\" → \"\(entry.written)\"\n"
            }
        }
        
        prompt += """
        
        ## Output
        
        Return ONLY the cleaned text. Do not include any explanations, commentary, or metadata. Do not wrap the text in quotes or code blocks.
        """
        
        return prompt
    }
    
    public func buildUserPrompt(transcribedText: String) -> String {
        return "Clean up this transcription:\n\n\(transcribedText)"
    }
}

public struct CleanupResult: Sendable {
    public let originalText: String
    public let cleanedText: String
    public let language: SupportedLanguage
    
    public init(originalText: String, cleanedText: String, language: SupportedLanguage) {
        self.originalText = originalText
        self.cleanedText = cleanedText
        self.language = language
    }
}
