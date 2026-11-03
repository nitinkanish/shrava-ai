import SwiftUI
import AVFoundation
import MurmurCore

@MainActor
final class IOSAppState: ObservableObject {
    static let shared = IOSAppState()
    
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var lastTranscription: String = ""
    @Published var lastError: String?
    @Published var recordingDuration: TimeInterval = 0
    @Published var showingResult = false
    @Published var launchedFromKeyboard = false
    @Published var currentTab: Tab = .record
    
    enum Tab {
        case record
        case history
        case dictionary
        case settings
    }
    
    private var audioRecorder: IOSAudioRecorder?
    private var transcriptionService: TranscriptionService?
    private var recordingTimer: Timer?
    
    let dictionary: PersonalDictionary
    let historyManager: HistoryManager
    
    private init() {
        dictionary = PersonalDictionary(storageURL: MurmurCore.dictionaryStorageURL())
        historyManager = HistoryManager(storageURL: MurmurCore.historyStorageURL())
        
        setupTranscriptionService()
        setupCloudSync()
        setupAudioSession()
    }
    
    private func setupTranscriptionService() {
        guard let apiKey = try? KeychainManager.shared.loadOpenAIAPIKey() else {
            return
        }
        
        let client = OpenAIClient(apiKey: apiKey)
        transcriptionService = TranscriptionService(
            client: client,
            dictionary: dictionary
        )
    }
    
    private func setupCloudSync() {
        if SettingsManager.shared.settings.iCloudSyncEnabled {
            CloudSyncManager.shared.setEnabled(true)
        }
    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    func refreshAPIKey() {
        setupTranscriptionService()
    }
    
    func startRecordingFromKeyboard() {
        launchedFromKeyboard = true
        currentTab = .record
        Task {
            await startRecording()
        }
    }
    
    func checkForPendingTranscription() {
        // Check if keyboard is waiting for transcription
    }
    
    func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
    
    var hasMicrophonePermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }
    
    func startRecording() async {
        guard !isRecording else { return }
        
        guard hasMicrophonePermission else {
            let granted = await requestMicrophonePermission()
            if !granted {
                lastError = "Microphone permission not granted"
                return
            }
        }
        
        isRecording = true
        recordingDuration = 0
        lastError = nil
        showingResult = false
        
        audioRecorder = IOSAudioRecorder()
        do {
            try await audioRecorder?.startRecording()
            startRecordingTimer()
            
            if SettingsManager.shared.settings.hapticFeedback {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
            }
        } catch {
            isRecording = false
            lastError = "Failed to start recording: \(error.localizedDescription)"
        }
    }
    
    func stopRecordingAndTranscribe() async {
        guard isRecording else { return }
        
        stopRecordingTimer()
        isRecording = false
        isProcessing = true
        
        if SettingsManager.shared.settings.hapticFeedback {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
        
        defer { isProcessing = false }
        
        guard let recorder = audioRecorder,
              let audioData = await recorder.stopRecording() else {
            lastError = "No audio data recorded"
            return
        }
        
        guard let service = transcriptionService else {
            lastError = "Please set your OpenAI API key in Settings"
            return
        }
        
        do {
            let result = try await service.transcribeAndCleanup(
                audioData: audioData,
                durationSeconds: recordingDuration
            )
            
            lastTranscription = result.cleanedText
            showingResult = true
            
            let entry = HistoryEntry(
                originalText: result.originalText,
                cleanedText: result.cleanedText,
                language: result.language.rawValue,
                durationSeconds: result.durationSeconds
            )
            await historyManager.add(entry)
            
            if SettingsManager.shared.settings.iCloudSyncEnabled {
                let allHistory = await historyManager.getAll()
                CloudSyncManager.shared.syncHistory(allHistory)
            }
            
            if launchedFromKeyboard {
                writeTranscriptionToAppGroup(result.cleanedText)
            }
            
            if SettingsManager.shared.settings.hapticFeedback {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
            }
            
        } catch let error as OpenAIError {
            switch error {
            case .unauthorized:
                lastError = "Invalid API key. Please check your OpenAI API key in Settings."
            case .rateLimited:
                lastError = "Rate limited. Please try again in a moment."
            case .transcriptionFailed(let message):
                lastError = "Transcription failed: \(message)"
            case .cleanupFailed(let message):
                lastError = "Cleanup failed: \(message)"
            default:
                lastError = "Error: \(error)"
            }
            
            if SettingsManager.shared.settings.hapticFeedback {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
            }
        } catch {
            lastError = "Error: \(error.localizedDescription)"
        }
    }
    
    func cancelRecording() async {
        guard isRecording else { return }
        
        stopRecordingTimer()
        isRecording = false
        await audioRecorder?.cancelRecording()
        launchedFromKeyboard = false
    }
    
    private func writeTranscriptionToAppGroup(_ text: String) {
        guard let url = MurmurCore.sharedTranscriptionURL() else { return }
        
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to write transcription to App Group: \(error)")
        }
    }
    
    func copyToClipboard() {
        UIPasteboard.general.string = lastTranscription
        
        if SettingsManager.shared.settings.hapticFeedback {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
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
