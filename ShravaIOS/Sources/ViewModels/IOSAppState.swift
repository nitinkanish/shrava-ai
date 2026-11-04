import SwiftUI
import AVFoundation
import CoreMedia
import ActivityKit
import WidgetKit
import CallKit
import BackgroundTasks
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
    /// Bumped whenever History changes so lists reload (pending → complete).
    @Published var historyEpoch: Int = 0
    /// After stop, open this history item when the user taps into the app.
    @Published var pendingOpenHistoryID: UUID?
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
    private var transcribeBgTask: UIBackgroundTaskIdentifier = .invalid
    private static let continuedProcessingTaskID = "com.shrava.ios.transcribe"
    private var continuedProcessingRegistered = false

    let dictionary: PersonalDictionary
    let historyManager: HistoryManager
    let modelManager = WhisperModelManager.shared

    private init() {
        dictionary = PersonalDictionary(storageURL: ShravaCore.dictionaryStorageURL())
        historyManager = HistoryManager(storageURL: ShravaCore.historyStorageURL())

        modelReady = modelManager.isReady
        setupCloudSync()
        setupAudioSession()
        registerIntentExecutor()
        observeStopIntent()
        setupCallMonitor()
        observeLifecycleForResume()
        registerContinuedProcessingTask()
        Task { @MainActor in
            // Drop orphaned/stale Live Activities from killed sessions so they
            // cannot stick around showing a failed/error chrome.
            await self.endAllLiveActivities(reason: "launch-cleanup")
            await self.recoverOrphanedRecordings()
            await self.resumePendingTranscriptions()
        }
    }

    private func registerIntentExecutor() {
        RecordingIntentExecutor.handle = { [weak self] action in
            guard let self else { return "failed" }
            return await self.performRecordingIntent(action)
        }
    }

    private func registerContinuedProcessingTask() {
        guard !continuedProcessingRegistered else { return }
        continuedProcessingRegistered = true
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.continuedProcessingTaskID,
            using: nil
        ) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // Work is driven from stopLongRecording*; this handler exists so the
            // system can reinstate progress UI if the process was relaunched.
            task.expirationHandler = {
                task.setTaskCompleted(success: false)
            }
            task.progress.totalUnitCount = 100
            task.progress.completedUnitCount = 0
            Task { @MainActor in
                // If we still have a pending item, keep reporting; otherwise finish.
                if IOSAppState.shared.isProcessing {
                    // Leave running until transcribe path completes / expires.
                } else {
                    task.setTaskCompleted(success: true)
                }
            }
        }
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
        // Call ended (CXCallObserver hasEnded / no active calls).
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
        guard isRecording, isLongRecording, audioRecorder != nil else { return }
        // Resume whenever we are paused OR the recorder stopped capturing during the call
        // (unexpected finish / failed prior resume). Always re-arm retries on call end.
        let recorderIdle = audioRecorder?.isRecording != true
        let needsResume = isPaused
            || audioRecorder?.isPausedRecording == true
            || audioRecorder?.currentPauseReason != nil
            || recorderIdle
        if needsResume {
            Self.log.info("callEnded resume isPaused=\(self.isPaused) idle=\(recorderIdle) reason=\(String(describing: self.audioRecorder?.currentPauseReason), privacy: .public)")
            print("SHRAVA callEnded resume isPaused=\(isPaused) idle=\(recorderIdle)")
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
        guard let action = RecordingIntentAction(rawValue: raw) else {
            RecordingIntentBridge.settle(reason: "unknown")
            return
        }
        let reason = await performRecordingIntent(action)
        RecordingIntentBridge.settle(reason: reason)
    }

    /// Shared by LiveActivityIntent executor and NotificationCenter bridge.
    @discardableResult
    func performRecordingIntent(_ action: RecordingIntentAction) async -> String {
        switch action {
        case .start:
            return await startLongRecordingFromIntentReturningReason()
        case .stop:
            return await stopLongRecordingFromIntentReturningReason()
        case .toggle:
            if (isRecording && isLongRecording) || RecordingIntentBridge.isLiveRecordingActive {
                let r = await stopLongRecordingFromIntentReturningReason()
                return r == "ok" ? "stopped" : r
            }
            let r = await startLongRecordingFromIntentReturningReason()
            return r == "ok" ? "started" : r
        case .pause:
            guard isRecording, isLongRecording, !isPaused else { return "ok" }
            await pauseLongRecording()
            return "ok"
        case .resume:
            guard isRecording, isLongRecording, isPaused else { return "ok" }
            await resumeLongRecording()
            return "ok"
        }
    }

    /// Intent/Control path: await Live Activity first, then start recorder while AudioRecordingIntent grant is open. Never return with mic active and no LA (AppIntents asserts).
    func startLongRecordingFromIntent(title: String = "Meeting") async {
        let reason = await startLongRecordingFromIntentReturningReason(title: title)
        RecordingIntentBridge.settle(reason: reason)
    }

    @discardableResult
    func startLongRecordingFromIntentReturningReason(title: String = "Meeting") async -> String {
        if isRecording && isLongRecording {
            return "ok"
        }
        guard !isRecording else {
            return "busy"
        }

        _ = startDiagnostics(path: "intent")

        let laEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        if !laEnabled {
            debugLog("intent: Live Activities disabled in Settings")
        }

        if !hasMicrophonePermission {
            lastError = "Microphone permission not granted"
            debugLog("intent: mic permission missing")
            return "permission"
        }
        refreshModelStatus()
        guard modelReady else {
            lastError = "Download the on-device Whisper model in Settings or Onboarding first."
            debugLog("intent: model missing")
            return "model"
        }

        if isInPhoneCall {
            pendingStartAfterCall = true
            pendingStartTitle = title
            pendingStartFromIntent = true
            lastError = RecordingError.callInProgress.errorDescription
            debugLog("intent: deferred — call active [\(PhoneCallMonitor.shared.debugDescriptionCalls)]")
            return "failed"
        }

        // AudioRecordingIntent hard-crashes (EXC_BREAKPOINT / AppIntents assertion
        // "performed with an active audio session but without a Live Activity") if
        // perform() returns with the mic/session active and no Live Activity.
        // So: await Activity.request BEFORE starting the recorder; on LA failure
        // never leave audio armed — return liveActivity for foreground retry.
        let laOK = await startLiveActivity(title: title)
        debugLog("intent: Live Activity pre-recorder ok=\(laOK)")
        if !laOK {
            lastError = ActivityAuthorizationInfo().areActivitiesEnabled
                ? "Couldn’t start Live Activity from background. Open Shrava and try again."
                : "Turn on Live Activities for Shrava in Settings."
            debugLog("intent: aborting start — no Live Activity (would crash AudioRecordingIntent)")
            return "liveActivity"
        }

        beginLongRecordingSession(title: title)

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
            lastError = nil
            debugLog("intent: recorder started ok (LA already active)")
            haptic(.medium)
            return "ok"
        } catch {
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
                debugLog("intent: call raced in during start")
                return "failed"
            }
            audioRecorder?.cancelRecording()
            audioRecorder = nil
            await endLiveActivity()
            isRecording = false
            isLongRecording = false
            UIApplication.shared.isIdleTimerDisabled = false
            let detail = Self.formatError(error)
            debugLog("intent: recorder failed \(detail)")
            lastError = "Couldn't start yet: \(detail). Try again in a moment."
            return "failed"
        }
    }

    func stopLongRecordingFromIntent() async {
        let reason = await stopLongRecordingFromIntentReturningReason()
        RecordingIntentBridge.settle(reason: reason)
    }

    @discardableResult
    func stopLongRecordingFromIntentReturningReason() async -> String {
        debugLog("STOP path=intent recording=\(isRecording) long=\(isLongRecording) la=\(RecordingIntentBridge.isLiveRecordingActive) dur=\(Int(recordingDuration))s")

        // Process was killed mid-record: LA may still show, but local state is cold.
        if !(isRecording && isLongRecording) {
            if RecordingIntentBridge.isLiveRecordingActive {
                await endAllLiveActivities()
                reloadRecordingControl()
            }
            // Recover newest orphan and transcribe if present.
            if let recovered = await enqueueNewestOrphanIfNeeded(titlePrefix: "Recovered recording") {
                debugLog("STOP intent: recovered orphan id=\(recovered.uuidString)")
                return "ok"
            }
            return RecordingIntentBridge.isLiveRecordingActive ? "ok" : "notRecording"
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
        audioRecorder?.deactivateAfterStop()
        audioRecorder = nil
        reloadRecordingControl()
        isLongRecording = false

        guard let url else {
            lastError = "No audio file recorded"
            isProcessing = false
            debugLog("STOP intent: no audio url")
            await markLiveActivityFailed("No audio file recorded")
            return "failed"
        }

        // Keep Live Activity alive through transcription (intent may run in background).
        await updateLiveActivityTranscribing(progress: 0, elapsed: duration)
        debugLog("STOP intent: file=\(url.lastPathComponent) dur=\(String(format: "%.1f", duration))s — queuing transcription")
        await beginTranscriptionPipeline(url: url, durationSeconds: duration, recoveredTitle: nil)
        return "ok"
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

    /// Debug URL helpers so device tests can hit the exact same code paths as UI / intents.
    func debugStart(path: String) {
        currentTab = .record
        Task {
            switch path {
            case "long", "in-app":
                await startLongRecording()
            case "quick":
                await startRecording()
            case "intent":
                await startLongRecordingFromIntent()
            case "stop", "stop-intent":
                _ = await stopLongRecordingFromIntentReturningReason()
            default:
                await startLongRecording()
            }
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

    /// True when a cellular/FaceTime call currently owns the mic.
    private var isInPhoneCall: Bool { PhoneCallMonitor.shared.hasActiveCall }

    /// Human-readable NSError domain/code for on-screen diagnostics.
    static func formatError(_ error: Error) -> String {
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "No network connection. Check Wi‑Fi or cellular and try again."
            case .timedOut:
                return "The request timed out. Try again when the connection is stronger."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Couldn’t reach the server. Check the endpoint in Settings."
            default:
                break
            }
        }
        let ns = error as NSError
        let desc = error.localizedDescription
        if ns.domain == "Shrava" || (ns.domain.isEmpty && ns.code == 0) {
            return desc
        }
        return "\(desc) [\(ns.domain) \(ns.code)]"
    }

    private var debugLogURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("shrava-debug.log")
    }

    private func debugLog(_ message: String) {
        // Never log secrets (tokens/keys).
        let scrubbed = message
            .replacingOccurrences(of: #"xox[baprs]-[A-Za-z0-9-]+"#, with: "xox***", options: .regularExpression)
            .replacingOccurrences(of: #"sk-[A-Za-z0-9]+"#, with: "sk-***", options: .regularExpression)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(scrubbed)\n"
        Self.log.info("\(scrubbed, privacy: .public)")
        print("SHRAVA \(scrubbed)")
        NSLog("SHRAVA %@", scrubbed)
        let url = debugLogURL
        let maxBytes = 512_000
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? NSNumber, size.intValue > maxBytes {
                    // Rotate: keep the last ~half of the file.
                    if let existing = try? Data(contentsOf: url), existing.count > maxBytes / 2 {
                        let trimmed = existing.suffix(maxBytes / 2)
                        try? trimmed.write(to: url, options: .atomic)
                    }
                }
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func startDiagnostics(path: String) -> String {
        let session = AVAudioSession.sharedInstance()
        let laEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        let calls = PhoneCallMonitor.shared.debugDescriptionCalls
        let bundle = Bundle.main.bundleIdentifier ?? "?"
        let pid = ProcessInfo.processInfo.processIdentifier
        let msg = "START path=\(path) modelReady=\(modelReady) mic=\(hasMicrophonePermission) callActive=\(isInPhoneCall) calls=[\(calls)] laEnabled=\(laEnabled) otherAudio=\(session.isOtherAudioPlaying) cat=\(session.category.rawValue) mode=\(session.mode.rawValue) recording=\(isRecording) bundle=\(bundle) pid=\(pid)"
        debugLog(msg)
        return msg
    }

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
        _ = startDiagnostics(path: "quick")
        guard await prepareToRecord() else {
            debugLog("quick: prepareToRecord failed lastError=\(lastError ?? "?")")
            return
        }

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
            debugLog("quick: recorder started ok")
        } catch {
            isRecording = false
            let detail = Self.formatError(error)
            debugLog("quick: failed \(detail)")
            lastError = "Failed to start recording: \(detail)"
        }
    }

    // MARK: - Long meeting recording

    func startLongRecording(title: String = "Meeting") async {
        guard !isRecording else { return }
        _ = startDiagnostics(path: "in-app-long")
        guard await prepareToRecord() else {
            debugLog("in-app-long: prepareToRecord failed lastError=\(lastError ?? "?")")
            return
        }

        if isInPhoneCall {
            pendingStartAfterCall = true
            pendingStartTitle = title
            pendingStartFromIntent = false
            lastError = RecordingError.callInProgress.errorDescription
            debugLog("in-app-long: deferred — call active [\(PhoneCallMonitor.shared.debugDescriptionCalls)]")
            return
        }

        beginLongRecordingSession(title: title)

        // Recorder FIRST — Live Activity must never block in-app capture (ActivityKit is flaky
        // with free/personal-team signing and can hang several seconds before failing).
        let recorder = IOSAudioRecorder()
        attachRecorderDelegate(recorder)
        audioRecorder = recorder
        do {
            try await recorder.startRecording(mode: .long)
            UIApplication.shared.isIdleTimerDisabled = true
            startRecordingTimer()
            reloadRecordingControl()
            haptic(.medium)
            lastError = nil
            debugLog("in-app-long: recorder started ok")
            // Best-effort Dynamic Island after mic is rolling.
            Task { [weak self] in
                guard let self else { return }
                let laOK = await self.startLiveActivity(title: title)
                self.debugLog("in-app-long: Live Activity ok=\(laOK)")
            }
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
                debugLog("in-app-long: call raced in during start")
                return
            }
            audioRecorder?.cancelRecording()
            audioRecorder = nil
            isRecording = false
            isLongRecording = false
            UIApplication.shared.isIdleTimerDisabled = false
            await endLiveActivity()
            let detail = Self.formatError(error)
            debugLog("in-app-long: failed \(detail)")
            lastError = "Couldn't start yet: \(detail). Try again in a moment."
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
            lastError = "Error: \(Self.formatError(error))"
            notifyError()
        }
    }

    func stopLongRecordingAndTranscribe() async {
        guard isRecording, isLongRecording else {
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
        audioRecorder?.deactivateAfterStop()
        audioRecorder = nil
        reloadRecordingControl()
        isLongRecording = false

        guard let url else {
            lastError = "No audio file recorded"
            isProcessing = false
            await markLiveActivityFailed("No audio file recorded")
            return
        }

        await updateLiveActivityTranscribing(progress: 0, elapsed: duration)
        debugLog("STOP path=in-app file=\(url.lastPathComponent) dur=\(String(format: "%.1f", duration))s")
        await beginTranscriptionPipeline(url: url, durationSeconds: duration, recoveredTitle: nil)
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
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            debugLog("LA: areActivitiesEnabled=false")
            return false
        }
        // Dismiss stale activities so a prior failed session cannot look "already recording".
        await endAllLiveActivities(reason: "before-start")

        let attributes = RecordingActivityAttributes(title: title)
        let state = RecordingActivityAttributes.ContentState(
            timerStart: Date(),
            isPaused: false,
            frozenElapsed: 0,
            phase: .recording,
            progress: 0
        )
        do {
            // Activity.request is synchronous but can stall under free signing — bound it.
            let activity = try await withThrowingTaskGroup(of: Activity<RecordingActivityAttributes>.self) { group in
                group.addTask { @MainActor in
                    try Activity.request(
                        attributes: attributes,
                        content: .init(state: state, staleDate: nil),
                        pushType: nil
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    throw NSError(domain: "Shrava", code: -4, userInfo: [
                        NSLocalizedDescriptionKey: "Live Activity request timed out"
                    ])
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            liveActivity = activity
            debugLog("LA: request ok id=\(activity.id)")
            return true
        } catch {
            let detail = Self.formatError(error)
            debugLog("LA: request failed \(detail)")
            return false
        }
    }

    /// Prefer the in-memory handle; fall back to any system-tracked activity (intent / cold start).
    private func adoptLiveActivityIfNeeded() {
        if liveActivity == nil {
            liveActivity = Activity<RecordingActivityAttributes>.activities.first
        }
    }

    private func updateLiveActivityPaused(_ paused: Bool, reason: String? = nil) async {
        adoptLiveActivityIfNeeded()
        guard let liveActivity else { return }
        let elapsed = recordingDuration
        let state: RecordingActivityAttributes.ContentState
        if paused {
            state = .init(
                timerStart: Date(),
                isPaused: true,
                frozenElapsed: elapsed,
                pauseReason: reason ?? "Paused",
                phase: .paused,
                progress: 0
            )
        } else {
            state = .init(
                timerStart: Date().addingTimeInterval(-elapsed),
                isPaused: false,
                frozenElapsed: 0,
                pauseReason: nil,
                phase: .recording,
                progress: 0
            )
        }
        await liveActivity.update(.init(state: state, staleDate: nil))
    }

    /// Post-stop: keep the Island alive and show transcription progress (intent + in-app).
    private func updateLiveActivityTranscribing(progress: Double, elapsed: TimeInterval? = nil) async {
        adoptLiveActivityIfNeeded()
        guard let liveActivity else {
            debugLog("LA: transcribing update skipped — no activity")
            return
        }
        let pct = max(0, min(100, Int((progress * 100).rounded())))
        let frozen = elapsed ?? recordingDuration
        let state = RecordingActivityAttributes.ContentState(
            timerStart: Date(),
            isPaused: true,
            frozenElapsed: frozen,
            pauseReason: "Transcribing… \(pct)%",
            phase: .transcribing,
            progress: progress
        )
        await liveActivity.update(.init(state: state, staleDate: nil))
        debugLog("LA: transcribing \(pct)%")
    }

    /// Final success — brief Saved ✓ then dismiss after ~4s. Never use failed chrome here.
    private func markLiveActivitySaved() async {
        adoptLiveActivityIfNeeded()
        guard let liveActivity else { return }
        let state = RecordingActivityAttributes.ContentState(
            timerStart: Date(),
            isPaused: true,
            frozenElapsed: recordingDuration,
            pauseReason: "Saved ✓",
            phase: .saved,
            progress: 1
        )
        let dismissAt = Date().addingTimeInterval(4)
        let savedID = liveActivity.id
        await liveActivity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(dismissAt))
        debugLog("LA: saved — dismiss after 4s id=\(savedID)")
        self.liveActivity = nil
        // Sweep any duplicates without overriding the Saved banner on the one we just ended.
        for activity in Activity<RecordingActivityAttributes>.activities where activity.id != savedID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Only for a definitive final failure — never for transient chunk/retry noise.
    private func markLiveActivityFailed(_ message: String) async {
        adoptLiveActivityIfNeeded()
        guard let liveActivity else {
            await endAllLiveActivities(reason: "failed-no-handle")
            return
        }
        let state = RecordingActivityAttributes.ContentState(
            timerStart: Date(),
            isPaused: true,
            frozenElapsed: recordingDuration,
            pauseReason: message,
            phase: .failed,
            progress: transcriptionProgress
        )
        let dismissAt = Date().addingTimeInterval(6)
        await liveActivity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(dismissAt))
        debugLog("LA: failed — \(message)")
        self.liveActivity = nil
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func endLiveActivity() async {
        await endAllLiveActivities(reason: "end")
    }

    private func endAllLiveActivities(reason: String = "sweep") async {
        let activities = Activity<RecordingActivityAttributes>.activities
        if !activities.isEmpty {
            debugLog("LA: endAll count=\(activities.count) reason=\(reason)")
        }
        for activity in activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        liveActivity = nil
    }

    // MARK: - Transcription pipeline (intent + in-app + recovery)

    private static var recordingsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Immediate History row + background Whisper; survives brief suspension via bg task + pending state.
    func beginTranscriptionPipeline(
        url: URL,
        durationSeconds: Double,
        recoveredTitle: String?
    ) async {
        let entryID = UUID()
        let fileName = url.lastPathComponent
        let placeholder = recoveredTitle.map { "\($0) — Transcribing… 0%" } ?? "Transcribing… 0%"
        var pending = HistoryEntry(
            id: entryID,
            originalText: placeholder,
            cleanedText: placeholder,
            language: SettingsManager.shared.settings.language.rawValue,
            durationSeconds: max(durationSeconds, 0.1),
            transcriptionState: .pending,
            audioFileName: fileName,
            transcriptionProgress: 0
        )
        await historyManager.add(pending)
        pendingOpenHistoryID = entryID
        historyEpoch += 1
        showingResult = false
        isProcessing = true
        transcriptionProgress = 0
        debugLog("TRANSCRIBE begin id=\(entryID.uuidString) file=\(fileName) dur=\(String(format: "%.1f", durationSeconds))")

        beginTranscribeBackgroundWork(title: "Transcribing", subtitle: formatDurationLabel(durationSeconds))

        do {
            let result = try await IOSWhisper.shared.transcribeFile(
                url: url,
                durationSeconds: durationSeconds,
                language: SettingsManager.shared.settings.language,
                dictionary: dictionary,
                progress: { [weak self] p in
                    guard let self else { return }
                    self.transcriptionProgress = p
                    Task { @MainActor in
                        await self.updatePendingProgress(id: entryID, progress: p, fileName: fileName, duration: durationSeconds, recoveredTitle: recoveredTitle)
                        self.updateContinuedProgress(p)
                    }
                },
                partialText: { [weak self] text in
                    Task { @MainActor in
                        await self?.savePartialTranscript(id: entryID, text: text, fileName: fileName, duration: durationSeconds)
                    }
                }
            )
            await finishTranscription(result, replacing: entryID, audioFileName: fileName)
            debugLog("TRANSCRIBE ok id=\(entryID.uuidString) chars=\(result.cleanedText.count)")
            // Success only — never surface transient chunk errors on the Live Activity.
            await markLiveActivitySaved()
            endTranscribeBackgroundWork(success: true)
        } catch {
            let msg = Self.formatError(error)
            debugLog("TRANSCRIBE fail id=\(entryID.uuidString) \(msg)")
            // Prefer any progressive text already saved; never mark failed if we have text.
            let existing = await historyManager.get(id: entryID)
            let partial = (existing?.cleanedText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let looksLikePlaceholder = partial.isEmpty
                || partial.hasPrefix("Transcribing")
                || partial.hasPrefix("Recovered")
                || partial.hasPrefix("Transcription failed")
            if !looksLikePlaceholder {
                pending.transcriptionState = .partial
                pending.transcriptionProgress = transcriptionProgress
                pending.cleanedText = partial
                pending.originalText = existing?.originalText ?? partial
                await historyManager.update(pending)
                historyEpoch += 1
                lastError = "Partial transcript saved — tap Retry to continue. (\(msg))"
                await markLiveActivitySaved()
                endTranscribeBackgroundWork(success: true)
            } else {
                pending.transcriptionState = .failed
                pending.transcriptionProgress = transcriptionProgress
                pending.cleanedText = "Transcription failed — tap to retry"
                pending.originalText = msg
                await historyManager.update(pending)
                historyEpoch += 1
                lastError = "Error: \(msg)"
                notifyError()
                await markLiveActivityFailed("Transcription failed")
                endTranscribeBackgroundWork(success: false)
            }
        }

        isProcessing = false
    }

    private func updatePendingProgress(
        id: UUID,
        progress: Double,
        fileName: String,
        duration: Double,
        recoveredTitle: String?
    ) async {
        let pct = Int((progress * 100).rounded())
        let label = recoveredTitle.map { "\($0) — Transcribing… \(pct)%" } ?? "Transcribing… \(pct)%"
        let entry = HistoryEntry(
            id: id,
            originalText: label,
            cleanedText: label,
            language: SettingsManager.shared.settings.language.rawValue,
            durationSeconds: duration,
            transcriptionState: .pending,
            audioFileName: fileName,
            transcriptionProgress: progress
        )
        await historyManager.update(entry)
        // Keep Island / Lock Screen in sync (intent stop often runs while backgrounded).
        await updateLiveActivityTranscribing(progress: progress)
        // Throttle History list churn: update epoch every ~10%.
        if pct % 10 == 0 {
            historyEpoch += 1
        }
    }

    private func savePartialTranscript(
        id: UUID,
        text: String,
        fileName: String,
        duration: Double
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = HistoryEntry(
            id: id,
            originalText: trimmed,
            cleanedText: trimmed,
            language: SettingsManager.shared.settings.language.rawValue,
            durationSeconds: duration,
            transcriptionState: .pending,
            audioFileName: fileName,
            transcriptionProgress: transcriptionProgress
        )
        await historyManager.update(entry)
        // Throttle UI refresh.
        if Int((transcriptionProgress * 100).rounded()) % 20 == 0 {
            historyEpoch += 1
        }
    }

    private func finishTranscription(
        _ result: TranscriptionResult,
        replacing id: UUID? = nil,
        audioFileName: String? = nil
    ) async {
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
            id: id ?? UUID(),
            originalText: original,
            cleanedText: cleaned,
            language: result.language.rawValue,
            durationSeconds: result.durationSeconds,
            transcriptionState: .complete,
            audioFileName: audioFileName,
            transcriptionProgress: 1
        )
        if id != nil {
            await historyManager.update(entry)
        } else {
            await historyManager.add(entry)
        }
        pendingOpenHistoryID = entry.id
        historyEpoch += 1

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

    func retryTranscription(for entry: HistoryEntry) async {
        guard entry.transcriptionState == .failed || entry.transcriptionState == .pending || entry.transcriptionState == .partial,
              let name = entry.audioFileName else { return }
        let url = Self.recordingsDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "Audio file missing"
            return
        }
        var updating = entry
        updating.transcriptionState = .pending
        updating.transcriptionProgress = 0
        updating.cleanedText = "Transcribing… 0%"
        await historyManager.update(updating)
        historyEpoch += 1
        currentTab = .history
        isProcessing = true
        beginTranscribeBackgroundWork(title: "Retrying transcription", subtitle: formatDurationLabel(entry.durationSeconds))
        do {
            let result = try await IOSWhisper.shared.transcribeFile(
                url: url,
                durationSeconds: entry.durationSeconds,
                language: SettingsManager.shared.settings.language,
                dictionary: dictionary,
                progress: { [weak self] p in
                    self?.transcriptionProgress = p
                    Task { @MainActor in
                        await self?.updatePendingProgress(
                            id: entry.id,
                            progress: p,
                            fileName: name,
                            duration: entry.durationSeconds,
                            recoveredTitle: nil
                        )
                        self?.updateContinuedProgress(p)
                    }
                },
                partialText: { [weak self] text in
                    Task { @MainActor in
                        await self?.savePartialTranscript(
                            id: entry.id,
                            text: text,
                            fileName: name,
                            duration: entry.durationSeconds
                        )
                    }
                }
            )
            await finishTranscription(result, replacing: entry.id, audioFileName: name)
            await markLiveActivitySaved()
            endTranscribeBackgroundWork(success: true)
        } catch {
            let msg = Self.formatError(error)
            let existing = await historyManager.get(id: entry.id)
            let partial = (existing?.cleanedText ?? entry.cleanedText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let looksLikePlaceholder = partial.isEmpty
                || partial.hasPrefix("Transcribing")
                || partial.hasPrefix("Recovered")
                || partial.hasPrefix("Transcription failed")
            var failed = entry
            if !looksLikePlaceholder {
                failed.transcriptionState = .partial
                failed.cleanedText = partial
                failed.originalText = existing?.originalText ?? partial
                await historyManager.update(failed)
                historyEpoch += 1
                lastError = "Partial transcript saved — tap Retry to continue. (\(msg))"
                await markLiveActivitySaved()
                endTranscribeBackgroundWork(success: true)
            } else {
                failed.transcriptionState = .failed
                failed.cleanedText = "Transcription failed — tap to retry"
                failed.originalText = msg
                await historyManager.update(failed)
                historyEpoch += 1
                lastError = "Error: \(msg)"
                notifyError()
                await markLiveActivityFailed("Transcription failed")
                endTranscribeBackgroundWork(success: false)
            }
        }
        isProcessing = false
    }

    /// Import orphaned m4a files that never made it into History.
    func recoverOrphanedRecordings() async {
        let dir = Self.recordingsDirectory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        let existing = await historyManager.getAll()
        let known = Set(existing.compactMap(\.audioFileName))
        let m4as = files.filter { $0.pathExtension.lowercased() == "m4a" && !known.contains($0.lastPathComponent) }
        for url in m4as.sorted(by: { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 8_000 else { continue } // skip tiny/corrupt stubs
            let duration = await audioDuration(url: url) ?? max(1, Double(size) / 7000.0)
            let entry = HistoryEntry(
                originalText: "Recovered recording",
                cleanedText: "Recovered recording — tap to transcribe",
                language: SettingsManager.shared.settings.language.rawValue,
                durationSeconds: duration,
                transcriptionState: .pending,
                audioFileName: url.lastPathComponent,
                transcriptionProgress: 0
            )
            await historyManager.add(entry)
            debugLog("RECOVER orphan \(url.lastPathComponent) dur=\(String(format: "%.1f", duration))s size=\(size)")
            historyEpoch += 1
        }
    }

    /// Legacy: recovered orphans were stored as `.failed` and looked like real failures in History.
    func migrateRecoveredFailedEntries() async {
        let all = await historyManager.getAll()
        var changed = false
        for entry in all where entry.transcriptionState == .failed
            && entry.cleanedText.hasPrefix("Recovered")
            && entry.audioFileName != nil {
            var fixed = entry
            fixed.transcriptionState = .pending
            await historyManager.update(fixed)
            changed = true
        }
        if changed { historyEpoch += 1 }
    }

    /// Resume any History rows still marked pending (app killed mid-Whisper).
    func resumePendingTranscriptions() async {
        await migrateRecoveredFailedEntries()
        let all = await historyManager.getAll()
        for entry in all where entry.transcriptionState == .pending || entry.transcriptionState == .partial {
            // Do not auto-start recovered orphans ("tap to transcribe") — only resume mid-run jobs.
            let label = entry.cleanedText
            let midRun = label.hasPrefix("Transcribing")
                || entry.transcriptionProgress > 0.01
                || entry.transcriptionState == .partial
            guard midRun else { continue }
            debugLog("RESUME \(entry.transcriptionState.rawValue) \(entry.id.uuidString)")
            await retryTranscription(for: entry)
        }
    }

    @discardableResult
    private func enqueueNewestOrphanIfNeeded(titlePrefix: String) async -> UUID? {
        await recoverOrphanedRecordings()
        let all = await historyManager.getAll()
        guard let entry = all.first(where: { ($0.transcriptionState == .pending || $0.transcriptionState == .failed || $0.transcriptionState == .partial) && $0.audioFileName != nil && $0.cleanedText.hasPrefix("Recovered") }) else { return nil }
        await retryTranscription(for: entry)
        return entry.id
    }

    private func audioDuration(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let secs = CMTimeGetSeconds(duration)
            return secs.isFinite && secs > 0 ? secs : nil
        } catch {
            return nil
        }
    }

    private func formatDurationLabel(_ t: TimeInterval) -> String {
        let e = max(0, Int(t))
        return String(format: "%d:%02d", e / 60, e % 60)
    }

    private func beginTranscribeBackgroundWork(title: String, subtitle: String) {
        if transcribeBgTask != .invalid {
            UIApplication.shared.endBackgroundTask(transcribeBgTask)
            transcribeBgTask = .invalid
        }
        transcribeBgTask = UIApplication.shared.beginBackgroundTask(withName: "ShravaTranscribe") { [weak self] in
            guard let self else { return }
            if self.transcribeBgTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.transcribeBgTask)
                self.transcribeBgTask = .invalid
            }
            self.debugLog("TRANSCRIBE bgTask expired")
        }

        // Identifier must stay under the Info.plist permitted prefix.
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.continuedProcessingTaskID,
            title: title,
            subtitle: subtitle
        )
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            debugLog("TRANSCRIBE submitted BGContinuedProcessingTask")
        } catch {
            debugLog("TRANSCRIBE BGContinuedProcessingTask submit failed: \(error.localizedDescription)")
        }
    }

    private func updateContinuedProgress(_ fraction: Double) {
        // Progress is also mirrored on History; BGContinuedProcessingTask progress
        // is updated inside the registered launch handler when the system attaches.
        _ = fraction
    }

    private func endTranscribeBackgroundWork(success: Bool) {
        if transcribeBgTask != .invalid {
            UIApplication.shared.endBackgroundTask(transcribeBgTask)
            transcribeBgTask = .invalid
        }
        _ = success
    }

    func openRecordTabForLiveActivity() {
        currentTab = .record
    }

    func openHistoryItem(_ id: UUID) {
        pendingOpenHistoryID = id
        currentTab = .history
    }

    // MARK: - Helpers

    private func prepareToRecord() async -> Bool {
        if !hasMicrophonePermission {
            let granted = await requestMicrophonePermission()
            if !granted {
                lastError = "Microphone access is off. Enable it in Settings → Shrava → Microphone."
                debugLog("prepare: mic denied")
                return false
            }
        }
        if !Self.hasEnoughFreeStorage(minimumBytes: 200_000_000) {
            lastError = "Not enough free storage to record. Free at least 200 MB and try again."
            debugLog("prepare: low storage")
            return false
        }
        refreshModelStatus()
        guard modelReady else {
            lastError = "Download the on-device Whisper model in Settings or Onboarding first."
            debugLog("prepare: model not ready status=\(String(describing: modelManager.status))")
            return false
        }
        return true
    }

    private static func hasEnoughFreeStorage(minimumBytes: Int64) -> Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let values = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else {
            return true // if unknown, don't block
        }
        return free >= minimumBytes
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
