import SwiftUI
import ShravaCore

struct IOSDictionaryView: View {
    @EnvironmentObject var appState: IOSAppState
    @State private var entries: [DictionaryEntry] = []
    @State private var showingAddSheet = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                ShravaTheme.softBackground.opacity(0.35).ignoresSafeArea()
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(entries) { entry in
                            IOSDictionaryRow(
                                entry: entry,
                                onToggle: { toggleEntry(entry) }
                            )
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteEntry(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            }
            .navigationTitle("Dictionary")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showingAddSheet = true }) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.glass)
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddDictionaryEntrySheet(isPresented: $showingAddSheet, onAdd: { spoken, written in
                    addEntry(spoken: spoken, written: written)
                })
            }
        }
        .task {
            await loadEntries()
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 56))
                .foregroundStyle(ShravaTheme.purple)
                .padding(28)
                .shravaGlass(in: Circle())

            Text("No Dictionary Entries")
                .font(.title2.weight(.semibold))

            Text("Add words that should be transcribed\ndifferently, like names or technical terms.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Add Entry") {
                showingAddSheet = true
            }
            .buttonStyle(.glassProminent)
            .tint(ShravaTheme.purple)
        }
    }
    
    private func loadEntries() async {
        entries = await appState.dictionary.getAll()
    }
    
    private func addEntry(spoken: String, written: String) {
        let entry = DictionaryEntry(spoken: spoken, written: written)
        Task {
            await appState.dictionary.add(entry)
            await loadEntries()
            syncIfNeeded()
        }
    }
    
    private func toggleEntry(_ entry: DictionaryEntry) {
        Task {
            await appState.dictionary.update(entry.toggled())
            await loadEntries()
            syncIfNeeded()
        }
    }
    
    private func deleteEntry(_ entry: DictionaryEntry) {
        Task {
            await appState.dictionary.delete(entry.id)
            await loadEntries()
            syncIfNeeded()
        }
    }
    
    private func syncIfNeeded() {
        if SettingsManager.shared.settings.iCloudSyncEnabled {
            CloudSyncManager.shared.syncDictionary(entries)
        }
    }
}

struct IOSDictionaryRow: View {
    let entry: DictionaryEntry
    let onToggle: () -> Void
    
    var body: some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.spoken)
                        .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.written)
                        .fontWeight(.medium)
                        .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                }
            }
        }
    }
}

struct AddDictionaryEntrySheet: View {
    @Binding var isPresented: Bool
    let onAdd: (String, String) -> Void
    
    @State private var spoken = ""
    @State private var written = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("How you say it", text: $spoken)
                        .autocorrectionDisabled()
                } header: {
                    Text("Spoken")
                }
                
                Section {
                    TextField("How to write it", text: $written)
                        .autocorrectionDisabled()
                } header: {
                    Text("Written")
                }
                
                Section {
                    Text("Example: \"john doe\" → \"John Doe\"")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(spoken, written)
                        isPresented = false
                    }
                    .disabled(spoken.isEmpty || written.isEmpty)
                }
            }
        }
    }
}
