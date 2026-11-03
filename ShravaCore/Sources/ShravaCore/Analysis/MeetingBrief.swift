import Foundation

public enum MeetingType: String, Codable, Sendable, CaseIterable {
    case planning
    case projectDiscussion = "project_discussion"
    case brainstorming
    case other

    public var displayName: String {
        switch self {
        case .planning: return "Planning"
        case .projectDiscussion: return "Project discussion"
        case .brainstorming: return "Brainstorming"
        case .other: return "Meeting"
        }
    }
}

public struct MeetingActionItem: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var task: String
    public var owner: String?
    public var dueDate: String?
    public var priority: String?
    public var done: Bool

    public init(id: UUID = UUID(), task: String, owner: String? = nil, dueDate: String? = nil, priority: String? = nil, done: Bool = false) {
        self.id = id; self.task = task; self.owner = owner; self.dueDate = dueDate; self.priority = priority; self.done = done
    }

    enum CodingKeys: String, CodingKey { case id, task, owner, dueDate = "due_date", priority, done }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate)
        priority = try c.decodeIfPresent(String.self, forKey: .priority)
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(task, forKey: .task)
        try c.encodeIfPresent(owner, forKey: .owner)
        try c.encodeIfPresent(dueDate, forKey: .dueDate)
        try c.encodeIfPresent(priority, forKey: .priority)
        try c.encode(done, forKey: .done)
    }
}

public struct MeetingBrief: Codable, Sendable, Equatable {
    public var meetingType: MeetingType
    public var summary: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var ideas: [String]
    public var openQuestions: [String]
    public var actionItems: [MeetingActionItem]
    public var model: String?
    public var analyzedAt: Date

    public init(
        meetingType: MeetingType = .other,
        summary: String = "",
        keyPoints: [String] = [],
        decisions: [String] = [],
        ideas: [String] = [],
        openQuestions: [String] = [],
        actionItems: [MeetingActionItem] = [],
        model: String? = nil,
        analyzedAt: Date = Date()
    ) {
        self.meetingType = meetingType
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.ideas = ideas
        self.openQuestions = openQuestions
        self.actionItems = actionItems
        self.model = model
        self.analyzedAt = analyzedAt
    }

    enum CodingKeys: String, CodingKey {
        case meetingType = "meeting_type"
        case summary
        case keyPoints = "key_points"
        case decisions
        case ideas
        case openQuestions = "open_questions"
        case actionItems = "action_items"
        case model, analyzedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try c.decodeIfPresent(String.self, forKey: .meetingType) {
            let normalized = raw.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
            meetingType = MeetingType(rawValue: normalized)
                ?? (normalized.contains("brain") ? .brainstorming
                    : normalized.contains("plan") ? .planning
                    : normalized.contains("project") || normalized.contains("discuss") ? .projectDiscussion
                    : .other)
        } else {
            meetingType = .other
        }
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        ideas = try c.decodeIfPresent([String].self, forKey: .ideas) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        actionItems = try c.decodeIfPresent([MeetingActionItem].self, forKey: .actionItems) ?? []
        model = try c.decodeIfPresent(String.self, forKey: .model)
        analyzedAt = (try? c.decode(Date.self, forKey: .analyzedAt)) ?? Date()
    }


    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(meetingType.rawValue, forKey: .meetingType)
        try c.encode(summary, forKey: .summary)
        try c.encode(keyPoints, forKey: .keyPoints)
        try c.encode(decisions, forKey: .decisions)
        try c.encode(ideas, forKey: .ideas)
        try c.encode(openQuestions, forKey: .openQuestions)
        try c.encode(actionItems, forKey: .actionItems)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(analyzedAt, forKey: .analyzedAt)
    }

    public func asMarkdown(title: String = "Meeting Brief") -> String {
        var lines: [String] = ["# \(title)", "", "**Type:** \(meetingType.displayName)", ""]
        if !summary.isEmpty {
            lines += ["## Summary", summary, ""]
        }
        func bullets(_ heading: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append("## \(heading)")
            for i in items { lines.append("- \(i)") }
            lines.append("")
        }
        bullets("Key discussion points", keyPoints)
        bullets("Decisions", decisions)
        bullets("Ideas", ideas)
        bullets("Open questions / risks", openQuestions)
        if !actionItems.isEmpty {
            lines.append("## Action items")
            for a in actionItems {
                var row = "- [\(a.done ? "x" : " ")] \(a.task)"
                if let o = a.owner, !o.isEmpty { row += " — @\(o)" }
                if let d = a.dueDate, !d.isEmpty { row += " (due \(d))" }
                if let p = a.priority, !p.isEmpty { row += " [\(p)]" }
                lines.append(row)
            }
            lines.append("")
        }
        if let model {
            lines += ["---", "_Analyzed with \(model)_"]
        }
        return lines.joined(separator: "\n")
    }
}
