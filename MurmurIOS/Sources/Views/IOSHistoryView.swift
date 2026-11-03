import SwiftUI
import MurmurCore

struct IOSHistoryView: View {
    @EnvironmentObject var appState: IOSAppState
    @State private var entries: [HistoryEntry] = []
    @State private var searchText = ""
    
    var filteredEntries: [HistoryEntry] {
        if searchText.isEmpty {
            return entries
        }
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
                            IOSHistoryRow(entry: entry)
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
        .task {
            await loadEntries()
        }
        .refreshable {
            await loadEntries()
        }
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
            await appState.historyManager.delete(entry.id)
            await loadEntries()
        }
    }
    
    private func clearAll() {
        Task {
            await appState.historyManager.clear()
            await loadEntries()
        }
    }
}

struct IOSHistoryRow: View {
    let entry: HistoryEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.cleanedText)
                .lineLimit(3)
            
            HStack {
                Text(entry.timestamp, style: .relative)
                Text("•")
                Text(String(format: "%.1fs", entry.durationSeconds))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
