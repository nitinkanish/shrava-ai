import Foundation

public enum SlackError: LocalizedError, Sendable {
    case missingToken
    case invalidToken
    case api(String)
    case httpStatus(Int, String)
    case decodeFailed
    case notInPrivateChannel(String)
    case noDefaultChannel

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Add a Slack Bot User OAuth Token (xoxb-…) in Settings → Slack."
        case .invalidToken:
            return "Slack token must start with xoxb-. Paste the Bot User OAuth Token from api.slack.com/apps."
        case .api(let code):
            return "Slack API error: \(code)"
        case .httpStatus(let code, let body):
            return "Slack HTTP \(code): \(body)"
        case .decodeFailed:
            return "Couldn’t parse the Slack response."
        case .notInPrivateChannel(let name):
            return "The bot isn’t in #\(name). In Slack, run /invite @YourBot in that private channel."
        case .noDefaultChannel:
            return "Pick a default Slack channel in Settings → Slack, or choose one when sending."
        }
    }
}

public struct SlackAuthInfo: Sendable, Equatable {
    public let team: String
    public let user: String
    public let url: String?
    public let teamID: String?
    public let userID: String?
}

public struct SlackChannel: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let isPrivate: Bool
    public let isMember: Bool

    public var displayName: String { isPrivate ? "🔒 \(name)" : "#\(name)" }
}

public struct SlackPostResult: Sendable {
    public let channelID: String
    public let messageTS: String
    public let permalink: URL?
}

/// Minimal Slack Web API client for Meeting Brief posts.
public final class SlackClient: @unchecked Sendable {
    public static let shared = SlackClient()

    private let session: URLSession
    private let baseURL = URL(string: "https://slack.com/api/")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Auth

    public func testAuth(token: String? = nil) async throws -> SlackAuthInfo {
        let tok = try resolveToken(token)
        let json = try await postForm(method: "auth.test", token: tok, fields: [:])
        guard (json["ok"] as? Bool) == true else {
            throw SlackError.api((json["error"] as? String) ?? "unknown")
        }
        return SlackAuthInfo(
            team: (json["team"] as? String) ?? "Workspace",
            user: (json["user"] as? String) ?? "bot",
            url: json["url"] as? String,
            teamID: json["team_id"] as? String,
            userID: json["user_id"] as? String
        )
    }

    // MARK: - Channels

    public func listChannels(token: String? = nil) async throws -> [SlackChannel] {
        let tok = try resolveToken(token)
        var cursor: String? = nil
        var all: [SlackChannel] = []
        repeat {
            var fields: [String: String] = [
                "types": "public_channel,private_channel",
                "exclude_archived": "true",
                "limit": "200"
            ]
            if let cursor, !cursor.isEmpty { fields["cursor"] = cursor }
            let json = try await postForm(method: "conversations.list", token: tok, fields: fields)
            guard (json["ok"] as? Bool) == true else {
                throw SlackError.api((json["error"] as? String) ?? "unknown")
            }
            let channels = (json["channels"] as? [[String: Any]]) ?? []
            for ch in channels {
                guard let id = ch["id"] as? String, let name = ch["name"] as? String else { continue }
                all.append(SlackChannel(
                    id: id,
                    name: name,
                    isPrivate: (ch["is_private"] as? Bool) ?? false,
                    isMember: (ch["is_member"] as? Bool) ?? false
                ))
            }
            let next = (json["response_metadata"] as? [String: Any])?["next_cursor"] as? String
            cursor = (next?.isEmpty == false) ? next : nil
        } while cursor != nil
        return all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func joinPublicChannel(id: String, token: String? = nil) async throws {
        let tok = try resolveToken(token)
        let json = try await postForm(method: "conversations.join", token: tok, fields: ["channel": id])
        if (json["ok"] as? Bool) == true { return }
        let err = (json["error"] as? String) ?? "unknown"
        if err == "already_in_channel" || err == "method_not_supported_for_channel_type" { return }
        throw SlackError.api(err)
    }

    // MARK: - Post brief

    public func postMeetingBrief(
        brief: MeetingBrief,
        channelID: String,
        channelName: String? = nil,
        isPrivate: Bool = false,
        title: String,
        date: Date,
        durationSeconds: Double,
        transcript: String? = nil,
        includeTranscript: Bool? = nil,
        token: String? = nil
    ) async throws -> SlackPostResult {
        let tok = try resolveToken(token)
        let settings = SlackSettingsStore.load()
        let wantTranscript = includeTranscript ?? settings.includeTranscript

        // Ensure membership for public channels.
        do {
            try await ensureMembership(
                channelID: channelID,
                channelName: channelName,
                isPrivate: isPrivate,
                token: tok
            )
        } catch {
            // Continue; postMessage may still succeed if already a member / chat:write.public.
        }

        let payload = SlackBriefFormatter.makePayload(
            brief: brief,
            title: title,
            date: date,
            durationSeconds: durationSeconds
        )

        let response = try await postJSON(method: "chat.postMessage", token: tok, body: [
            "channel": channelID,
            "text": payload.text,
            "blocks": payload.blocks,
            "unfurl_links": false,
            "unfurl_media": false
        ])

        if (response["ok"] as? Bool) != true {
            let err = (response["error"] as? String) ?? "unknown"
            if err == "not_in_channel" {
                if isPrivate {
                    throw SlackError.notInPrivateChannel(channelName ?? channelID)
                }
                // Try join then retry once for public channels.
                try await joinPublicChannel(id: channelID, token: tok)
                let retry = try await postJSON(method: "chat.postMessage", token: tok, body: [
                    "channel": channelID,
                    "text": payload.text,
                    "blocks": payload.blocks,
                    "unfurl_links": false,
                    "unfurl_media": false
                ])
                guard (retry["ok"] as? Bool) == true else {
                    throw SlackError.api((retry["error"] as? String) ?? err)
                }
                return try await finalizePost(retry, channelID: channelID, transcript: wantTranscript ? transcript : nil, token: tok)
            }
            throw SlackError.api(err)
        }

        return try await finalizePost(response, channelID: channelID, transcript: wantTranscript ? transcript : nil, token: tok)
    }

    /// Convenience: post using saved default channel.
    public func postMeetingBriefToDefault(
        brief: MeetingBrief,
        title: String,
        date: Date,
        durationSeconds: Double,
        transcript: String?
    ) async throws -> SlackPostResult {
        let s = SlackSettingsStore.load()
        guard let channelID = s.defaultChannelID, !channelID.isEmpty else {
            throw SlackError.noDefaultChannel
        }
        return try await postMeetingBrief(
            brief: brief,
            channelID: channelID,
            channelName: s.defaultChannelName,
            isPrivate: s.defaultChannelName?.hasPrefix("🔒") == true,
            title: title,
            date: date,
            durationSeconds: durationSeconds,
            transcript: transcript,
            includeTranscript: s.includeTranscript
        )
    }

    public func permalink(channelID: String, messageTS: String, token: String? = nil) async throws -> URL? {
        let tok = try resolveToken(token)
        let json = try await postForm(method: "chat.getPermalink", token: tok, fields: [
            "channel": channelID,
            "message_ts": messageTS
        ])
        guard (json["ok"] as? Bool) == true, let link = json["permalink"] as? String else { return nil }
        return URL(string: link)
    }

    // MARK: - Internals

    private func finalizePost(
        _ json: [String: Any],
        channelID: String,
        transcript: String?,
        token: String
    ) async throws -> SlackPostResult {
        let ts = (json["ts"] as? String) ?? ((json["message"] as? [String: Any])?["ts"] as? String) ?? ""
        let ch = (json["channel"] as? String) ?? channelID
        if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !ts.isEmpty {
            let chunks = SlackBriefFormatter.transcriptChunks(transcript)
            for (i, chunk) in chunks.enumerated() {
                let header = chunks.count == 1 ? "*Full transcript*" : "*Full transcript* (\(i + 1)/\(chunks.count))"
                let body: [String: Any] = [
                    "channel": ch,
                    "thread_ts": ts,
                    "text": "Transcript part \(i + 1)",
                    "blocks": [[
                        "type": "section",
                        "text": ["type": "mrkdwn", "text": "\(header)\n```\(clampForCode(chunk))```"]
                    ]],
                    "unfurl_links": false
                ]
                _ = try? await postJSON(method: "chat.postMessage", token: token, body: body)
            }
        }
        let link = try? await permalink(channelID: ch, messageTS: ts, token: token)
        return SlackPostResult(channelID: ch, messageTS: ts, permalink: link)
    }

    private func ensureMembership(
        channelID: String,
        channelName: String?,
        isPrivate: Bool,
        token: String
    ) async throws {
        if isPrivate { return }
        try await joinPublicChannel(id: channelID, token: token)
    }

    private func resolveToken(_ override: String?) throws -> String {
        if let override {
            let t = override.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("xoxb-") else { throw SlackError.invalidToken }
            return t
        }
        guard let t = SlackSecrets.loadToken(), t.hasPrefix("xoxb-") else {
            throw SlackError.missingToken
        }
        return t
    }

    private func postForm(method: String, token: String, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?"))
        let body = fields
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        return try await perform(request)
    }

    private func postJSON(method: String, token: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Never echo Authorization; body from Slack is fine.
            throw SlackError.httpStatus(http.statusCode, String(body.prefix(200)))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackError.decodeFailed
        }
        return json
    }

    private func clampForCode(_ s: String) -> String {
        // Leave room for fencing + header inside a section.
        let limit = 2800
        if s.count <= limit { return s }
        return String(s.prefix(limit - 1)) + "…"
    }
}
