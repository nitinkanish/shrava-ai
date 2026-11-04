import Foundation
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
            detail: "Good multilingual balance (~181 MB).",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!,
            expectedByteCount: 190_085_487,
            qualityRank: 20
        ),
        WhisperModelOption(
            id: "base-q5_1",
            fileName: "ggml-base-q5_1.bin",
            displayName: "Base Q5_1",
            detail: "Fast / small (~57 MB). Use when storage is tight.",
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
    @Published var selectedModelID: String {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: Self.selectedModelKey) }
    }

    private var downloadTask: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shrava/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    var selectedOption: WhisperModelOption {
        Self.catalog.first { $0.id == selectedModelID } ?? Self.catalog[0]
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
        return size > 100_000
    }

    var isReady: Bool {
        if case .ready = status { return true }
        return false
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
            // Prefer best already-downloaded model; else recommend turbo.
            selectedModelID = Self.bestInstalledID(in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Shrava/models", isDirectory: true)) ?? "large-v3-turbo-q5_0"
        }
        refreshStatus()
    }

    private static func bestInstalledID(in dir: URL) -> String? {
        let installed = catalog.compactMap { opt -> (WhisperModelOption, Int64)? in
            let url = dir.appendingPathComponent(opt.fileName)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
                  size > 1_000_000 else { return nil }
            return (opt, size)
        }
        return installed.max(by: { $0.0.qualityRank < $1.0.qualityRank })?.0.id
    }

    private func isValidModelSize(_ bytes: Int64, for option: WhisperModelOption) -> Bool {
        let expected = option.expectedByteCount
        let tol = max(2_000_000, expected / 50)
        return abs(bytes - expected) <= tol || bytes > expected - tol
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
            try? FileManager.default.removeItem(at: url)
            status = .missing
            downloadProgress = 0
        } else if case .downloading = status {
            // keep
        } else {
            status = .missing
            downloadProgress = 0
        }
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

    /// Optional larger ggml than the currently selected one (for hallucination retries).
    func largerModelURLIfAvailable() -> URL? {
        let currentRank = selectedOption.qualityRank
        let better = Self.catalog
            .filter { $0.qualityRank > currentRank && isInstalled($0) }
            .sorted { $0.qualityRank > $1.qualityRank }
        if let best = better.first {
            return modelsDirectory.appendingPathComponent(best.fileName)
        }
        // Also accept ad-hoc medium if present.
        for name in ["ggml-medium-q5_0.bin", "ggml-medium.bin"] {
            let url = modelsDirectory.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size > 10_000_000 { return url }
        }
        return nil
    }

    func ensureModel() async throws {
        refreshStatus()
        if isReady { return }
        try await downloadModelWithProgress()
    }

    func downloadModel() async throws {
        try await downloadModelWithProgress()
    }

    func downloadModelWithProgress() async throws {
        let option = selectedOption
        let destination = modelsDirectory.appendingPathComponent(option.fileName)
        try await download(from: option.downloadURL, to: destination, expected: option.expectedByteCount)
        refreshStatus()
        guard isReady else { throw URLError(.cannotOpenFile) }
        // Best-effort VAD model (tiny) — improves silence skipping.
        if !isVadReady {
            try? await download(from: Self.vadDownloadURL, to: vadModelURL, expected: Self.vadExpectedByteCount, trackProgress: false)
        }
    }

    func downloadVadIfNeeded() async {
        guard !isVadReady else { return }
        try? await download(from: Self.vadDownloadURL, to: vadModelURL, expected: Self.vadExpectedByteCount, trackProgress: false)
    }

    private func download(from url: URL, to destination: URL, expected: Int64, trackProgress: Bool = true) async throws {
        if trackProgress {
            status = .downloading(progress: 0)
            downloadProgress = 0
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { [weak self] temp, response, error in
                Task { @MainActor in
                    if let error {
                        if trackProgress { self?.status = .failed(error.localizedDescription) }
                        cont.resume(throwing: error)
                        return
                    }
                    guard let temp else {
                        let err = URLError(.badServerResponse)
                        if trackProgress { self?.status = .failed(err.localizedDescription) }
                        cont.resume(throwing: err)
                        return
                    }
                    do {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.moveItem(at: temp, to: destination)
                        if let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value,
                           size < expected / 2 {
                            try? FileManager.default.removeItem(at: destination)
                            throw URLError(.cannotDecodeContentData)
                        }
                        if trackProgress {
                            self?.downloadProgress = 1
                            self?.status = .ready
                        }
                        cont.resume()
                    } catch {
                        if trackProgress { self?.status = .failed(error.localizedDescription) }
                        cont.resume(throwing: error)
                    }
                }
            }
            if trackProgress {
                observation?.invalidate()
                observation = task.progress.observe(\.fractionCompleted) { [weak self] prog, _ in
                    Task { @MainActor in
                        self?.downloadProgress = prog.fractionCompleted
                        self?.status = .downloading(progress: prog.fractionCompleted)
                    }
                }
            }
            downloadTask = task
            task.resume()
        }
    }
}
