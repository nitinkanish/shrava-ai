import SwiftUI
import AppKit
import ShravaCore

final class DictionaryWindowController {
    static let shared = DictionaryWindowController()
    
    private var window: NSWindow?
    
    private init() {}
    
    func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let contentView = DictionaryView()
            .environmentObject(AppState.shared)
        
        let hostingView = NSHostingView(rootView: contentView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.contentView = hostingView
        window.title = "Personal Dictionary"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)
        
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct DictionaryView: View {
    @EnvironmentObject var appState: AppState
    @State private var entries: [DictionaryEntry] = []
    @State private var newSpoken = ""
    @State private var newWritten = ""
    @State private var showingAddForm = false
    
    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty && !showingAddForm {
                VStack(spacing: 12) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No dictionary entries yet")
                        .foregroundStyle(.secondary)
                    Text("Add words that should be transcribed differently,\nlike names or technical terms.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Add First Entry") {
                        showingAddForm = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if showingAddForm {
                    addEntryForm
                    Divider()
                }
                
                List {
                    ForEach(entries) { entry in
                        DictionaryRow(entry: entry, onToggle: {
                            Task {
                                await appState.dictionary.update(entry.toggled())
                                await loadEntries()
                                syncIfNeeded()
                            }
                        }, onDelete: {
                            Task {
                                await appState.dictionary.delete(entry.id)
                                await loadEntries()
                                syncIfNeeded()
                            }
                        })
                    }
                }
            }
            
            Divider()
            
            HStack {
                Text("\(entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                if !showingAddForm && !entries.isEmpty {
                    Button(action: { showingAddForm = true }) {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .padding(10)
        }
        .task {
            await loadEntries()
        }
    }
    
    private var addEntryForm: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Add Dictionary Entry")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    showingAddForm = false
                    newSpoken = ""
                    newWritten = ""
                }
                .buttonStyle(.plain)
            }
            
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spoken")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("How you say it", text: $newSpoken)
                        .textFieldStyle(.roundedBorder)
                }
                
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Written")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("How to write it", text: $newWritten)
                        .textFieldStyle(.roundedBorder)
                }
            }
            
            HStack {
                Spacer()
                Button("Add") {
                    guard !newSpoken.isEmpty && !newWritten.isEmpty else { return }
                    
                    let entry = DictionaryEntry(spoken: newSpoken, written: newWritten)
                    Task {
                        await appState.dictionary.add(entry)
                        await loadEntries()
                        syncIfNeeded()
                        newSpoken = ""
                        newWritten = ""
                        showingAddForm = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newSpoken.isEmpty || newWritten.isEmpty)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func loadEntries() async {
        entries = await appState.dictionary.getAll()
    }
    
    private func syncIfNeeded() {
        if SettingsManager.shared.settings.iCloudSyncEnabled {
            CloudSyncManager.shared.syncDictionary(entries)
        }
    }
}

struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onToggle: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            
            VStack(alignment: .leading, spacing: 2) {
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
            
            Spacer()
            
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}
