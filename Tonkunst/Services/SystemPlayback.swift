import AVFoundation
import MediaPlayer

@MainActor
final class AudioSessionService: AudioSessionActivating {
    private let queue = DispatchQueue(label: "com.tonkunst.audio-session", qos: .userInitiated)
    func activate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .default)
                    try session.setActive(true)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func deactivate() {
        queue.async { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}

@MainActor
final class AVPlayerDriver: PlaybackDriving {
    var onProgress: ((Double) -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?
    var onFinished: (() -> Void)?
    var onFailure: (((any Error)?) -> Void)?
    private let player: AVPlayer
    private var timeObserver: Any?
    private var itemObservation: NSKeyValueObservation?
    private var playingObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []

    init(url: URL) {
        player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.onProgress?(time.seconds) }
        }
        itemObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in if item.status == .failed { self?.onFailure?(item.error) } }
        }
        playingObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in self?.onPlayingChanged?(player.timeControlStatus != .paused) }
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onFinished?() }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in self?.onFailure?(error) }
        })
    }
    isolated deinit {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for token in notifications { NotificationCenter.default.removeObserver(token) }
    }
    func play() { player.play() }
    func pause() { player.pause() }
    func seek(to seconds: Double) { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
}

@MainActor
final class SystemMediaControls {
    enum Action: Sendable { case play, pause, next, previous, interruptionBegan, interruptionEnded(Bool) }
    var onAction: ((Action) -> Void)?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var notifications: [NSObjectProtocol] = []
    private var configured = false

    func configure() {
        guard !configured else { return }
        configured = true
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand, action: .play)
        register(center.pauseCommand, action: .pause)
        register(center.nextTrackCommand, action: .next)
        register(center.previousTrackCommand, action: .previous)
        let notifications = NotificationCenter.default
        self.notifications.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                if type == AVAudioSession.InterruptionType.began.rawValue { self?.onAction?(.interruptionBegan) }
                else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    self?.onAction?(.interruptionEnded(AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)))
                }
            }
        })
        self.notifications.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.onAction?(.pause) }
            }
        })
    }

    func update(_ snapshot: NowPlayingSnapshot?) {
        guard let snapshot else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: snapshot.track.title,
            MPMediaItemPropertyArtist: snapshot.track.artist,
            MPMediaItemPropertyAlbumTitle: snapshot.track.album,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.progress,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? 1 : 0
        ]
    }

    private func register(_ command: MPRemoteCommand, action: Action) {
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor in self?.onAction?(action) }
            return .success
        }
        targets.append((command, target))
    }

    isolated deinit {
        for (command, target) in targets { command.removeTarget(target) }
        for token in notifications { NotificationCenter.default.removeObserver(token) }
    }
}
