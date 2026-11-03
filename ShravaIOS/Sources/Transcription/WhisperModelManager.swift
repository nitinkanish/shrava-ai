import Foundation
import ShravaCore

/// Downloads and tracks the on-device Whisper ggml model (no OpenAI, no API key).
@MainActor
final class WhisperModelManager: ObservableObject {
    static let shared = WhisperModelManager()

    static let modelFileName = "ggml-base-q5_1.bin"
    static let modelDisplayName = "Whisper Base Q5_1 (multilingual)"
    /// Approximate download size for UI (~57 MB).
    static let expectedByteCount: Int64 = 59_707_625
    static let downloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin")!

    enum Status: Equatable {
        case missing
        case downloading(progress: Double)
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .missing
    @Published private(set) var downloadProgress: Double = 0

    private var downloadTask: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shrava/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    var modelURL: URL {
        modelsDirectory.appendingPathComponent(Self.modelFileName)
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
        let bytes = modelByteCount ?? Self.expectedByteCount
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    init() {
        refreshStatus()
    }

    func refreshStatus() {
        if FileManager.default.fileExists(atPath: modelURL.path),
           (modelByteCount ?? 0) > 1_000_000 {
            status = .ready
            downloadProgress = 1
        } else if case .downloading = status {
            // keep downloading state
        } else {
            status = .missing
            downloadProgress = 0
        }
    }

    func ensureModel() async throws {
        refreshStatus()
        if isReady { return }
        try await downloadModel()
    }

    func downloadModel() async throws {
        if case .downloading = status { return }

        status = .downloading(progress: 0)
        downloadProgress = 0

        let destination = modelURL
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)

        do {
            let (tempURL, response) = try await URLSession.shared.download(from: Self.downloadURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "WhisperModel", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Model download failed (HTTP \(http.statusCode))"
                ])
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            downloadProgress = 1
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Download with progress updates via a delegate-backed session.
    func downloadModelWithProgress() async throws {
        if case .downloading = status { return }
        if isReady { return }

        status = .downloading(progress: 0)
        downloadProgress = 0

        let destination = modelURL
        try? FileManager.default.removeItem(at: destination.appendingPathExtension("partial"))

        let delegate = DownloadDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.onProgress = { [weak self] fraction in
                Task { @MainActor in
                    self?.downloadProgress = fraction
                    self?.status = .downloading(progress: fraction)
                }
            }
            delegate.onFinished = { [weak self] tempURL, error in
                Task { @MainActor in
                    if let error {
                        self?.status = .failed(error.localizedDescription)
                        cont.resume(throwing: error)
                        return
                    }
                    guard let tempURL else {
                        let err = NSError(domain: "WhisperModel", code: -1, userInfo: [
                            NSLocalizedDescriptionKey: "Download produced no file"
                        ])
                        self?.status = .failed(err.localizedDescription)
                        cont.resume(throwing: err)
                        return
                    }
                    do {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: tempURL, to: destination)
                        self?.downloadProgress = 1
                        self?.status = .ready
                        cont.resume()
                    } catch {
                        self?.status = .failed(error.localizedDescription)
                        cont.resume(throwing: error)
                    }
                }
            }
            let task = session.downloadTask(with: Self.downloadURL)
            self.downloadTask = task
            task.resume()
        }
        session.finishTasksAndInvalidate()
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: ((Double) -> Void)?
    var onFinished: ((URL?, Error?) -> Void)?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try FileManager.default.copyItem(at: location, to: tmp)
            onFinished?(tmp, nil)
        } catch {
            onFinished?(nil, error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onFinished?(nil, error)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fallback: Int64 = 59_707_625
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : fallback
        onProgress?(min(1.0, Double(totalBytesWritten) / Double(expected)))
    }
}
