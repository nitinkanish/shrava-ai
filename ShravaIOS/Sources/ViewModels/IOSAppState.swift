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
    /// Live mic level 0...1 while recording.
    @Published var audioLevel: Float = 0
    /// Rolling waveform bars (0...1) for the record UI.
    @Published var waveformSamples: [Float] = Array(repeating: 0.08, count: 32)

    enum Tab: Hashable {
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
        audioLevel = 0
        waveformSamples = Array(repeating: 0.08, count: 32)

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
        audioLevel = 0

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
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordingDuration += 0.08
                let level = self.audioRecorder?.normalizedLevel ?? 0
                self.audioLevel = level
                var samples = self.waveformSamples
                samples.removeFirst()
                samples.append(max(0.06, min(1, level)))
                self.waveformSamples = samples
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
    /// Debug/screenshot helper: `defaults write com.shrava.ios screenshotTab history`
    func applyScreenshotTabIfNeeded() {
        guard let raw = UserDefaults.standard.string(forKey: "screenshotTab") else { return }
        UserDefaults.standard.removeObject(forKey: "screenshotTab")
        switch raw.lowercased() {
        case "record": currentTab = .record
        case "history": currentTab = .history
        case "dictionary": currentTab = .dictionary
        case "settings": currentTab = .settings
        default: break
        }
    }

}
