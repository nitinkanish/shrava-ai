import AVFoundation
import SwiftUI
import Combine
import MurmurCore

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var lastTranscription: String = ""
    @Published var lastError: String? { didSet { if let e = lastError { NSLog("Murmur error: \(e)") } } }
    @Published var recordingDuration: TimeInterval = 0
    
    private var audioRecorder: AudioRecorder?
    private var recordingTimer: Timer?
    
    let dictionary: PersonalDictionary
    let historyManager: HistoryManager
    let snippetManager: SnippetManager
    
    private init() {
        dictionary = PersonalDictionary(storageURL: MurmurCore.dictionaryStorageURL())
        historyManager = HistoryManager(storageURL: MurmurCore.historyStorageURL())
        snippetManager = SnippetManager(storageURL: MurmurCore.snippetsStorageURL())
        
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
            NSLog("Murmur: mic access \(ok)")
            guard ok else { lastError = "Microphone permission not granted"; NSLog("Murmur: mic denied"); return }
        }
        NSLog("Murmur: recording start")
        
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
              let audioData = await recorder.stopRecording() else {
            lastError = "No audio data recorded"
            return
        }
        
        do {
            NSLog("Murmur: transcribing locally with Whisper")
            let result = try await LocalWhisper.shared.transcribe(
                audioData: audioData,
                durationSeconds: recordingDuration,
                language: SettingsManager.shared.settings.language,
                dictionary: dictionary
            )
            
            lastTranscription = result.cleanedText
            
            let entry = HistoryEntry(
                originalText: result.originalText,
                cleanedText: result.cleanedText,
                language: result.language.rawValue,
                durationSeconds: result.durationSeconds,
                appBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            )
            await historyManager.add(entry)
            NSLog("Murmur: saved to history (\(result.cleanedText.count) chars)")
            NotificationCenter.default.post(name: .murmurHistoryUpdated, object: nil)
            
            if SettingsManager.shared.settings.iCloudSyncEnabled {
                let allHistory = await historyManager.getAll()
                CloudSyncManager.shared.syncHistory(allHistory)
            }
            
            await insertText(result.cleanedText)
            
        } catch {
            lastError = "Error: \(error.localizedDescription)"
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
