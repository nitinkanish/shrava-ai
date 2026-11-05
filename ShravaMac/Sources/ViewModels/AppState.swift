import AVFoundation
import SwiftUI
import Combine
import ShravaCore

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var lastTranscription: String = ""
    @Published var lastError: String? { didSet { if let e = lastError { NSLog("Shrava error: \(e)") } } }
    @Published var recordingDuration: TimeInterval = 0
    
    private var audioRecorder: AudioRecorder?
    private var recordingTimer: Timer?
    
    let dictionary: PersonalDictionary
    let historyManager: HistoryManager
    let snippetManager: SnippetManager
    
    private init() {
        dictionary = PersonalDictionary(storageURL: ShravaCore.dictionaryStorageURL())
        historyManager = HistoryManager(storageURL: ShravaCore.historyStorageURL())
        snippetManager = SnippetManager(storageURL: ShravaCore.snippetsStorageURL())
        
        setupCloudSync()
    }
    
    private func setupCloudSync() {
        if SettingsManager.shared.settings.iCloudSyncEnabled {
            CloudSyncManager.shared.setEnabled(true)
        }
    }
    
    func startRecording() async {
        guard !isRecording else { return }
        
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            NSLog("Shrava: mic access \(ok)")
            guard ok else { lastError = "Microphone permission not granted"; NSLog("Shrava: mic denied"); return }
        }
        NSLog("Shrava: recording start")
        
        isRecording = true
        recordingDuration = 0
        lastError = nil
        
        NotificationCenter.default.post(
            name: .recordingStateChanged,
            object: nil,
            userInfo: ["isRecording": true]
        )
        
        audioRecorder = AudioRecorder()
        do {
            try await audioRecorder?.startRecording()
            startRecordingTimer()
        } catch {
            isRecording = false
            lastError = "Failed to start recording: \(error.localizedDescription)"
        }
    }
    
    func cancelRecording() async {
        guard isRecording else { return }
        stopRecordingTimer()
        isRecording = false
        await audioRecorder?.cancelRecording()
        audioRecorder = nil
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil, userInfo: ["isRecording": false])
    }

    func stopRecordingAndTranscribe() async {
        guard isRecording else { return }
        
        stopRecordingTimer()
        isRecording = false
        isProcessing = true
        
        NotificationCenter.default.post(
            name: .recordingStateChanged,
            object: nil,
            userInfo: ["isRecording": false]
        )
        
        defer { isProcessing = false }
        
        guard let recorder = audioRecorder,
              let stopped = await recorder.stopRecording() else {
            lastError = "No audio data recorded"
            return
        }
        
        do {
            NSLog("Shrava: transcribing locally with Whisper")
            let result = try await LocalWhisper.shared.transcribe(
                audioData: stopped.data,
                durationSeconds: recordingDuration,
                language: SettingsManager.shared.settings.language,
                dictionary: dictionary,
                existingURL: stopped.url
            )
            
            lastTranscription = result.cleanedText
            
            let entry = HistoryEntry(
                originalText: result.originalText,
                cleanedText: result.cleanedText,
                language: result.language.rawValue,
                durationSeconds: result.durationSeconds,
                appBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                audioFileName: result.audioFileName ?? stopped.url.lastPathComponent
            )
            await historyManager.add(entry)
            NSLog("Shrava: saved to history (\(result.cleanedText.count) chars)")
            NotificationCenter.default.post(name: .shravaHistoryUpdated, object: nil)
            
            if SettingsManager.shared.settings.iCloudSyncEnabled {
                let allHistory = await historyManager.getAll()
                CloudSyncManager.shared.syncHistory(allHistory)
            }
            
            await insertText(result.cleanedText)
            
        } catch {
            lastError = "Error: \(error.localizedDescription)"
        }
    }
    
    /// Re-run Whisper on a History entry's linked audio. Keeps prior transcript until success.
    func regenerateTranscription(for entry: HistoryEntry) async {
        guard let name = entry.audioFileName else {
            lastError = "No audio file linked to this capture"
            return
        }
        let url = LocalWhisper.recordingsDirectory.appendingPathComponent(name)
        let alt = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Shrava/Recordings")
            .appendingPathComponent(name)
        let fileURL: URL
        if FileManager.default.fileExists(atPath: url.path) {
            fileURL = url
        } else if FileManager.default.fileExists(atPath: alt.path) {
            fileURL = alt
        } else {
            lastError = "Audio file missing"
            return
        }
        if isProcessing {
            lastError = "Already transcribing — try again when the current job finishes"
            return
        }

        let previousCleaned = entry.cleanedText
        let previousOriginal = entry.originalText
        let keepPrevious = !entry.isPlaceholderTranscript

        var updating = entry
        updating.transcriptionState = .pending
        updating.transcriptionProgress = 0
        if !keepPrevious {
            updating.cleanedText = "Transcribing… 0%"
        }
        await historyManager.update(updating)
        NotificationCenter.default.post(name: .shravaHistoryUpdated, object: nil)
        isProcessing = true
        defer { isProcessing = false }

        do {
            let result = try await LocalWhisper.shared.transcribeExistingFile(
                url: fileURL,
                durationSeconds: entry.durationSeconds,
                language: SettingsManager.shared.settings.language,
                dictionary: dictionary,
                progress: { [weak self] p in
                    Task { @MainActor in
                        self?.isProcessing = true
                        var mid = entry
                        mid.transcriptionState = .pending
                        mid.transcriptionProgress = p
                        if keepPrevious {
                            mid.cleanedText = previousCleaned
                            mid.originalText = previousOriginal
                        } else {
                            mid.cleanedText = String(format: "Transcribing… %d%%", Int((p * 100).rounded()))
                        }
                        await self?.historyManager.update(mid)
                        if Int((p * 100).rounded()) % 10 == 0 {
                            NotificationCenter.default.post(name: .shravaHistoryUpdated, object: nil)
                        }
                    }
                },
                partialText: { text in
                    if keepPrevious { return }
                    Task { @MainActor in
                        var mid = entry
                        mid.transcriptionState = .pending
                        mid.cleanedText = text
                        mid.originalText = text
                        await AppState.shared.historyManager.update(mid)
                    }
                }
            )
            let done = HistoryEntry(
                id: entry.id,
                originalText: result.originalText,
                cleanedText: result.cleanedText,
                language: result.language.rawValue,
                timestamp: entry.timestamp,
                durationSeconds: entry.durationSeconds,
                appBundleIdentifier: entry.appBundleIdentifier,
                transcriptionState: .complete,
                audioFileName: name,
                transcriptionProgress: 1
            )
            await historyManager.update(done)
            lastTranscription = result.cleanedText
            NotificationCenter.default.post(name: .shravaHistoryUpdated, object: nil)
            NSLog("Shrava: regenerate ok id=%@ chars=%d", entry.id.uuidString, result.cleanedText.count)
        } catch {
            if keepPrevious {
                var restored = entry
                restored.cleanedText = previousCleaned
                restored.originalText = previousOriginal
                restored.transcriptionState = .complete
                restored.transcriptionProgress = 1
                await historyManager.update(restored)
                lastError = "Regenerate failed — previous transcript kept. (\(error.localizedDescription))"
            } else {
                var failed = entry
                failed.transcriptionState = .failed
                failed.cleanedText = "Transcription failed — \(error.localizedDescription)"
                failed.originalText = error.localizedDescription
                await historyManager.update(failed)
                lastError = "Error: \(error.localizedDescription)"
            }
            NotificationCenter.default.post(name: .shravaHistoryUpdated, object: nil)
        }
    }

    private func insertText(_ text: String) async {
        if SettingsManager.shared.settings.useAccessibilityInsertion {
            let success = TextInserter.insertViaAccessibility(text)
            if !success {
                TextInserter.insertViaPasteboard(text)
            }
        } else {
            TextInserter.insertViaPasteboard(text)
        }
    }
    
    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordingDuration += 0.1
            }
        }
    }
    
    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
}
