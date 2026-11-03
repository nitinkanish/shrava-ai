import SwiftUI
import UniformTypeIdentifiers
import ShravaCore

struct IOSHistoryView: View {
    @EnvironmentObject var appState: IOSAppState
    @State private var entries: [HistoryEntry] = []
    @State private var searchText = ""

    var filteredEntries: [HistoryEntry] {
        if searchText.isEmpty { return entries }
        return entries.filter { entry in
            entry.cleanedText.localizedCaseInsensitiveContains(searchText) ||
            entry.originalText.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(filteredEntries) { entry in
                            NavigationLink {
                                IOSHistoryDetailView(entry: entry)
                            } label: {
                                IOSHistoryRow(entry: entry)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteEntry(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    UIPasteboard.general.string = entry.cleanedText
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search history")
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !entries.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button(role: .destructive) {
                                clearAll()
                            } label: {
                                Label("Clear All", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .task { await loadEntries() }
        .refreshable { await loadEntries() }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No History Yet")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Your dictation history will appear here.")
                .foregroundStyle(.secondary)
        }
    }

    private func loadEntries() async {
        entries = await appState.historyManager.getAll()
    }

    private func deleteEntry(_ entry: HistoryEntry) {
        Task {
            await BriefStore.shared.delete(for: entry.id)
            await appState.historyManager.delete(entry.id)
            await loadEntries()
        }
    }

    private func clearAll() {
        Task {
            await BriefStore.shared.clear()
            await appState.historyManager.clear()
            await loadEntries()
        }
    }
}

struct IOSHistoryRow: View {
    let entry: HistoryEntry
    @State private var hasBrief = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.cleanedText)
                .lineLimit(3)
            HStack {
                Text(entry.timestamp, style: .relative)
                Text("•")
                Text(String(format: "%.1fs", entry.durationSeconds))
                if hasBrief {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .task { hasBrief = await BriefStore.shared.brief(for: entry.id) != nil }
    }
}

struct IOSHistoryDetailView: View {
    let entry: HistoryEntry
    @State private var brief: MeetingBrief?
    @State private var analyzing = false
    @State private var errorText: String?
    @State private var showBrief = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.cleanedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(entry.timestamp, style: .date)
                    Text(entry.timestamp, style: .time)
                    Spacer()
                    Text(String(format: "%.0fs", entry.durationSeconds))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }

                Button {
                    Task { await analyze(force: brief != nil) }
                } label: {
                    HStack {
                        if analyzing { ProgressView() }
                        else { Image(systemName: "sparkles") }
                        Text(brief == nil ? "Analyze meeting" : "Re-analyze")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(analyzing || entry.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if brief != nil {
                    Button("View Meeting Brief") { showBrief = true }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .task { brief = await BriefStore.shared.brief(for: entry.id) }
        .sheet(isPresented: $showBrief) {
            NavigationStack {
                Group {
                    if let brief {
                        IOSMeetingBriefView(brief: brief) { updated in
                            self.brief = updated
                            Task { try? await BriefStore.shared.save(updated, for: entry.id) }
                        }
                    } else {
                        ProgressView("Analyzing…")
                    }
                }
                .navigationTitle("Meeting Brief")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showBrief = false }
                    }
                    if let brief {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button {
                                UIPasteboard.general.string = brief.asMarkdown()
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            ShareLink(
                                item: BriefMarkdownFile(
                                    markdown: brief.asMarkdown(),
                                    filename: markdownFilename
                                ),
                                preview: SharePreview("Meeting Brief", image: Image(systemName: "doc.richtext"))
                            ) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Button {
                                showBrief = false
                                Task { await analyze(force: true) }
                            } label: {
                                Label("Re-analyze", systemImage: "arrow.clockwise")
                            }
                            .disabled(analyzing)
                        }
                    }
                }
            }
        }
    }

    private var markdownFilename: String {
        let day = entry.timestamp.formatted(.iso8601.year().month().day())
        return "Meeting-Brief-\(day).md"
    }

    private func analyze(force: Bool) async {
        if !force, let existing = await BriefStore.shared.brief(for: entry.id) {
            brief = existing
            showBrief = true
            return
        }
        analyzing = true
        errorText = nil
        showBrief = true
        defer { analyzing = false }
        do {
            let result = try await OllamaClient.shared.analyzeMeeting(transcript: entry.cleanedText)
            try await BriefStore.shared.save(result, for: entry.id)
            brief = result
        } catch {
            errorText = error.localizedDescription
            if brief == nil { showBrief = false }
        }
    }
}

struct IOSMeetingBriefView: View {
    @State var brief: MeetingBrief
    var onChange: (MeetingBrief) -> Void

    var body: some View {
        List {
            Section {
                Text(brief.meetingType.displayName)
                    .font(.headline)
                Text(brief.summary)
            } header: { Text("Summary") }

            if !brief.keyPoints.isEmpty {
                Section("Key points") {
                    ForEach(brief.keyPoints, id: \.self) { Text($0) }
                }
            }
            if !brief.decisions.isEmpty {
                Section("Decisions") {
                    ForEach(brief.decisions, id: \.self) { Text($0) }
                }
            }
            if !brief.ideas.isEmpty {
                Section("Ideas") {
                    ForEach(brief.ideas, id: \.self) { Text($0) }
                }
            }
            if !brief.openQuestions.isEmpty {
                Section("Open questions / risks") {
                    ForEach(brief.openQuestions, id: \.self) { Text($0) }
                }
            }
            if !brief.actionItems.isEmpty {
                Section("Action items") {
                    ForEach($brief.actionItems) { $item in
                        Toggle(isOn: $item.done) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.task)
                                HStack(spacing: 8) {
                                    if let o = item.owner, !o.isEmpty { Text("@\(o)").font(.caption).foregroundStyle(.secondary) }
                                    if let d = item.dueDate, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                                    if let p = item.priority, !p.isEmpty { Text(p).font(.caption2).foregroundStyle(.orange) }
                                }
                            }
                        }
                        .onChange(of: item.done) { _, _ in onChange(brief) }
                    }
                }
            }
        }
    }
}


/// Temporary .md file for ShareLink export.
private struct BriefMarkdownFile: Transferable {
    let markdown: String
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { value in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(value.filename)
            try value.markdown.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
