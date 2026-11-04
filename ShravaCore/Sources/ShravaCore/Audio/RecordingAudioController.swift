import Foundation
import AVFoundation

/// Resolves a HistoryEntry.audioFileName to an on-disk URL for Mac / iOS.
public enum RecordingAudioStore {
    public static func recordingsDirectory() -> URL {
        #if os(iOS)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Recordings", isDirectory: true)
        #else
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shrava/Recordings", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func url(forFileName name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        let url = recordingsDirectory().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Play/pause + scrubber state for a single recording file.
@MainActor
public final class RecordingAudioController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var loadError: String?

    private var player: AVAudioPlayer?
    private var tick: Timer?
    public let fileURL: URL?

    public init(fileName: String?) {
        self.fileURL = RecordingAudioStore.url(forFileName: fileName)
        super.init()
        prepare()
    }

    public init(url: URL?) {
        self.fileURL = url
        super.init()
        prepare()
    }

    private func prepare() {
        guard let fileURL else {
            loadError = "Audio file not found"
            return
        }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            #endif
            let p = try AVAudioPlayer(contentsOf: fileURL)
            p.delegate = self
            p.prepareToPlay()
            player = p
            duration = max(p.duration, 0.1)
            currentTime = 0
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    public func toggle() {
        guard player != nil else { return }
        if isPlaying { pause() } else { play() }
    }

    public func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTick()
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        stopTick()
        currentTime = player?.currentTime ?? currentTime
    }

    public func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(time, player.duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    public func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        stopTick()
    }

    private func startTick() {
        stopTick()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                self.isPlaying = player.isPlaying
            }
        }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func stopTick() {
        tick?.invalidate()
        tick = nil
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = self.duration
            self.stopTick()
        }
    }
}
