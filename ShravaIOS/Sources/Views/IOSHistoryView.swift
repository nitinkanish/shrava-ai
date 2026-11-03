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
            ZStack {
                ShravaTheme.softBackground.opacity(0.55).ignoresSafeArea()
                Group {
                    if entries.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredEntries) { entry in
                                    NavigationLink {
                                        IOSHistoryDetailView(entry: entry)
                                    } label: {
                                        IOSHistoryRow(entry: entry)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button {
                                            UIPasteboard.general.string = entry.cleanedText
                                        } label: {
                                            Label("Copy", systemImage: "doc.on.doc")
                                        }
                                        Button(role: .destructive) {
                                            deleteEntry(entry)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .searchable(text: $searchText, prompt: "Search captures")
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(role: .destructive) { clearAll() } label: {
                                Label("Clear All", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
        }
        .task { await loadEntries() }
        .refreshable { await loadEntries() }
        .onChange(of: appState.showingResult) { _, _ in
            Task { await loadEntries() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 56))
                .foregroundStyle(ShravaTheme.purple)
                .padding(28)
                .shravaGlass(in: Circle())
            Text("No captures yet")
                .font(.title2.weight(.semibold))
            Text("Your on-device transcripts will appear here as glass cards.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(ShravaTheme.title(from: entry.cleanedText))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if hasBrief {
                    Label("Brief", systemImage: "sparkles")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .shravaGlass(.regular.tint(ShravaTheme.magenta.opacity(0.35)), in: Capsule())
                }
            }
            Text(entry.cleanedText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 10) {
                Label(entry.timestamp.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                Label(String(format: "%.0fs", entry.durationSeconds), systemImage: "timer")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shravaGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task { hasBrief = await BriefStore.shared.brief(for: entry.id) != nil }
    }
}

struct IOSHistoryDetailView: View {
    let entry: HistoryEntry
    @State private var brief: MeetingBrief?
    @State private var analyzing = false
    @State private var errorText: String?
    @State private var showBrief = false
    @State private var showSlackSend = false

    var body: some View {
        ZStack {
            ShravaTheme.softBackground.opacity(0.4).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(ShravaTheme.title(from: entry.cleanedText, limit: 80))
                            .font(.title2.weight(.bold))
                        HStack {
                            Text(entry.timestamp, style: .date)
                            Text(entry.timestamp, style: .time)
                            Spacer()
                            Text(String(format: "%.0fs", entry.durationSeconds))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shravaGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Transcript")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(entry.cleanedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(18)
                    .shravaGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(ShravaTheme.coral)
                            .padding(.horizontal, 4)
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
                    .buttonStyle(.glassProminent)
                    .tint(ShravaTheme.purple)
                    .disabled(analyzing || entry.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if brief != nil {
                        Button("View Meeting Brief") { showBrief = true }
                            .buttonStyle(.glass)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Capture")
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
                            .buttonStyle(.glass)
                    }
                    if let brief {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button {
                                showSlackSend = true
                            } label: {
                                Label("Slack", systemImage: "paperplane")
                            }
                            .buttonStyle(.glass)
                            Button {
                                UIPasteboard.general.string = brief.asMarkdown()
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.glass)
                            ShareLink(
                                item: BriefMarkdownFile(
                                    markdown: brief.asMarkdown(),
                                    filename: markdownFilename
                                ),
                                preview: SharePreview("Meeting Brief", image: Image(systemName: "doc.richtext"))
                            ) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.glass)
                            Button {
                                showBrief = false
                                Task { await analyze(force: true) }
                            } label: {
                                Label("Re-analyze", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.glass)
                            .disabled(analyzing)
                        }
                    }
                }
            }
            .presentationDetents([.large, .medium])
            .sheet(isPresented: $showSlackSend) {
                if let brief {
                    IOSSendBriefToSlackSheet(
                        brief: brief,
                        entry: entry,
                        title: ShravaTheme.title(from: entry.cleanedText, limit: 80)
                    )
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
            await autoSendToSlackIfNeeded(result)
        } catch {
            errorText = error.localizedDescription
            if brief == nil { showBrief = false }
        }
    }


    private func autoSendToSlackIfNeeded(_ brief: MeetingBrief) async {
        let s = SlackSettingsStore.load()
        guard s.autoSendAfterAnalyze, SlackSecrets.hasToken(), let channel = s.defaultChannelID, !channel.isEmpty else { return }
        do {
            _ = try await SlackClient.shared.postMeetingBrief(
                brief: brief,
                channelID: channel,
                channelName: s.defaultChannelName,
                title: ShravaTheme.title(from: entry.cleanedText, limit: 80),
                date: entry.timestamp,
                durationSeconds: entry.durationSeconds,
                transcript: entry.cleanedText,
                includeTranscript: s.includeTranscript
            )
        } catch {
            errorText = "Slack auto-send failed: \(error.localizedDescription)"
        }
    }
}

struct IOSMeetingBriefView: View {
    @State var brief: MeetingBrief
    var onChange: (MeetingBrief) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                glassSection(title: "Summary") {
                    Text(brief.meetingType.displayName)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .shravaGlass(.regular.tint(ShravaTheme.purple.opacity(0.35)), in: Capsule())
                    Text(brief.summary)
                        .font(.body)
                }

                if !brief.keyPoints.isEmpty {
                    glassSection(title: "Key points") {
                        ForEach(brief.keyPoints, id: \.self) { bullet($0) }
                    }
                }
                if !brief.decisions.isEmpty {
                    glassSection(title: "Decisions") {
                        ForEach(brief.decisions, id: \.self) { bullet($0) }
                    }
                }
                if !brief.ideas.isEmpty {
                    glassSection(title: "Ideas") {
                        ForEach(brief.ideas, id: \.self) { bullet($0) }
                    }
                }
                if !brief.openQuestions.isEmpty {
                    glassSection(title: "Open questions / risks") {
                        ForEach(brief.openQuestions, id: \.self) { bullet($0) }
                    }
                }
                if !brief.actionItems.isEmpty {
                    glassSection(title: "Action items") {
                        ForEach($brief.actionItems) { $item in
                            Toggle(isOn: $item.done) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.task)
                                    HStack(spacing: 8) {
                                        if let o = item.owner, !o.isEmpty {
                                            Text("@\(o)").font(.caption).foregroundStyle(.secondary)
                                        }
                                        if let d = item.dueDate, !d.isEmpty {
                                            Text(d).font(.caption).foregroundStyle(.secondary)
                                        }
                                        if let p = item.priority, !p.isEmpty {
                                            Text(p).font(.caption2).foregroundStyle(ShravaTheme.coral)
                                        }
                                    }
                                }
                            }
                            .onChange(of: item.done) { _, _ in onChange(brief) }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(ShravaTheme.softBackground.opacity(0.35).ignoresSafeArea())
    }

    @ViewBuilder
    private func glassSection(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shravaGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(ShravaTheme.purple)
            Text(text)
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
