import Foundation
import Network
import ShravaCore

/// Catalog entry for an on-device whisper.cpp ggml model (download-on-demand).
struct WhisperModelOption: Identifiable, Equatable, Hashable {
    let id: String
    let fileName: String
    let displayName: String
    let detail: String
    let downloadURL: URL
    let expectedByteCount: Int64
    let qualityRank: Int // higher = better

    var formattedExpectedSize: String {
        ByteCountFormatter.string(fromByteCount: expectedByteCount, countStyle: .file)
    }
}

/// Downloads and tracks on-device Whisper ggml models (no OpenAI, no API key).
@MainActor
final class WhisperModelManager: ObservableObject {
    static let shared = WhisperModelManager()

    static let selectedModelKey = "shrava.selectedWhisperModel"
    static let recommendedID = "large-v3-turbo-q5_0"
    /// Base (rank 10) is too weak for Hindi/Auto — require small+.
    static let minimumHindiQualityRank = 20

    /// Prefer large-v3-turbo on iPhone 17-class devices; fall back to small / base.
    static let catalog: [WhisperModelOption] = [
        WhisperModelOption(
            id: "large-v3-turbo-q5_0",
            fileName: "ggml-large-v3-turbo-q5_0.bin",
            displayName: "Large v3 Turbo Q5_0",
            detail: "Best Hindi/English quality (~547 MB). Recommended for iPhone 15 Pro / 16 / 17.",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
            expectedByteCount: 574_041_195,
            qualityRank: 30
        ),
        WhisperModelOption(
            id: "small-q5_1",
            fileName: "ggml-small-q5_1.bin",
            displayName: "Small Q5_1",
            detail: "Good multilingual balance (~181 MB). Minimum for Hindi/Auto.",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!,
            expectedByteCount: 190_085_487,
            qualityRank: 20
        ),
        WhisperModelOption(
            id: "base-q5_1",
            fileName: "ggml-base-q5_1.bin",
            displayName: "Base Q5_1",
            detail: "Fast / small (~57 MB). English-only fallback — not used for Hindi/Auto.",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin")!,
            expectedByteCount: 59_707_625,
            qualityRank: 10
        )
    ]

    static let vadFileName = "ggml-silero-v5.1.2.bin"
    static let vadDownloadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!
    static let vadExpectedByteCount: Int64 = 885_098

    enum Status: Equatable {
        case missing
        case downloading(progress: Double)
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .missing
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var bannerMessage: String?
    @Published private(set) var isOnWiFi = false
    @Published var selectedModelID: String {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: Self.selectedModelKey) }
    }

    private var downloadTask: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private let pathMonitor = NWPathMonitor()
    private var autoUpgradeStarted = false
    private var modelDownloadTask: Task<Void, Error>?

    var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shrava/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    var selectedOption: WhisperModelOption {
        Self.catalog.first { $0.id == selectedModelID } ?? Self.catalog[0]
    }

    var recommendedOption: WhisperModelOption {
        Self.catalog.first { $0.id == Self.recommendedID } ?? Self.catalog[0]
    }

    var modelURL: URL {
        modelsDirectory.appendingPathComponent(selectedOption.fileName)
    }

    var vadModelURL: URL {
        modelsDirectory.appendingPathComponent(Self.vadFileName)
    }

    var isVadReady: Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: vadModelURL.path)[.size] as? NSNumber)?.int64Value else {
            return false
        }
        return size == Self.vadExpectedByteCount
    }

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    /// True when an installed model meets Hindi/Auto quality (small+).
    var isHindiCapable: Bool {
        bestInstalledOption(minRank: Self.minimumHindiQualityRank) != nil
    }

    var modelByteCount: Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: modelURL.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    var formattedSize: String {
        let bytes = modelByteCount ?? selectedOption.expectedByteCount
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Back-compat display strings used by older UI.
    static var modelFileName: String { shared.selectedOption.fileName }
    static var modelDisplayName: String { shared.selectedOption.displayName }

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.selectedModelKey),
           Self.catalog.contains(where: { $0.id == saved }) {
            selectedModelID = saved
        } else {
            // Always recommend turbo until the user explicitly picks another size.
            // (Previously bestInstalled preferred base and skipped the turbo download.)
            selectedModelID = Self.recommendedID
        }
        refreshStatus()
        startPathMonitor()
        refreshBanner()
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.isOnWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
                self.refreshBanner()
                if self.isOnWiFi {
                    self.startAutoUpgradeIfNeeded()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.shrava.ios.model-path"))
    }

    private static func bestInstalledID(in dir: URL, minRank: Int = 0) -> String? {
        bestInstalledOption(in: dir, minRank: minRank)?.id
    }

    private static func bestInstalledOption(in dir: URL, minRank: Int) -> WhisperModelOption? {
        let installed = catalog.compactMap { opt -> WhisperModelOption? in
            guard opt.qualityRank >= minRank else { return nil }
            let url = dir.appendingPathComponent(opt.fileName)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
                  size > 1_000_000 else { return nil }
            guard TranscriptionRecoveryPolicy.validModelByteCount(size, expected: opt.expectedByteCount) else { return nil }
            return opt
        }
        return installed.max(by: { $0.qualityRank < $1.qualityRank })
    }

    func bestInstalledOption(minRank: Int = 0) -> WhisperModelOption? {
        Self.bestInstalledOption(in: modelsDirectory, minRank: minRank)
    }

    private func isValidModelSize(_ bytes: Int64, for option: WhisperModelOption) -> Bool {
        TranscriptionRecoveryPolicy.validModelByteCount(bytes, expected: option.expectedByteCount)
    }

    func refreshStatus() {
        let option = selectedOption
        let url = modelsDirectory.appendingPathComponent(option.fileName)
        if FileManager.default.fileExists(atPath: url.path),
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
           size > 1_000_000, isValidModelSize(size, for: option) {
            status = .ready
            downloadProgress = 1
        } else if FileManager.default.fileExists(atPath: url.path),
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
                  size > 1_000_000, !isValidModelSize(size, for: option) {
            // Keep suspect file until a validated replacement is downloaded.
            status = .missing
            downloadProgress = 0
        } else if case .downloading = status {
            // keep
        } else {
            status = .missing
            downloadProgress = 0
        }
        refreshBanner()
    }

    func refreshBanner() {
        if case .downloading(let p) = status {
            bannerMessage = "Downloading \(selectedOption.displayName)… \(Int(p * 100))%"
            return
        }
        if !isHindiCapable {
            if isOnWiFi {
                bannerMessage = "Hindi needs Small or Large Turbo — downloading best model on Wi‑Fi…"
            } else {
                bannerMessage = "Hindi/Auto needs Small+ model. Connect to Wi‑Fi to auto-download Large Turbo (~547 MB), or download Small in Settings."
            }
            return
        }
        if selectedOption.qualityRank < Self.minimumHindiQualityRank,
           let better = bestInstalledOption(minRank: Self.minimumHindiQualityRank) {
            bannerMessage = "Base model is weak for Hindi — using \(better.displayName)."
            return
        }
        if !isInstalled(recommendedOption), isOnWiFi {
            bannerMessage = "Recommended: download Large v3 Turbo for best Hindi/English quality."
            return
        }
        bannerMessage = nil
    }

    func isInstalled(_ option: WhisperModelOption) -> Bool {
        let url = modelsDirectory.appendingPathComponent(option.fileName)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            return false
        }
        return size > 1_000_000 && isValidModelSize(size, for: option)
    }

    /// Select a catalog model; if already on disk, mark ready.
    func select(_ option: WhisperModelOption) {
        selectedModelID = option.id
        if case .downloading = status { return }
        refreshStatus()
    }

    /// Model file used for a transcription. Refuses base for Hindi/Auto (uses best small+).
    func modelURLForTranscription(language: SupportedLanguage) -> URL? {
        let needsHindi = language == .hindi || language == .auto
        if needsHindi {
            if selectedOption.qualityRank >= Self.minimumHindiQualityRank, isInstalled(selectedOption) { return modelURL }
            if let best = bestInstalledOption(minRank: Self.minimumHindiQualityRank) {
                if selectedOption.qualityRank < Self.minimumHindiQualityRank {
                    selectedModelID = best.id
                    refreshStatus()
                }
                return modelsDirectory.appendingPathComponent(best.fileName)
            }
            return nil
        }
        if isReady { return modelURL }
        if let any = bestInstalledOption(minRank: 0) {
            return modelsDirectory.appendingPathComponent(any.fileName)
        }
        return nil
    }

    /// Optional larger ggml than the currently selected one (for hallucination retries).
    func largerModelURLIfAvailable() -> URL? {
        let currentRank = selectedOption.qualityRank
        let better = Self.catalog
            .filter { $0.qualityRank > currentRank && isInstalled($0) }
            .sorted { $0.qualityRank > $1.qualityRank }
        if let best = better.first {
            return modelsDirectory.appendingPathComponent(best.fileName)
        }
        for name in ["ggml-medium-q5_0.bin", "ggml-medium.bin"] {
            let url = modelsDirectory.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size > 10_000_000 { return url }
        }
        return nil
    }

    /// On Wi‑Fi: download Large Turbo (or at least Small) when Hindi-capable model is missing.
    func startAutoUpgradeIfNeeded() {
        guard !autoUpgradeStarted else { return }
        if case .downloading = status { return }
        guard isOnWiFi else { return }

        if isInstalled(recommendedOption) {
            // Never override an explicit Small selection with Turbo (memory/battery choice).
            Task { await downloadVadIfNeeded() }
            refreshBanner()
            return
        }

        autoUpgradeStarted = true
        let target: WhisperModelOption
        if !isHindiCapable {
            // Prefer turbo on Wi‑Fi; Small is the Hindi floor if turbo fails later.
            target = recommendedOption
        } else if selectedModelID == Self.recommendedID {
            target = recommendedOption
        } else {
            autoUpgradeStarted = false
            return
        }
        select(target)
        bannerMessage = "Downloading \(target.displayName) on Wi‑Fi for Hindi/English…"
        Task {
            do {
                try await downloadModelWithProgress()
                refreshBanner()
            } catch {
                // Fall back to Small if Turbo fails and Hindi still unsupported.
                if !isHindiCapable, let small = Self.catalog.first(where: { $0.id == "small-q5_1" }) {
                    select(small)
                    try? await downloadModelWithProgress()
                }
                refreshBanner()
            }
            autoUpgradeStarted = false
        }
    }

    func ensureModel() async throws {
        refreshStatus()
        if isReady { return }
        try await downloadModelWithProgress()
    }

    /// Ensure a Hindi-capable model exists before transcription; auto-download Small on any network if needed.
    func ensureHindiCapableModel() async throws {
        if isHindiCapable {
            if selectedOption.qualityRank >= Self.minimumHindiQualityRank, isInstalled(selectedOption) { return }
            if let best = bestInstalledOption(minRank: Self.minimumHindiQualityRank) {
                select(best)
            }
            return
        }
        // Prefer turbo when on Wi‑Fi; otherwise Small (faster / smaller cellular pull).
        let target = isOnWiFi ? recommendedOption : (Self.catalog.first { $0.id == "small-q5_1" } ?? recommendedOption)
        select(target)
        bannerMessage = "Downloading \(target.displayName) — required for Hindi…"
        do {
            try await downloadModelWithProgress()
        } catch {
            guard target.id == Self.recommendedID,
                  let small = Self.catalog.first(where: { $0.id == "small-q5_1" }) else { throw error }
            select(small)
            try await downloadModelWithProgress()
        }
        refreshBanner()
        guard isHindiCapable else {
            throw URLError(.cannotOpenFile)
        }
    }

    func downloadModel() async throws {
        try await downloadModelWithProgress()
    }

    func downloadModelWithProgress() async throws {
        let option = selectedOption
        if let task = modelDownloadTask {
            try await task.value // join auto-upgrade; never start duplicate 547 MB transfers
            if isInstalled(option) { refreshStatus(); return }
        }
        let destination = modelsDirectory.appendingPathComponent(option.fileName)
        let task = Task { @MainActor in
            try await self.download(from: option.downloadURL, to: destination, expected: option.expectedByteCount)
        }
        modelDownloadTask = task
        do {
            try await task.value
            modelDownloadTask = nil
            refreshStatus()
            guard isInstalled(option) else { throw URLError(.cannotDecodeContentData) }
            await downloadVadIfNeeded()
        } catch {
            modelDownloadTask = nil
            status = .failed("Model download failed. Check connection/storage, then retry in Settings.")
            throw error
        }
        refreshBanner()
    }

    func downloadVadIfNeeded() async {
        guard !isVadReady else { return }
        try? await download(from: Self.vadDownloadURL, to: vadModelURL, expected: Self.vadExpectedByteCount, trackProgress: false)
    }

    private func download(from url: URL, to destination: URL, expected: Int64, trackProgress: Bool = true) async throws {
        if trackProgress {
            status = .downloading(progress: 0)
            downloadProgress = 0
            refreshBanner()
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            let task = URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, response, networkError in
                // URLSession removes its temporary file as soon as this completion
                // returns. Preserve it BEFORE hopping asynchronously to MainActor.
                let preservedURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".model-download")
                var error = networkError
                var temp: URL?
                if let temporaryURL, error == nil {
                    do { try FileManager.default.moveItem(at: temporaryURL, to: preservedURL); temp = preservedURL }
                    catch let fileError { error = fileError }
                }
                let completedError = error
                let completedTemp = temp
                Task { @MainActor in
                    defer { if let completedTemp { try? FileManager.default.removeItem(at: completedTemp) } }
                    if let error = completedError {
                        if trackProgress { self?.status = .failed(error.localizedDescription) }
                        self?.refreshBanner()
                        cont.resume(throwing: error)
                        return
                    }
                    guard let temp = completedTemp else {
                        let err = URLError(.badServerResponse)
                        if trackProgress { self?.status = .failed(err.localizedDescription) }
                        self?.refreshBanner()
                        cont.resume(throwing: err)
                        return
                    }
                    do {
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                            throw URLError(.badServerResponse)
                        }
                        let attrs = try FileManager.default.attributesOfItem(atPath: temp.path)
                        guard let bytes = (attrs[.size] as? NSNumber)?.int64Value,
                              TranscriptionRecoveryPolicy.validModelByteCount(bytes, expected: expected) else {
                            throw URLError(.cannotDecodeContentData)
                        }
                        // Validate before replacing: a failed HTML/partial download must not
                        // delete the last working model. Same-volume rename is atomic.
                        let staged = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".download")
                        try FileManager.default.copyItem(at: temp, to: staged)
                        defer { try? FileManager.default.removeItem(at: staged) }
                        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staged.path)
                        if FileManager.default.fileExists(atPath: destination.path) {
                            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
                        } else {
                            try FileManager.default.moveItem(at: staged, to: destination)
                        }
                        var excluded = destination
                        var values = URLResourceValues()
                        values.isExcludedFromBackup = true
                        try? excluded.setResourceValues(values)
                        if trackProgress {
                            self?.downloadProgress = 1
                            self?.status = .ready
                        }
                        self?.refreshBanner()
                        cont.resume()
                    } catch {
                        if trackProgress { self?.status = .failed(error.localizedDescription) }
                        self?.refreshBanner()
                        cont.resume(throwing: error)
                    }
                }
            }
            if trackProgress {
                observation?.invalidate()
                observation = task.progress.observe(\.fractionCompleted) { [weak self] prog, _ in
                    Task { @MainActor in
                        guard let self, case .downloading = self.status else { return }
                        self.downloadProgress = prog.fractionCompleted
                        self.status = .downloading(progress: prog.fractionCompleted)
                        self.refreshBanner()
                    }
                }
            }
            downloadTask = task
            task.resume()
        }
    }
}
