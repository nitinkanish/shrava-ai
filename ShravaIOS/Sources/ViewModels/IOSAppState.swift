import SwiftUI
import AVFoundation
import ShravaCore

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
    @Published var modelReady = false

    enum Tab {
        case record
        case history
        case dictionary
        case settings
    }

    private var audioRecorder: IOSAudioRecorder?
    private var recordingTimer: Timer?

    let dictionary: PersonalDictionary
    let historyManager: HistoryManager
    let modelManager = WhisperModelManager.shared

    private init() {
        dictionary = PersonalDictionary(storageURL: ShravaCore.dictionaryStorageURL())
        historyManager = HistoryManager(storageURL: ShravaCore.historyStorageURL())

        modelReady = modelManager.isReady
        setupCloudSync()
        setupAudioSession()
    }

    private func setupCloudSync() {
        if SettingsManager.shared.settings.iCloudSyncEnabled {
            CloudSyncManager.shared.setEnabled(true)
        }
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }

    func refreshModelStatus() {
        modelManager.refreshStatus()
        modelReady = modelManager.isReady
    }

    func startRecordingFromKeyboard() {
        launchedFromKeyboard = true
        currentTab = .record
        Task {
            await startRecording()
        }
    }

    func checkForPendingTranscription() {
        // Keyboard reads shared_transcription.txt when returning to the host app.
    }

    func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    var hasMicrophonePermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    func startRecording() async {
        guard !isRecording else { return }

        if !hasMicrophonePermission {
            let granted = await requestMicrophonePermission()
            if !granted {
                lastError = "Microphone permission not granted"
                return
            }
        }

        refreshModelStatus()
        guard modelReady else {
            lastError = "Download the on-device Whisper model in Settings or Onboarding first."
            return
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
              let audioData = recorder.stopRecording() else {
            lastError = "No audio data recorded"
            return
        }

        do {
            let result = try await IOSWhisper.shared.transcribe(
                audioData: audioData,
                durationSeconds: recordingDuration,
                language: SettingsManager.shared.settings.language,
                dictionary: dictionary
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

        } catch {
            lastError = "Error: \(error.localizedDescription)"

            if SettingsManager.shared.settings.hapticFeedback {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
            }
        }
    }

    func cancelRecording() async {
        guard isRecording else { return }

        stopRecordingTimer()
        isRecording = false
        audioRecorder?.cancelRecording()
        launchedFromKeyboard = false
    }

    private func writeTranscriptionToAppGroup(_ text: String) {
        guard let url = ShravaCore.sharedTranscriptionURL() else { return }

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
