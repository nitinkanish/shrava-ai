import Foundation

/// Builds Block Kit payloads for Meeting Brief posts. Respects Slack section ≤3000 chars and ≤50 blocks.
public enum SlackBriefFormatter {
    public static let footerText = "Sent from Shrava — Every Conversation, Captured"
    private static let sectionLimit = 2900
    private static let maxBlocks = 50
    private static let headerLimit = 150

    public struct Payload {
        public let text: String
        public let blocks: [[String: Any]]
    }

    public static func makePayload(
        brief: MeetingBrief,
        title: String,
        date: Date,
        durationSeconds: Double
    ) -> Payload {
        let safeTitle = clamp(title.isEmpty ? brief.meetingType.displayName : title, max: headerLimit)
        let fallback = "Meeting Brief: \(safeTitle)"
        var blocks: [[String: Any]] = []

        blocks.append([
            "type": "header",
            "text": ["type": "plain_text", "text": safeTitle, "emoji": true]
        ])

        let dateStr = date.formatted(date: .abbreviated, time: .shortened)
        let dur = formatDuration(durationSeconds)
        let contextBits = [
            brief.meetingType.displayName,
            dateStr,
            dur,
            brief.model.map { "via \($0)" }
        ].compactMap { $0 }.filter { !$0.isEmpty }
        blocks.append([
            "type": "context",
            "elements": [["type": "mrkdwn", "text": contextBits.joined(separator: "  ·  ")]]
        ])
        blocks.append(["type": "divider"])

        appendSection(heading: "*Summary*", body: brief.summary, into: &blocks)

        if !brief.keyPoints.isEmpty {
            appendBullets(heading: "*Key insights*", items: brief.keyPoints, into: &blocks)
        }
        if !brief.decisions.isEmpty {
            appendBullets(heading: "*Decisions*", items: brief.decisions, into: &blocks)
        }
        if !brief.ideas.isEmpty {
            appendBullets(heading: "*Ideas*", items: brief.ideas, into: &blocks)
        }
        if !brief.openQuestions.isEmpty {
            appendBullets(heading: "*Open questions / risks*", items: brief.openQuestions, into: &blocks)
        }
        if !brief.actionItems.isEmpty {
            let lines = brief.actionItems.map { item -> String in
                let box = item.done ? "☑" : "☐"
                var row = "\(box) \(item.task)"
                if let o = item.owner, !o.isEmpty { row += " — _\(o)_" }
                if let d = item.dueDate, !d.isEmpty { row += " (due \(d))" }
                if let p = item.priority, !p.isEmpty { row += " [`\(p)`]" }
                return row
            }
            appendBullets(heading: "*Action items*", items: lines, into: &blocks, alreadyFormatted: true)
        }

        if blocks.count >= maxBlocks - 1 {
            blocks = Array(blocks.prefix(maxBlocks - 1))
        }
        blocks.append([
            "type": "context",
            "elements": [["type": "mrkdwn", "text": "_\(footerText)_"]]
        ])
        if blocks.count > maxBlocks {
            blocks = Array(blocks.prefix(maxBlocks))
        }

        return Payload(text: fallback, blocks: blocks)
    }

    /// Chunk a transcript for threaded replies (plain text, ≤3500 chars each).
    public static func transcriptChunks(_ transcript: String, maxChars: Int = 3500) -> [String] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count <= maxChars { return [trimmed] }
        var chunks: [String] = []
        var remaining = trimmed[...]
        while !remaining.isEmpty {
            if remaining.count <= maxChars {
                chunks.append(String(remaining))
                break
            }
            let end = remaining.index(remaining.startIndex, offsetBy: maxChars)
            var split = end
            if let space = remaining[..<end].lastIndex(where: { $0.isWhitespace || $0 == "\n" }) {
                split = space
            }
            let piece = String(remaining[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            remaining = remaining[split...].drop(while: { $0.isWhitespace })
        }
        return chunks
    }

    // MARK: - Helpers

    private static func appendSection(heading: String, body: String, into blocks: inout [[String: Any]]) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for (i, chunk) in splitText("\(heading)\n\(trimmed)").enumerated() {
            guard blocks.count < maxBlocks - 1 else { return }
            let text = i == 0 ? chunk : "\(heading) _(cont.)_\n\(chunk)"
            blocks.append([
                "type": "section",
                "text": ["type": "mrkdwn", "text": clamp(text, max: sectionLimit)]
            ])
        }
    }

    private static func appendBullets(
        heading: String,
        items: [String],
        into blocks: inout [[String: Any]],
        alreadyFormatted: Bool = false
    ) {
        let lines = items.map { alreadyFormatted ? $0 : "• \($0)" }
        var buffer = heading + "\n"
        for line in lines {
            let candidate = buffer + line + "\n"
            if candidate.count > sectionLimit {
                guard blocks.count < maxBlocks - 1 else { return }
                blocks.append([
                    "type": "section",
                    "text": ["type": "mrkdwn", "text": clamp(buffer.trimmingCharacters(in: .whitespacesAndNewlines), max: sectionLimit)]
                ])
                buffer = heading + " _(cont.)_\n" + line + "\n"
            } else {
                buffer = candidate
            }
        }
        let final = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !final.isEmpty, final != heading, blocks.count < maxBlocks - 1 {
            blocks.append([
                "type": "section",
                "text": ["type": "mrkdwn", "text": clamp(final, max: sectionLimit)]
            ])
        }
    }

    private static func splitText(_ text: String) -> [String] {
        if text.count <= sectionLimit { return [text] }
        var chunks: [String] = []
        var remaining = text[...]
        while !remaining.isEmpty {
            if remaining.count <= sectionLimit {
                chunks.append(String(remaining))
                break
            }
            let end = remaining.index(remaining.startIndex, offsetBy: sectionLimit)
            var split = end
            if let nl = remaining[..<end].lastIndex(of: "\n") { split = nl }
            else if let sp = remaining[..<end].lastIndex(of: " ") { split = sp }
            chunks.append(String(remaining[..<split]))
            remaining = remaining[split...].drop(while: { $0.isWhitespace })
        }
        return chunks
    }

    private static func clamp(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let idx = s.index(s.startIndex, offsetBy: max - 1)
        return String(s[..<idx]) + "…"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600
        let m = (s % 3600) / 60
        let r = s % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, r) }
        return "\(r)s"
    }
}
