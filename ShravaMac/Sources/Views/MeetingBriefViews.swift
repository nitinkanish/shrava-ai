import SwiftUI
import AppKit
import ShravaCore
import UniformTypeIdentifiers

struct MeetingBriefSheet: View {
    let entry: HistoryEntry
    @Binding var brief: MeetingBrief?
    var onReanalyze: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showSlackSheet = false
    @State private var slackToast: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Meeting Brief", systemImage: "sparkles")
                    .font(.title2.bold())
                Spacer()
                if brief != nil {
                    Button("Re-analyze", action: onReanalyze)
                    Button("Send to Slack") { showSlackSheet = true }
                    Button("Copy Markdown") { copyMarkdown() }
                    Button("Export…") { exportMarkdown() }
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            if let brief {
                ScrollView {
                    MeetingBriefContent(brief: brief, onToggleAction: toggleAction)
                        .padding()
                }
            } else {
                ProgressView("Analyzing meeting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .overlay(alignment: .bottom) {
            if let slackToast {
                Text(slackToast)
                    .font(.caption)
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $showSlackSheet) {
            if let brief {
                SendBriefToSlackSheet(
                    brief: brief,
                    entry: entry,
                    title: meetingTitle
                )
            }
        }
    }

    private var meetingTitle: String {
        let words = entry.cleanedText.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        return words.isEmpty ? brief?.meetingType.displayName ?? "Meeting Brief" : words
    }

    private func toggleAction(_ item: MeetingActionItem) {
        guard var b = brief, let idx = b.actionItems.firstIndex(where: { $0.id == item.id }) else { return }
        b.actionItems[idx].done.toggle()
        brief = b
        Task { try? await BriefStore.shared.save(b, for: entry.id) }
    }

    private func copyMarkdown() {
        guard let brief else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(brief.asMarkdown(), forType: .string)
    }

    private func exportMarkdown() {
        guard let brief else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Meeting-Brief-\(entry.timestamp.formatted(.iso8601.year().month().day())).md"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? brief.asMarkdown().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct MeetingBriefContent: View {
    let brief: MeetingBrief
    var onToggleAction: (MeetingActionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Text(brief.meetingType.displayName.uppercased())
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
                if let model = brief.model {
                    Text(model).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(brief.analyzedAt, style: .relative)
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            section("Summary") { Text(brief.summary).font(.body).fixedSize(horizontal: false, vertical: true) }
            listSection("Key discussion points", brief.keyPoints)
            listSection("Decisions", brief.decisions)
            listSection("Ideas", brief.ideas)
            listSection("Open questions / risks", brief.openQuestions)

            if !brief.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Action items").font(.headline)
                    ForEach(brief.actionItems) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                onToggleAction(item)
                            } label: {
                                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(item.done ? Color.accentColor : .secondary)
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.task)
                                    .strikethrough(item.done)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    if let o = item.owner, !o.isEmpty {
                                        Label(o, systemImage: "person").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let d = item.dueDate, !d.isEmpty {
                                        Label(d, systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let p = item.priority, !p.isEmpty {
                                        Text(p.capitalized)
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(RoundedRectangle(cornerRadius: 4).fill(priorityColor(p).opacity(0.15)))
                                            .foregroundStyle(priorityColor(p))
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    @ViewBuilder
    private func listSection(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func priorityColor(_ p: String) -> Color {
        switch p.lowercased() {
        case "high": return .red
        case "medium": return .orange
        case "low": return .blue
        default: return .secondary
        }
    }
}

struct AnalysisSettingsView: View {
    @State private var mode: OllamaEndpointMode = AnalysisSettingsStore.load().endpointMode
    @State private var customURL: String = AnalysisSettingsStore.load().customBaseURL
    @State private var model: String = AnalysisSettingsStore.load().model
    @State private var apiKey: String = ""
    @State private var keyPresent = OllamaSecrets.hasAPIKey()
    @State private var showKey = false
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testOK = false

    var body: some View {
        Form {
            Section("Endpoint") {
                Picker("Provider", selection: $mode) {
                    ForEach(OllamaEndpointMode.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, _ in persist() }

                if mode == .custom {
                    TextField("Base URL", text: $customURL)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: customURL) { _, _ in persist() }
                    Text("Example: http://192.168.1.10:11434")
                        .font(.caption).foregroundStyle(.secondary)
                } else if mode == .local {
                    Text("Uses http://localhost:11434 — run `ollama serve` with your model pulled.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Uses https://ollama.com/api/chat with a Bearer API key from ollama.com.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Model") {
                TextField("Model name", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model) { _, _ in persist() }
                Text("Default: gpt-oss:120b-cloud. Fallback tag without -cloud: gpt-oss:120b")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if mode == .cloud || mode == .custom {
                Section("API key") {
                    HStack {
                        Group {
                            if showKey {
                                TextField(keyPresent ? "•••••••• (replace to update)" : "Paste API key", text: $apiKey)
                            } else {
                                SecureField(keyPresent ? "•••••••• (replace to update)" : "Paste API key", text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        Button { showKey.toggle() } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    HStack {
                        Button("Save to Keychain") { saveKey() }
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if keyPresent {
                            Button("Remove key", role: .destructive) {
                                OllamaSecrets.deleteAPIKey()
                                keyPresent = false
                                apiKey = ""
                                testMessage = "API key removed from Keychain."
                                testOK = true
                            }
                        }
                        Spacer()
                        Label(keyPresent ? "Key stored in Keychain" : "No key stored",
                              systemImage: keyPresent ? "checkmark.seal.fill" : "key")
                            .foregroundStyle(keyPresent ? .green : .secondary)
                            .font(.caption)
                    }
                    Text("Never stored in code, UserDefaults, git, or logs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button {
                        Task { await runTest() }
                    } label: {
                        if testing { ProgressView().controlSize(.small) }
                        else { Text("Test connection") }
                    }
                    .disabled(testing)

                    if let testMessage {
                        Text(testMessage)
                            .font(.caption)
                            .foregroundStyle(testOK ? .green : .red)
                            .lineLimit(4)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let s = AnalysisSettingsStore.load()
            mode = s.endpointMode
            customURL = s.customBaseURL
            model = s.model
            keyPresent = OllamaSecrets.hasAPIKey()
        }
    }

    private func persist() {
        var s = AnalysisSettingsStore.load()
        s.endpointMode = mode
        s.customBaseURL = customURL
        s.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AnalysisSettings.default.model : model.trimmingCharacters(in: .whitespacesAndNewlines)
        AnalysisSettingsStore.save(s)
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try OllamaSecrets.saveAPIKey(trimmed)
            keyPresent = true
            apiKey = ""
            testMessage = "API key saved to Keychain."
            testOK = true
        } catch {
            testMessage = "Couldn’t save key: \(error.localizedDescription)"
            testOK = false
        }
    }

    private func runTest() async {
        persist()
        testing = true
        testMessage = nil
        defer { testing = false }
        do {
            let reply = try await OllamaClient.shared.testConnection()
            testOK = true
            testMessage = "Connected. Model replied: \(String(reply.prefix(80)))"
        } catch {
            testOK = false
            testMessage = error.localizedDescription
        }
    }
}
