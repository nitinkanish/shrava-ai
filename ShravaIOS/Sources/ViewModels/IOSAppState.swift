import SwiftUI
import AVFoundation
import ActivityKit
import WidgetKit
import CallKit
import OSLog
import ShravaCore

@MainActor
final class IOSAppState: ObservableObject, IOSAudioRecorderDelegate {
    static let shared = IOSAppState()
    private static let log = Logger(subsystem: "com.shrava.ios", category: "appstate")

    @Published var isRecording = false
    @Published var isLongRecording = false
    @Published var isPaused = false
    @Published var isProcessing = false
    @Published var transcriptionProgress: Double = 0
    @Published var lastTranscription: String = ""
    @Published var lastError: String?
    @Published var recordingDuration: TimeInterval = 0
    @Published var showingResult = false
    @Published var launchedFromKeyboard = false
    @Published var currentTab: Tab = .record
    @Published var modelReady = false
    @Published var audioLevel: Float = 0
    @Published var waveformSamples: [Float] = Array(repeating: 0.08, count: 32)

    enum Tab: Hashable {
        case record
        case history
        case dictionary
        case settings
    }

    private var audioRecorder: IOSAudioRecorder?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    private var pauseStartedAt: Date?
    private var accumulatedPause: TimeInterval = 0
    private var liveActivity: Activity<RecordingActivityAttributes>?
    private var stopObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Start was requested while a phone call was active — auto-start when it ends.
    private var pendingStartAfterCall = false
    private var pendingStartTitle = "Meeting"
    private var pendingStartFromIntent = false
    /// Gap markers to inject into the transcript (phone-call pauses, etc.).
    private var transcriptGapMarkers: [String] = []

    let dictionary: PersonalDictionary
    let historyManager: HistoryManager
    let modelManager = WhisperModelManager.shared

    private init() {
        dictionary = PersonalDictionary(storageURL: ShravaCore.dictionaryStorageURL())
        historyManager = HistoryManager(storageURL: ShravaCore.historyStorageURL())

        modelReady = modelManager.isReady
        setupCloudSync()
        setupAudioSession()
        observeStopIntent()
        setupCallMonitor()
        observeLifecycleForResume()
    }

    private func setupCloudSync() {
        if SettingsManager.shared.settings.iCloudSyncEnabled {
            CloudSyncManager.shared.setEnabled(true)
        }
    }

    private func setupAudioSession() {
        // Category only — do not activate until we actually record (avoids fighting CallKit).
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
            )
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }

    private func setupCallMonitor() {
        PhoneCallMonitor.shared.onCallsChanged = { [weak self] hasCall in
            Task { @MainActor in
                self?.handlePhoneCallStateChange(hasActiveCall: hasCall)
            }
        }
    }

    private func observeLifecycleForResume() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.retryResumeAfterLifecycle()
                }
            }
            lifecycleObservers.append(token)
        }
    }

    private func handlePhoneCallStateChange(hasActiveCall: Bool) {
        if hasActiveCall {
            guard isRecording, isLongRecording, !isPaused else { return }
            audioRecorder?.pause(reason: .phoneCall)
            return
        }
        // Call ended.
        if pendingStartAfterCall {
            let title = pendingStartTitle
            let fromIntent = pendingStartFromIntent
            pendingStartAfterCall = false
            lastError = nil
            Task {
                if fromIntent {
                    await startLongRecordingFromIntent(title: title)
                } else {
                    await startLongRecording(title: title)
                }
            }
            return
        }
        if isRecording, isLongRecording, isPaused {
            audioRecorder?.resumeWithRetry(trigger: "callEnded")
        }
    }

    private func retryResumeAfterLifecycle() {
        guard isRecording, isLongRecording, audioRecorder != nil else { return }
        if PhoneCallMonitor.shared.hasActiveCall { return }
        // Only when we know we're paused/interrupted — avoid racing a cold start
        // (which previously could call resume → startNewSegmentContinuing and break recording).
        let recorderPaused = audioRecorder?.isPausedRecording == true
            || audioRecorder?.currentPauseReason != nil
        guard isPaused || recorderPaused else { return }
        Self.log.info("lifecycle resume attempt isPaused=\(self.isPaused) reason=\(String(describing: self.audioRecorder?.currentPauseReason), privacy: .public)")
        print("SHRAVA lifecycle resume attempt isPaused=\(isPaused)")
        audioRecorder?.resumeWithRetry(trigger: "lifecycle")
    }

    private func observeStopIntent() {
        stopObserver = NotificationCenter.default.addObserver(
            forName: .shravaRecordingIntent,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?["action"] as? String ?? ""
            Task { @MainActor in
                await self?.handleRecordingIntent(raw)
            }
        }
        // Cold-start: intent may have posted before we registered — drain pending Live Activities sync.
        reloadRecordingControl()
    }

    private func handleRecordingIntent(_ raw: String) async {
        switch raw {
        case RecordingIntentAction.start.rawValue:
            await startLongRecordingFromIntent()
        case RecordingIntentAction.stop.rawValue:
            await stopLongRecordingFromIntent()
        case RecordingIntentAction.toggle.rawValue:
            if isRecording && isLongRecording {
                await stopLongRecordingFromIntent()
            } else {
                await startLongRecordingFromIntent()
            }
        default:
            RecordingIntentBridge.settle(reason: "unknown")
        }
    }

    /// Intent/Control path: Live Activity first, then recorder, then settle (keeps AudioRecordingIntent grant open).
    func startLongRecordingFromIntent(title: String = "Meeting") async {
        if isRecording && isLongRecording {
            RecordingIntentBridge.settle(reason: "ok")
            return
        }
        guard !isRecording else {
            RecordingIntentBridge.settle(reason: "busy")
            return
        }

        // Live Activities must be enabled — required by AudioRecordingIntent.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            RecordingIntentBridge.settle(reason: "liveActivity")
            return
        }

        if !hasMicrophonePermission {
            // Can't prompt from background.
            RecordingIntentBridge.settle(reason: "permission")
            return
        }
        refreshModelStatus()
        guard modelReady else {
            RecordingIntentBridge.settle(reason: "model")
            return
        }

        Self.log.info("startLongRecordingFromIntent callActive=\(self.isInPhoneCall) modelReady=\(self.modelReady)")
        if isInPhoneCall {
            pendingStartAfterCall = true
            pendingStartTitle = title
            pendingStartFromIntent = true
            lastError = RecordingError.callInProgress.errorDescription
            RecordingIntentBridge.settle(reason: "failed")
            return
        }

        beginLongRecordingSession(title: title)

        // 1) Live Activity FIRST (AudioRecordingIntent contract).
        let laOK = await startLiveActivity(title: title)
        guard laOK else {
            isRecording = false
            isLongRecording = false
            RecordingIntentBridge.settle(reason: "liveActivity")
            return
        }

        // 2) Start recorder while intent perform() is still waiting.
        let recorder = IOSAudioRecorder()
        attachRecorderDelegate(recorder)
        audioRecorder = recorder
        do {
            try await recorder.startRecording(mode: .long)
            guard recorder.isRecording else {
                throw RecordingError.failedToStart(NSError(domain: "Shrava", code: -3, userInfo: [
                    NSLocalizedDescriptionKey: "Recorder did not start"
                ]))
            }
            UIApplication.shared.isIdleTimerDisabled = true
            startRecordingTimer()
            reloadRecordingControl()
            RecordingIntentBridge.settle(reason: "ok")
            haptic(.medium)
        } catch {
            // If activation failed because a call raced in, defer instead of fatal error.
            if isInPhoneCall {
                audioRecorder?.cancelRecording()
                audioRecorder = nil
                await endLiveActivity()
                isRecording = false
                isLongRecording = false
                UIApplication.shared.isIdleTimerDisabled = false
                pendingStartAfterCall = true
                pendingStartTitle = title
                pendingStartFromIntent = true
                lastError = RecordingError.callInProgress.errorDescription
                RecordingIntentBridge.settle(reason: "failed")
                return
            }
            audioRecorder?.cancelRecording()
            audioRecorder = nil
            await endLiveActivity()
            isRecording = false
            isLongRecording = false
            UIApplication.shared.isIdleTimerDisabled = false
            Self.log.error("startLongRecordingFromIntent failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't start yet: \(error.localizedDescription). Try again in a moment."
            RecordingIntentBridge.settle(reason: "failed")
        }
    }

    func stopLongRecordingFromIntent() async {
        guard isRecording, isLongRecording else {
            RecordingIntentBridge.settle(reason: "ok")
            return
        }
        // Keep process alive for transcription after intent returns.
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "ShravaTranscribe") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }

        pendingStartAfterCall = false
        stopRecordingTimer()
        isRecording = false
        isPaused = false
        let duration = recordingDuration
        isProcessing = true
        transcriptionProgress = 0
        audioLevel = 0
        UIApplication.shared.isIdleTimerDisabled = false

        let url = await audioRecorder?.stopLongRecording()
        // End Live Activity BEFORE deactivating session (AudioRecordingIntent contract).
        await endLiveActivity()
        audioRecorder?.deactivateAfterStop()
        audioRecorder = nil
        reloadRecordingControl()
        RecordingIntentBridge.settle(reason: "ok")

        defer {
            isProcessing = false
            isLongRecording = false
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }

        guard let url else {
            lastError = "No audio file recorded"
            return
        }

        do {
            let result = try await IOSWhisper.shared.transcribeFile(
                url: url,
                durationSeconds: duration,
                language: SettingsManager.shared.settings.language,
                dictionary: dictionary,
                progress: { [weak self] p in
                    self?.transcriptionProgress = p
                }
            )
            await finishTranscription(result)
        } catch {
            lastError = "Error: \(error.localizedDescription)"
            notifyError()
        }
    }

    private func reloadRecordingControl() {
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: ShravaControlKind.recording)
        }
    }

    func refreshModelStatus() {
        modelManager.refreshStatus()
        modelReady = modelManager.isReady
    }

    /// Keyboard / in-app URL (`shrava://record`) when the app is opened.
    /// Action Button / Control Center / Siri use `StartRecordingIntent` (no UI).
    func startRecordingFromKeyboard() {
        launchedFromKeyboard = true
        currentTab = .record
        Task { await startLongRecording() }
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


    /// True when a cellular/FaceTime call currently owns the mic.
    private var isInPhoneCall: Bool { PhoneCallMonitor.shared.hasActiveCall }

    private func beginLongRecordingSession(title: String) {
        isRecording = true
        isLongRecording = true
        isPaused = false
        recordingDuration = 0
        accumulatedPause = 0
        recordingStartedAt = Date()
        pauseStartedAt = nil
        lastError = nil
        showingResult = false
        transcriptionProgress = 0
        audioLevel = 0
        waveformSamples = Array(repeating: 0.08, count: 32)
        transcriptGapMarkers = []
    }

    private func attachRecorderDelegate(_ recorder: IOSAudioRecorder) {
        recorder.delegate = self
    }

    // MARK: - IOSAudioRecorderDelegate

    nonisolated func audioRecorderDidBeginInterruption(_ recorder: IOSAudioRecorder, reason: RecordingPauseReason) {
        Task { @MainActor in
            guard self.isRecording, self.isLongRecording else { return }
            if let marker = reason.transcriptGapMarker {
                if self.transcriptGapMarkers.last != marker {
                    self.transcriptGapMarkers.append(marker)
                }
            }
            if !self.isPaused {
                if self.pauseStartedAt == nil { self.pauseStartedAt = Date() }
                self.isPaused = true
            }
            await self.updateLiveActivityPaused(true, reason: reason.liveActivityMessage)
            // Soft status — never a fatal error for a phone-call pause.
            if reason == .phoneCall || reason == .audioInterruption {
                self.lastError = reason.liveActivityMessage
            }
        }
    }

    nonisolated func audioRecorderDidResume(_ recorder: IOSAudioRecorder) {
        Task { @MainActor in
            guard self.isRecording, self.isLongRecording else { return }
            if let pauseStartedAt = self.pauseStartedAt {
                self.accumulatedPause += Date().timeIntervalSince(pauseStartedAt)
            }
            self.pauseStartedAt = nil
            self.isPaused = false
            if self.lastError?.contains("Paused") == true || self.lastError?.contains("call") == true {
                self.lastError = nil
            }
            await self.updateLiveActivityPaused(false, reason: nil)
        }
    }

    nonisolated func audioRecorderResumeFailed(_ recorder: IOSAudioRecorder, error: Error, willRetry: Bool) {
        Task { @MainActor in
            guard self.isRecording, self.isLongRecording else { return }
            // Transient — keep recording session alive; show soft status only.
            self.isPaused = true
            if self.pauseStartedAt == nil { self.pauseStartedAt = Date() }
            let msg = willRetry
                ? "Paused — waiting to resume (\(error.localizedDescription))"
                : "Paused — could not resume yet. Tap Resume or reopen Shrava after the call."
            self.lastError = msg
            await self.updateLiveActivityPaused(true, reason: "Paused — waiting to resume")
        }
    }

    // MARK: - Quick (hold-to-talk)

    func startRecording() async {
        guard !isRecording else { return }
        guard await prepareToRecord() else { return }

        isRecording = true
        isLongRecording = false
        isPaused = false
        recordingDuration = 0
        accumulatedPause = 0
        recordingStartedAt = Date()
        lastError = nil
        showingResult = false
        audioLevel = 0
        waveformSamples = Array(repeating: 0.08, count: 32)

        audioRecorder = IOSAudioRecorder()
        do {
            try await audioRecorder?.startRecording(mode: .quick)
            startRecordingTimer()
            haptic(.medium)
        } catch {
            isRecording = false
            lastError = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    // MARK: - Long meeting recording

    func startLongRecording(title: String = "Meeting") async {
        guard !isRecording else { return }
        guard await prepareToRecord() else { return }

        Self.log.info("startLongRecording callActive=\(self.isInPhoneCall) modelReady=\(self.modelReady)")
        if isInPhoneCall {
            pendingStartAfterCall = true
            pendingStartTitle = title
            pendingStartFromIntent = false
            lastError = RecordingError.callInProgress.errorDescription
            return
        }

        beginLongRecordingSession(title: title)

        // Live Activity before recorder (same contract as AudioRecordingIntent).
        let laOK = await startLiveActivity(title: title)
        if !laOK {
            // Still allow in-app recording if Live Activities are off — warn but continue.
            lastError = "Live Activities are off — enable them for Dynamic Island + shortcuts."
        }

        let recorder = IOSAudioRecorder()
        attachRecorderDelegate(recorder)
        audioRecorder = recorder
        do {
            try await recorder.startRecording(mode: .long)
            UIApplication.shared.isIdleTimerDisabled = true
            startRecordingTimer()
            reloadRecordingControl()
            haptic(.medium)
        } catch {
            if isInPhoneCall {
                audioRecorder?.cancelRecording()
                audioRecorder = nil
                isRecording = false
                isLongRecording = false
                UIApplication.shared.isIdleTimerDisabled = false
                await endLiveActivity()
                pendingStartAfterCall = true
                pendingStartTitle = title
                pendingStartFromIntent = false
                lastError = RecordingError.callInProgress.errorDescription
                return
            }
            audioRecorder?.cancelRecording()
            audioRecorder = nil
            isRecording = false
            isLongRecording = false
            UIApplication.shared.isIdleTimerDisabled = false
            await endLiveActivity()
            // Soft message — activation often fails transiently right after a call.
            Self.log.error("startLongRecording failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't start yet: \(error.localizedDescription). Try again in a moment."
        }
    }

    func toggleLongRecording() async {
        if isRecording && isLongRecording {
            await stopLongRecordingAndTranscribe()
        } else if !isRecording {
            await startLongRecording()
        }
    }

    func pauseLongRecording() async {
        guard isRecording, isLongRecording, !isPaused else { return }
        audioRecorder?.pause(reason: .manual)
        // Delegate updates isPaused + Live Activity.
        haptic(.light)
    }

    func resumeLongRecording() async {
        guard isRecording, isLongRecording, isPaused else { return }
        if isInPhoneCall {
            lastError = RecordingError.callInProgress.errorDescription
            return
        }
        // Prefer retrying resume so a single activation blip isn't fatal.
        audioRecorder?.resumeWithRetry(trigger: "userResume")
        haptic(.light)
    }

    func stopRecordingAndTranscribe() async {
        guard isRecording else { return }
        if isLongRecording {
            await stopLongRecordingAndTranscribe()
            return
        }

        stopRecordingTimer()
        isRecording = false
        isProcessing = true
        audioLevel = 0
        haptic(.light)
        defer { isProcessing = false }

        guard let recorder = audioRecorder,
              let audioData = recorder.stopRecording() else {
            lastError = "No audio data recorded"
            return
        }
        audioRecorder = nil

        do {
            let result = try await IOSWhisper.shared.transcribe(
                audioData: audioData,
                durationSeconds: recordingDuration,
                language: SettingsManager.shared.settings.language,
                dictionary: dictionary
            )
            await finishTranscription(result)
        } catch {
            lastError = "Error: \(error.localizedDescription)"
            notifyError()
        }
    }

    func stopLongRecordingAndTranscribe() async {
        guard isRecording, isLongRecording else {
            // If stop intent fires when already stopped, ignore.
            if isRecording { await stopRecordingAndTranscribe() }
            return
        }

        stopRecordingTimer()
        isRecording = false
        isPaused = false
        let duration = recordingDuration
        isProcessing = true
        transcriptionProgress = 0
        audioLevel = 0
        UIApplication.shared.isIdleTimerDisabled = false
        haptic(.light)

        let url = await audioRecorder?.stopLongRecording()
        await endLiveActivity()
        audioRecorder?.deactivateAfterStop()
        audioRecorder = nil
        reloadRecordingControl()

        defer { isProcessing = false; isLongRecording = false }

        guard let url else {
            lastError = "No audio file recorded"
            return
        }

        do {
            let result = try await IOSWhisper.shared.transcribeFile(
                url: url,
                durationSeconds: duration,
                language: SettingsManager.shared.settings.language,
                dictionary: dictionary,
                progress: { [weak self] p in
                    self?.transcriptionProgress = p
                }
            )
            await finishTranscription(result)
            // Keep the m4a for now in Documents/Recordings (user may want it); optional cleanup:
            // try? FileManager.default.removeItem(at: url)
        } catch {
            lastError = "Error: \(error.localizedDescription)"
            notifyError()
        }
    }

    func cancelRecording() async {
        guard isRecording || pendingStartAfterCall else { return }
        pendingStartAfterCall = false
        stopRecordingTimer()
        isRecording = false
        isPaused = false
        transcriptGapMarkers = []
        UIApplication.shared.isIdleTimerDisabled = false
        audioRecorder?.cancelRecording()
        audioRecorder = nil
        launchedFromKeyboard = false
        if isLongRecording {
            isLongRecording = false
            await endLiveActivity()
            reloadRecordingControl()
        }
    }

    // MARK: - Live Activity

    @discardableResult
    private func startLiveActivity(title: String) async -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        let attributes = RecordingActivityAttributes(title: title)
        let state = RecordingActivityAttributes.ContentState(timerStart: Date(), isPaused: false, frozenElapsed: 0)
        do {
            liveActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            return liveActivity != nil
        } catch {
            print("Live Activity start failed: \(error)")
            return false
        }
    }

    private func updateLiveActivityPaused(_ paused: Bool, reason: String? = nil) async {
        guard let liveActivity else { return }
        let elapsed = recordingDuration
        let state: RecordingActivityAttributes.ContentState
        if paused {
            state = .init(
                timerStart: Date(),
                isPaused: true,
                frozenElapsed: elapsed,
                pauseReason: reason ?? "Paused"
            )
        } else {
            state = .init(
                timerStart: Date().addingTimeInterval(-elapsed),
                isPaused: false,
                frozenElapsed: 0,
                pauseReason: nil
            )
        }
        await liveActivity.update(.init(state: state, staleDate: nil))
    }

    private func endLiveActivity() async {
        guard let liveActivity else { return }
        let state = RecordingActivityAttributes.ContentState(
            timerStart: Date(),
            isPaused: true,
            frozenElapsed: recordingDuration
        )
        await liveActivity.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate)
        self.liveActivity = nil
    }

    // MARK: - Helpers

    private func prepareToRecord() async -> Bool {
        if !hasMicrophonePermission {
            let granted = await requestMicrophonePermission()
            if !granted {
                lastError = "Microphone permission not granted"
                return false
            }
        }
        refreshModelStatus()
        guard modelReady else {
            lastError = "Download the on-device Whisper model in Settings or Onboarding first."
            return false
        }
        return true
    }

    private func finishTranscription(_ result: TranscriptionResult) async {
        var cleaned = result.cleanedText
        var original = result.originalText
        if !transcriptGapMarkers.isEmpty {
            let gaps = transcriptGapMarkers.joined(separator: "\n")
            cleaned = cleaned.isEmpty ? gaps : gaps + "\n\n" + cleaned
            original = original.isEmpty ? gaps : gaps + "\n\n" + original
            transcriptGapMarkers = []
        }
        lastTranscription = cleaned
        showingResult = true

        let entry = HistoryEntry(
            originalText: original,
            cleanedText: cleaned,
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
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func writeTranscriptionToAppGroup(_ text: String) {
        guard let url = ShravaCore.sharedTranscriptionURL() else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func copyToClipboard() {
        UIPasteboard.general.string = lastTranscription
        haptic(.light)
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                if self.isPaused { return }
                if let started = self.recordingStartedAt {
                    self.recordingDuration = Date().timeIntervalSince(started) - self.accumulatedPause
                } else {
                    self.recordingDuration += 0.08
                }
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

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard SettingsManager.shared.settings.hapticFeedback else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func notifyError() {
        guard SettingsManager.shared.settings.hapticFeedback else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

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
