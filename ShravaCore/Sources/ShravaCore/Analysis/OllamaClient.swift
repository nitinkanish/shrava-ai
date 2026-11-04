import Foundation

public enum OllamaEndpointMode: String, Codable, Sendable, CaseIterable, Hashable {
    case cloud
    case local
    case custom

    public var displayName: String {
        switch self {
        case .cloud: return "Ollama Cloud"
        case .local: return "Local Ollama"
        case .custom: return "Custom URL"
        }
    }
}

public struct AnalysisSettings: Codable, Equatable, Sendable {
    public var endpointMode: OllamaEndpointMode
    public var customBaseURL: String
    public var model: String
    /// Soft character budget before chunked analysis (characters of transcript).
    public var maxCharsPerRequest: Int

    public static let `default` = AnalysisSettings(
        endpointMode: .cloud,
        customBaseURL: "http://localhost:11434",
        model: "gpt-oss:120b-cloud",
        maxCharsPerRequest: 48_000
    )

    public init(endpointMode: OllamaEndpointMode, customBaseURL: String, model: String, maxCharsPerRequest: Int) {
        self.endpointMode = endpointMode
        self.customBaseURL = customBaseURL
        self.model = model
        self.maxCharsPerRequest = maxCharsPerRequest
    }

    public var resolvedBaseURL: URL {
        switch endpointMode {
        case .cloud: return URL(string: "https://ollama.com")!
        case .local: return URL(string: "http://localhost:11434")!
        case .custom:
            let trimmed = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return URL(string: trimmed.isEmpty ? "http://localhost:11434" : trimmed) ?? URL(string: "http://localhost:11434")!
        }
    }

    public var chatURL: URL {
        resolvedBaseURL.appendingPathComponent("api/chat")
    }

    public var needsAPIKey: Bool {
        endpointMode == .cloud || resolvedBaseURL.host?.contains("ollama.com") == true
    }
}

public enum OllamaError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidURL
    case httpStatus(Int, String)
    case emptyResponse
    case decodeFailed(String)
    case timeout
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your Ollama API key in Settings → Meeting Brief. Keys are stored in the Keychain."
        case .invalidURL:
            return "The Ollama endpoint URL is invalid."
        case .httpStatus(let code, let body):
            if code == 401 || code == 403 { return "Ollama rejected the API key (\(code)). Check Settings → Meeting Brief." }
            if code == 402 { return "This model isn’t included in your Ollama plan. Add credits, upgrade, or pick a free-plan model in Settings → Meeting Brief. \(body)" }
            if code == 404 { return "Model or endpoint not found. Check the model name in Settings. \(body)" }
            return "Ollama error (\(code)): \(body)"
        case .emptyResponse:
            return "Ollama returned an empty response."
        case .decodeFailed(let detail):
            return "Couldn’t parse the meeting brief. \(detail)"
        case .timeout:
            return "Analysis timed out. Try a shorter transcript or check your connection."
        case .cancelled:
            return "Analysis was cancelled."
        }
    }
}

public enum OllamaSecrets {
    public static let keychainKey = "ollama_api_key"

    public static func loadAPIKey() -> String? {
        try? KeychainManager.shared.load(key: keychainKey)
    }

    public static func saveAPIKey(_ key: String) throws {
        try KeychainManager.shared.save(key: keychainKey, value: key)
    }

    public static func deleteAPIKey() {
        try? KeychainManager.shared.delete(key: keychainKey)
    }

    public static func hasAPIKey() -> Bool {
        KeychainManager.shared.exists(key: keychainKey)
    }
}

/// Talks to Ollama Cloud or a local/custom Ollama server for Meeting Brief analysis.
public final class OllamaClient: @unchecked Sendable {
    public static let shared = OllamaClient()

    public var settings: AnalysisSettings {
        get { AnalysisSettingsStore.load() }
        set { AnalysisSettingsStore.save(newValue) }
    }

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 180
            cfg.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Public API

    public func testConnection() async throws -> String {
        let settings = self.settings
        let reply = try await chat(
            messages: [
                .init(role: "system", content: "You are a connectivity probe. Reply with exactly: OK"),
                .init(role: "user", content: "ping")
            ],
            settings: settings,
            formatJSON: false,
            temperature: 0
        )
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Polish a Whisper transcript with the configured cloud model (meaning-preserving).
    public func enhanceTranscript(_ text: String, languageHint: String = "Hindi and English") async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let settings = AnalysisSettingsStore.load()
        let messages = [
            ChatMessage(role: "system", content: TranscriptionCleanup.enhanceSystemPrompt(languageHint: languageHint)),
            ChatMessage(role: "user", content: TranscriptionCleanup.enhanceUserPrompt(trimmed))
        ]
        let out = try await chat(messages: messages, settings: settings, formatJSON: false, temperature: 0.2)
        let polished = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return polished.isEmpty ? text : polished
    }

    public func analyzeMeeting(transcript: String, titleHint: String? = nil) async throws -> MeetingBrief {
        let settings = self.settings
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OllamaError.emptyResponse
        }

        if trimmed.count <= settings.maxCharsPerRequest {
            return try await analyzeChunk(trimmed, settings: settings, titleHint: titleHint, partLabel: nil)
        }

        // Chunk long transcripts, then merge.
        let chunks = chunkTranscript(trimmed, maxChars: settings.maxCharsPerRequest)
        var partials: [MeetingBrief] = []
        for (idx, chunk) in chunks.enumerated() {
            let label = "Part \(idx + 1) of \(chunks.count)"
            let brief = try await analyzeChunk(chunk, settings: settings, titleHint: titleHint, partLabel: label)
            partials.append(brief)
        }
        return try await mergeBriefs(partials, settings: settings, titleHint: titleHint)
    }

    // MARK: - Internals

    private struct ChatMessage: Encodable {
        let role: String
        let content: String
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let format: String?
        let options: [String: Double]?
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable { let role: String?; let content: String? }
        let message: Message?
        let error: String?
    }

    private func analyzeChunk(_ text: String, settings: AnalysisSettings, titleHint: String?, partLabel: String?) async throws -> MeetingBrief {
        let system = """
        You are Shrava Meeting Brief. Analyze meeting / brainstorming transcripts.
        Respond with ONLY valid JSON matching this schema (no markdown fences):
        {
          "meeting_type": "planning" | "project_discussion" | "brainstorming" | "other",
          "summary": "2-4 sentence overview",
          "key_points": ["..."],
          "decisions": ["..."],
          "ideas": ["..."],  // especially for brainstorming; empty array otherwise ok
          "open_questions": ["..."],  // risks and unresolved questions
          "action_items": [
            {"task":"...","owner":null or string,"due_date":null or string,"priority":null or "high"|"medium"|"low"}
          ]
        }
        Rules:
        - Auto-detect meeting_type from content.
        - Capture ALL action items mentioned (assign owner/due/priority only when stated).
        - Be concise; use empty arrays when nothing applies.
        - Do not invent people or deadlines.
        """

        var user = "Transcript:\n\n\(text)"
        if let titleHint, !titleHint.isEmpty { user = "Context: \(titleHint)\n\n" + user }
        if let partLabel { user = "\(partLabel) — analyze this segment fully.\n\n" + user }

        let raw = try await chat(
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            settings: settings,
            formatJSON: true,
            temperature: 0.2
        )
        return try decodeBrief(raw, model: settings.model)
    }

    private func mergeBriefs(_ briefs: [MeetingBrief], settings: AnalysisSettings, titleHint: String?) async throws -> MeetingBrief {
        guard briefs.count > 1 else { return briefs.first ?? MeetingBrief(model: settings.model) }
        // Prefer a model merge when possible; fall back to local concat.
        let payload: [String: Any] = [
            "parts": briefs.map { b -> [String: Any] in
                [
                    "meeting_type": b.meetingType.rawValue,
                    "summary": b.summary,
                    "key_points": b.keyPoints,
                    "decisions": b.decisions,
                    "ideas": b.ideas,
                    "open_questions": b.openQuestions,
                    "action_items": b.actionItems.map { a -> [String: Any?] in
                        ["task": a.task, "owner": a.owner, "due_date": a.dueDate, "priority": a.priority]
                    }
                ]
            }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return concatenate(briefs, model: settings.model)
        }

        let system = """
        Merge these partial meeting briefs into ONE JSON object with the same schema:
        meeting_type, summary, key_points, decisions, ideas, open_questions, action_items
        (action_items: task, owner, due_date, priority). Deduplicate. Prefer the most specific meeting_type.
        Respond with ONLY JSON.
        """
        do {
            let raw = try await chat(
                messages: [
                    .init(role: "system", content: system),
                    .init(role: "user", content: (titleHint.map { "Title: \($0)\n" } ?? "") + json)
                ],
                settings: settings,
                formatJSON: true,
                temperature: 0.1
            )
            return try decodeBrief(raw, model: settings.model)
        } catch {
            return concatenate(briefs, model: settings.model)
        }
    }

    private func concatenate(_ briefs: [MeetingBrief], model: String) -> MeetingBrief {
        func uniq(_ items: [String]) -> [String] {
            var seen = Set<String>()
            var out: [String] = []
            for i in items {
                let k = i.lowercased()
                if seen.insert(k).inserted { out.append(i) }
            }
            return out
        }
        let type = briefs.map(\.meetingType).first(where: { $0 != .other }) ?? .other
        var actions: [MeetingActionItem] = []
        var seenTasks = Set<String>()
        for b in briefs {
            for a in b.actionItems {
                let k = a.task.lowercased()
                if seenTasks.insert(k).inserted { actions.append(a) }
            }
        }
        return MeetingBrief(
            meetingType: type,
            summary: briefs.map(\.summary).filter { !$0.isEmpty }.joined(separator: " "),
            keyPoints: uniq(briefs.flatMap(\.keyPoints)),
            decisions: uniq(briefs.flatMap(\.decisions)),
            ideas: uniq(briefs.flatMap(\.ideas)),
            openQuestions: uniq(briefs.flatMap(\.openQuestions)),
            actionItems: actions,
            model: model,
            analyzedAt: Date()
        )
    }

    private func chat(messages: [ChatMessage], settings: AnalysisSettings, formatJSON: Bool, temperature: Double) async throws -> String {
        let url = settings.chatURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        if settings.needsAPIKey {
            guard let key = OllamaSecrets.loadAPIKey(), !key.isEmpty else { throw OllamaError.missingAPIKey }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body = ChatRequest(
            model: settings.model,
            messages: messages,
            stream: false,
            format: formatJSON ? "json" : nil,
            options: ["temperature": temperature]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw OllamaError.timeout
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw OllamaError.cancelled
        }

        guard let http = response as? HTTPURLResponse else { throw OllamaError.emptyResponse }
        if http.statusCode >= 400 {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            // Never echo Authorization-related secrets; strip common key-looking tokens.
            let safe = bodyText
                .replacingOccurrences(of: #"(?i)bearer\s+[A-Za-z0-9._\-]+"#, with: "Bearer [redacted]", options: .regularExpression)
                .prefix(400)
            throw OllamaError.httpStatus(http.statusCode, String(safe))
        }

        if let parsed = try? JSONDecoder().decode(ChatResponse.self, from: data) {
            if let err = parsed.error, !err.isEmpty { throw OllamaError.httpStatus(http.statusCode, String(err.prefix(400))) }
            if let content = parsed.message?.content, !content.isEmpty { return content }
        }
        // Some gateways return raw text
        if let text = String(data: data, encoding: .utf8), !text.isEmpty { return text }
        throw OllamaError.emptyResponse
    }

    private func decodeBrief(_ raw: String, model: String) throws -> MeetingBrief {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        guard let data = text.data(using: .utf8) else { throw OllamaError.decodeFailed("Invalid UTF-8") }
        do {
            var brief = try JSONDecoder().decode(MeetingBrief.self, from: data)
            brief.model = model
            brief.analyzedAt = Date()
            return brief
        } catch {
            throw OllamaError.decodeFailed(error.localizedDescription)
        }
    }

    private func chunkTranscript(_ text: String, maxChars: Int) -> [String] {
        TranscriptChunking.chunk(text, maxChars: maxChars)
    }
}

/// Pure transcript splitter used by OllamaClient (and unit tests).
public enum TranscriptChunking {
    public static func chunk(_ text: String, maxChars: Int) -> [String] {
        guard maxChars > 0, text.count > maxChars else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = text.index(start, offsetBy: maxChars, limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex {
                let windowStart = text.index(end, offsetBy: -min(800, text.distance(from: start, to: end)), limitedBy: start) ?? start
                let window = text[windowStart..<end]
                if let r = window.range(of: "\n\n", options: .backwards) {
                    end = r.lowerBound
                } else if let r = window.range(of: ". ", options: .backwards) {
                    end = r.upperBound
                }
            }
            let piece = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            start = end
        }
        return chunks.isEmpty ? [text] : chunks
    }
}

public enum AnalysisSettingsStore {
    private static let key = "shrava.analysisSettings"

    public static func load() -> AnalysisSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var s = try? JSONDecoder().decode(AnalysisSettings.self, from: data) else {
            return .default
        }
        // Migrate superseded default model tags.
        let legacy = ["deepseek-v4.1-flash", "deepseek-v4.1-flash:latest", "deepseek-v3.1:671b-cloud", "deepseek-v3.1:671b"]
        if legacy.contains(s.model) {
            s.model = AnalysisSettings.default.model
            save(s)
        }
        return s
    }

    public static func save(_ settings: AnalysisSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
