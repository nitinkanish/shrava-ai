import SwiftUI
import AppKit
import MurmurCore

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
    static let murmurHistoryUpdated = Notification.Name("murmurHistoryUpdated")
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
        .onReceive(NotificationCenter.default.publisher(for: .murmurHistoryUpdated)) { _ in
            Task { await loadEntries() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await loadEntries() }
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) {
                Task { await appState.historyManager.clear(); await loadEntries() }
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
        Task { await appState.historyManager.delete(entry.id); await loadEntries() }
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
                }
            }

            HStack(spacing: 4) {
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
            .opacity(hovering || copied ? 1 : 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(hovering ? Color.primary.opacity(0.03) : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu {
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
}
