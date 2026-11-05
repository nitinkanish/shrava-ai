import SwiftUI
import AppKit
import AVFoundation
import ShravaCore

final class HistoryWindowController {
    static let shared = HistoryWindowController()
    
    private var window: NSWindow?
    
    private init() {}
    
    func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let contentView = HistoryView()
            .environmentObject(AppState.shared)
        
        let hostingView = NSHostingView(rootView: contentView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.contentView = hostingView
        window.title = "Shrava History"
        window.titlebarAppearsTransparent = true
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 420)
        
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}


extension Notification.Name {
    static let shravaHistoryUpdated = Notification.Name("shravaHistoryUpdated")
}

struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @State private var entries: [HistoryEntry] = []
    @State private var searchText = ""
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        let sorted = entries.sorted { $0.timestamp > $1.timestamp }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            $0.cleanedText.localizedCaseInsensitiveContains(searchText) ||
            $0.originalText.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var groups: [(String, [HistoryEntry])] {
        let cal = Calendar.current
        let fmt = DateFormatter(); fmt.dateFormat = "EEEE, d MMMM"
        var order: [String] = []; var map: [String: [HistoryEntry]] = [:]
        for e in filtered {
            let key = cal.isDateInToday(e.timestamp) ? "Today" : cal.isDateInYesterday(e.timestamp) ? "Yesterday" : fmt.string(from: e.timestamp)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(e)
        }
        return order.map { ($0, map[$0]!) }
    }

    private var totalWords: Int { entries.reduce(0) { $0 + $1.cleanedText.split { $0.isWhitespace }.count } }
    private var totalMinutes: Double { entries.reduce(0) { $0 + $1.durationSeconds } / 60 }
    private var wpm: Int { totalMinutes > 0 ? Int(Double(totalWords) / totalMinutes) : 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(groups, id: \.0) { title, items in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(title.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .tracking(0.8)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 4)
                                VStack(spacing: 0) {
                                    ForEach(Array(items.enumerated()), id: \.element.id) { i, entry in
                                        HistoryCard(entry: entry,
                                                    onDelete: { delete(entry) })
                                        if i < items.count - 1 { Divider().padding(.leading, 86) }
                                    }
                                }
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
                            }
                        }
                    }
                    .padding(24)
                }
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task { await loadEntries() }
        .onReceive(NotificationCenter.default.publisher(for: .shravaHistoryUpdated)) { _ in
            Task { await loadEntries() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await loadEntries() }
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) {
                Task {
                    await BriefStore.shared.clear()
                    await appState.historyManager.clear()
                    await loadEntries()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("History").font(.system(size: 26, weight: .bold))
                Spacer()
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("Clear all", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(entries.isEmpty)
            }
            HStack(spacing: 10) {
                StatPill(value: "\(totalWords)", label: "words dictated", icon: "text.word.spacing")
                StatPill(value: "\(entries.count)", label: "recordings", icon: "waveform")
                StatPill(value: "\(wpm)", label: "words / min", icon: "speedometer")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your transcripts", text: $searchText).textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle").font(.system(size: 52)).foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "No dictations yet" : "No matching transcripts").font(.headline)
            if searchText.isEmpty {
                Text("Hold Fn, or double-tap Fn for hands-free, and start talking.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func delete(_ entry: HistoryEntry) {
        Task {
            await BriefStore.shared.delete(for: entry.id)
            await appState.historyManager.delete(entry.id)
            await loadEntries()
        }
    }

    private func loadEntries() async {
        entries = await appState.historyManager.getAll()
    }
}

struct StatPill: View {
    let value: String; let label: String; let icon: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
    }
}

struct HistoryCard: View {
    let entry: HistoryEntry
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var showOriginal = false
    @State private var copied = false
    @State private var analyzing = false
    @State private var brief: MeetingBrief?
    @State private var showBrief = false
    @State private var analyzeError: String?
    @StateObject private var audioPlayer: RecordingAudioController

    init(entry: HistoryEntry, onDelete: @escaping () -> Void) {
        self.entry = entry
        self.onDelete = onDelete
        _audioPlayer = StateObject(wrappedValue: RecordingAudioController(fileName: entry.audioFileName))
    }

    private var appName: String? {
        guard let id = entry.appBundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.timestamp, format: .dateTime.hour().minute())
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text(String(format: "%.0fs", entry.durationSeconds))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .frame(width: 54, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                if entry.needsTranscriptRegenerateCTA {
                    HStack(spacing: 8) {
                        Image(systemName: entry.transcriptionState == .failed ? "exclamationmark.triangle.fill" : "arrow.clockwise.circle")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.transcriptionState == .failed ? "Transcription failed" : (entry.transcriptionState == .pending ? "Waiting to transcribe" : "Transcript needs refresh"))
                                .font(.system(size: 12, weight: .semibold))
                            if entry.transcriptionState == .failed {
                                Text(entry.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Tap Regenerate to retry from saved audio." : entry.originalText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            } else if entry.transcriptionState == .pending {
                                Text(String(format: "Transcribing… %d%%", Int((entry.transcriptionProgress * 100).rounded())))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Regenerate from the saved audio anytime.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Button("Regenerate transcript") {
                            Task { await AppState.shared.regenerateTranscription(for: entry) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(AppState.shared.isProcessing)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
                }

                Text(entry.cleanedText)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showOriginal && entry.originalText != entry.cleanedText {
                    Text(entry.originalText)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }

                if entry.audioFileName != nil {
                    MacRecordingPlaybackBar(controller: audioPlayer)
                }

                HStack(spacing: 10) {
                    if let appName {
                        Label(appName, systemImage: "app").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text("\(entry.cleanedText.split { $0.isWhitespace }.count) words")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if entry.originalText != entry.cleanedText {
                        Button(showOriginal ? "Hide original" : "Show original") { showOriginal.toggle() }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                    if brief != nil {
                        Button {
                            showBrief = true
                        } label: {
                            Label("Brief", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.link).font(.system(size: 11))
                    }
                }

                if let analyzeError {
                    Text(analyzeError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 4) {
                if entry.audioFileName != nil {
                    Button {
                        Task { await AppState.shared.regenerateTranscription(for: entry) }
                    } label: {
                        if entry.transcriptionState == .pending && AppState.shared.isProcessing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "text.badge.checkmark")
                        }
                    }
                    .help(entry.needsTranscriptRegenerateCTA ? "Regenerate transcript (recommended)" : "Regenerate transcript")
                    .disabled(AppState.shared.isProcessing)
                }

                Button {
                    Task { await analyze(force: brief != nil) }
                } label: {
                    if analyzing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: brief == nil ? "sparkles" : "arrow.clockwise")
                    }
                }
                .help(brief == nil ? "Analyze meeting" : "Re-analyze")
                .disabled(analyzing || entry.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let url = audioPlayer.fileURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: { Image(systemName: "folder") }
                    .help("Show audio in Finder")
                    Button {
                        let picker = NSSharingServicePicker(items: [url])
                        if let view = NSApp.keyWindow?.contentView {
                            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
                        }
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .help("Share / export audio")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.cleanedText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                .help("Copy")
                Button(action: onDelete) { Image(systemName: "trash") }.help("Delete")
            }
            .buttonStyle(.borderless)
            .opacity(hovering || copied || analyzing || brief != nil ? 1 : 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(hovering ? Color.primary.opacity(0.03) : Color.clear)
        .onHover { hovering = $0 }
        .task { brief = await BriefStore.shared.brief(for: entry.id) }
        .sheet(isPresented: $showBrief) {
            MeetingBriefSheet(entry: entry, brief: $brief) {
                showBrief = false
                Task { await analyze(force: true) }
            }
        }
        .contextMenu {
            if entry.audioFileName != nil {
                Button(entry.needsTranscriptRegenerateCTA ? "Regenerate transcript…" : "Regenerate transcript") {
                    Task { await AppState.shared.regenerateTranscription(for: entry) }
                }
                .disabled(AppState.shared.isProcessing)
            }
            Button(brief == nil ? "Analyze meeting" : "View brief") {
                if brief != nil { showBrief = true }
                else { Task { await analyze(force: false) } }
            }
            if brief != nil {
                Button("Re-analyze") { Task { await analyze(force: true) } }
            }
            Button("Copy transcript") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.cleanedText, forType: .string)
            }
            Button("Copy original") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.originalText, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func analyze(force: Bool) async {
        if !force, let existing = await BriefStore.shared.brief(for: entry.id) {
            brief = existing
            showBrief = true
            return
        }
        analyzing = true
        analyzeError = nil
        showBrief = true
        defer { analyzing = false }
        do {
            let result = try await OllamaClient.shared.analyzeMeeting(
                transcript: entry.cleanedText,
                titleHint: "Shrava history entry \(entry.timestamp.formatted())"
            )
            try await BriefStore.shared.save(result, for: entry.id)
            brief = result
            await autoSendToSlackIfNeeded(result)
        } catch {
            analyzeError = error.localizedDescription
            // Keep sheet open only if we already had a brief; otherwise dismiss empty loading sheet
            if brief == nil { showBrief = false }
        }
    }

    private func autoSendToSlackIfNeeded(_ brief: MeetingBrief) async {
        let s = SlackSettingsStore.load()
        guard s.autoSendAfterAnalyze, SlackSecrets.hasToken(), let channel = s.defaultChannelID, !channel.isEmpty else { return }
        let titleWords = entry.cleanedText.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        do {
            _ = try await SlackClient.shared.postMeetingBrief(
                brief: brief,
                channelID: channel,
                channelName: s.defaultChannelName,
                title: titleWords.isEmpty ? brief.meetingType.displayName : titleWords,
                date: entry.timestamp,
                durationSeconds: entry.durationSeconds,
                transcript: entry.cleanedText,
                includeTranscript: s.includeTranscript
            )
        } catch {
            analyzeError = "Slack auto-send failed: \(error.localizedDescription)"
        }
    }
}


struct MacRecordingPlaybackBar: View {
    @ObservedObject var controller: RecordingAudioController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = controller.loadError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red)
            } else {
                HStack(spacing: 10) {
                    Button {
                        controller.toggle()
                    } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(controller.isPlaying ? "Pause" : "Play")

                    Slider(
                        value: Binding(
                            get: { controller.currentTime },
                            set: { controller.seek(to: $0) }
                        ),
                        in: 0...max(controller.duration, 0.1)
                    )
                    .controlSize(.small)

                    Text("\(Self.fmt(controller.currentTime)) / \(Self.fmt(controller.duration))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 88, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 4)
        .onDisappear { controller.pause() }
    }

    private static func fmt(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
