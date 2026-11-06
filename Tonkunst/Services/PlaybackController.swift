import Foundation
import Observation

@MainActor
protocol PlaybackDriving: AnyObject {
    var onProgress: ((Double) -> Void)? { get set }
    var onPlayingChanged: ((Bool) -> Void)? { get set }
    var onFinished: (() -> Void)? { get set }
    var onFailure: (((any Error)?) -> Void)? { get set }
    func play()
    func pause()
    func seek(to seconds: Double)
}

@MainActor
protocol AudioSessionActivating: AnyObject {
    func activate() async throws
    func deactivate()
}

struct NowPlayingSnapshot: Sendable {
    let track: MediaTrack
    let duration: Double
    let progress: Double
    let isPlaying: Bool
}

/// Owns playback intent and driver lifetime. Queue selection remains in MusicStore.
@MainActor
@Observable
final class PlaybackController {
    enum Event { case finished, failed((any Error)?), audioSessionFailed(any Error) }
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private(set) var duration: Double = 0
    private(set) var hasDriver = false
    @ObservationIgnored var onEvent: ((Event) -> Void)?
    @ObservationIgnored var onSnapshot: ((NowPlayingSnapshot?) -> Void)?
    @ObservationIgnored private let factory: (URL) -> any PlaybackDriving
    @ObservationIgnored private let audioSession: any AudioSessionActivating
    @ObservationIgnored private var driver: (any PlaybackDriving)?
    @ObservationIgnored private var metadata: MediaTrack?
    @ObservationIgnored private var activation: Task<Void, Never>?
    @ObservationIgnored private var playbackID = UUID()
    @ObservationIgnored private var intentID = UUID()
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var interruptionIntent: UUID?

    init(audioSession: any AudioSessionActivating, factory: @escaping (URL) -> any PlaybackDriving) {
        self.audioSession = audioSession
        self.factory = factory
    }

    isolated deinit { activation?.cancel(); audioSession.deactivate() }

    func load(_ url: URL, track: MediaTrack) {
        stopDriver()
        metadata = track
        duration = track.duration.isFinite ? max(0, track.duration) : 0
        progress = 0
        finished = false
        let id = playbackID
        let driver = factory(url)
        self.driver = driver
        hasDriver = true
        driver.onProgress = { [weak self] value in
            guard let self, self.playbackID == id else { return }
            self.progress = value.isFinite ? max(0, value) : 0
            self.publish()
        }
        driver.onPlayingChanged = { [weak self] playing in
            guard let self, self.playbackID == id else { return }
            self.isPlaying = playing && self.wantsPlayback
            self.publish()
        }
        driver.onFinished = { [weak self] in
            guard let self, self.playbackID == id else { return }
            self.pause()
            self.finished = true
            self.onEvent?(.finished)
        }
        driver.onFailure = { [weak self] error in
            guard let self, self.playbackID == id else { return }
            self.stopDriver()
            self.publish()
            self.onEvent?(.failed(error))
        }
        resume()
    }

    func resume() {
        guard let driver, !isPlaying, activation == nil else { return }
        wantsPlayback = true
        if finished { seek(to: 0) }
        activation?.cancel()
        let intent = UUID()
        intentID = intent
        let id = playbackID
        let session = audioSession
        activation = Task { [weak self, weak driver] in
            guard !Task.isCancelled else { return }
            do {
                try await session.activate()
                guard !Task.isCancelled, let self, let driver,
                      self.playbackID == id, self.intentID == intent else { return }
                driver.play()
                self.activation = nil
                self.isPlaying = true
                self.publish()
            } catch {
                guard !Task.isCancelled, let self, self.playbackID == id, self.intentID == intent else { return }
                self.isPlaying = false
                self.wantsPlayback = false
                self.activation = nil
                self.onEvent?(.audioSessionFailed(error))
            }
        }
    }

    func pause() {
        intentID = UUID()
        wantsPlayback = false
        activation?.cancel()
        activation = nil
        driver?.pause()
        isPlaying = false
        publish()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        finished = false
        progress = max(0, min(duration, seconds))
        driver?.seek(to: progress)
        publish()
    }

    func stop() {
        stopDriver()
        metadata = nil
        duration = 0
        progress = 0
        onSnapshot?(nil)
        audioSession.deactivate()
    }

    func interruptionBegan() {
        let shouldResume = isPlaying
        pause()
        interruptionIntent = shouldResume ? intentID : nil
    }

    func interruptionEnded(shouldResume: Bool) {
        let allowed = shouldResume && interruptionIntent == intentID
        interruptionIntent = nil
        if allowed { resume() }
    }

    private func stopDriver() {
        pause()
        playbackID = UUID()
        driver?.onProgress = nil
        driver?.onPlayingChanged = nil
        driver?.onFinished = nil
        driver?.onFailure = nil
        driver = nil
        hasDriver = false
    }

    private func publish() {
        guard let metadata else { return }
        onSnapshot?(NowPlayingSnapshot(track: metadata, duration: duration, progress: progress, isPlaying: isPlaying))
    }
}
