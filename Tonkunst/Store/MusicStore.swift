import AVFoundation
import MediaPlayer
import Network
import SwiftUI

@MainActor
final class MusicStore: NSObject, ObservableObject {
    @Published var profile: ServerProfile?
    @Published var tracks: [MediaTrack] = []
    @Published var currentTrack: MediaTrack?
    @Published var isPlaying = false
    @Published var connectionAvailable = false
    @Published var isLoading = false
    @Published private(set) var isRestoringSession = true
    @Published var errorMessage: String?
    @Published var repeatMode: RepeatMode = .off
    @Published var isShuffled = false
    @Published var progress: Double = 0
    @Published var playbackDuration: Double = 0
    let offline = OfflineLibrary()

    enum RepeatMode: String { case off, all, one }
    private let api = JellyfinAPI()
    private let audioSessionQueue = DispatchQueue(label: "com.tonkunst.audio-session", qos: .userInitiated)
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var didFinishObserver: NSObjectProtocol?
    private var didFailToFinishObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.tonkunst.network-path")
    private var isMonitoringNetwork = false
    private var serverHealthTask: Task<Void, Never>?
    private var isUsingFallbackStream = false
    private var canUseFallbackStream = false

    override init() {
        super.init()
        Task { [weak self] in
            // Let SwiftUI present its first frame before doing any work that can
            // involve system services (notably Keychain and MediaPlayer).
            await Task.yield()
            guard let self else { return }

            configureRemoteControls()
            profile = await Task.detached(priority: .userInitiated) {
                KeychainStore.load()
            }.value
            isRestoringSession = false

            if profile != nil {
                await refresh()
                startConnectionMonitoring()
            }
        }
    }

    deinit {
        pathMonitor.cancel()
        serverHealthTask?.cancel()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let didFinishObserver { NotificationCenter.default.removeObserver(didFinishObserver) }
        if let didFailToFinishObserver { NotificationCenter.default.removeObserver(didFailToFinishObserver) }
    }

    var offlineTracks: [MediaTrack] {
        let visibleIDs = Set(tracks.map(\.id))
        return tracks.filter { offline.contains($0) } + offline.tracks.filter { !visibleIDs.contains($0.id) }
    }
    var listenStatus: String { connectionAvailable ? "Connected to Jellyfin" : (offlineTracks.isEmpty ? "Jellyfin unavailable" : "Offline listening") }

    func signIn(server: String, username: String, password: String) async {
        isLoading = true; errorMessage = nil
        do {
            profile = try await api.authenticate(server: server, username: username, password: password)
            KeychainStore.save(profile!)
            await refresh()
            startConnectionMonitoring()
        }
        catch {
            print("Jellyfin authentication failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func refresh() async {
        guard let profile else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fetchedTracks = try await api.fetchSongs(profile: profile)
            offline.reconcile(with: fetchedTracks)
            tracks = fetchedTracks.map { item in
                var item = item
                item.isDownloaded = offline.contains(item)
                return item
            }
            connectionAvailable = true
        } catch {
            connectionAvailable = false
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        stop()
        serverHealthTask?.cancel()
        profile = nil; tracks = []; connectionAvailable = false; KeychainStore.remove()
    }

    func play(_ track: MediaTrack) {
        let localSource = offline.localURL(for: track)
        guard let source = localSource ?? (connectionAvailable ? track.streamURL : nil) else { errorMessage = "This song is not downloaded and Jellyfin is unavailable."; return }
        if currentTrack?.id == track.id, player != nil { togglePlay(); return }
        stopPlayerOnly()
        currentTrack = track; progress = 0; playbackDuration = track.duration
        isUsingFallbackStream = false
        canUseFallbackStream = localSource == nil
        startPlayer(source: source, for: track)
    }

    func togglePlay() {
        guard let player else { if let currentTrack { play(currentTrack) }; return }
        if isPlaying {
            player.pause()
            isPlaying = false
            updateNowPlaying()
        } else {
            activateAudioSession { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.player?.play()
                    self.isPlaying = true
                    self.updateNowPlaying()
                case .failure(let error):
                    self.isPlaying = false
                    self.errorMessage = "Audio could not start: \(error.localizedDescription)"
                }
            }
        }
    }
    func stop() { stopPlayerOnly(); currentTrack = nil; isPlaying = false; deactivateAudioSession() }
    func seek(to seconds: Double) { player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)); progress = seconds }
    func skip(_ delta: TimeInterval) { seek(to: max(0, min(playbackDuration, progress + delta))) }

    func next() {
        guard !tracks.isEmpty else { return }
        guard let currentTrack, let index = tracks.firstIndex(where: { $0.id == currentTrack.id }) else { play(tracks[0]); return }
        if isShuffled { play(tracks.filter { $0.id != currentTrack.id }.randomElement() ?? currentTrack) }
        else if index + 1 < tracks.count { play(tracks[index + 1]) }
        else if repeatMode == .all { play(tracks[0]) }
    }
    func previous() { if progress > 4 { seek(to: 0) } else if let currentTrack, let index = tracks.firstIndex(where: { $0.id == currentTrack.id }), index > 0 { play(tracks[index - 1]) } }
    func cycleRepeat() { repeatMode = repeatMode == .off ? .all : (repeatMode == .all ? .one : .off) }

    func toggleDownload(_ track: MediaTrack) async {
        if offline.contains(track) {
            offline.remove(track)
            tracks = tracks.map { var value = $0; value.isDownloaded = offline.contains(value); return value }
        }
        else { do { try await offline.download(track); tracks = tracks.map { var value = $0; value.isDownloaded = offline.contains(value); return value } } catch { errorMessage = "Download failed: \(error.localizedDescription)" } }
    }

    private func startPlayer(source: URL, for track: MediaTrack) {
        let player = AVPlayer(url: source)
        self.player = player
        observePlayer(player, trackID: track.id)
        activateAudioSession { [weak self, weak player] result in
            guard let self, let player, self.player === player else { return }
            switch result {
            case .success:
                player.play()
                self.isPlaying = true
                self.updateNowPlaying()
            case .failure(let error):
                self.isPlaying = false
                self.errorMessage = "Audio could not start: \(error.localizedDescription)"
            }
        }
    }

    private func observePlayer(_ player: AVPlayer, trackID: String) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.progress = time.seconds.isFinite ? time.seconds : 0; self?.updateNowPlaying() }
        }
        itemStatusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self, weak player] item, _ in
            Task { @MainActor in
                guard let self, let player, self.player === player else { return }
                self.handleItemStatus(item.status, error: item.error, trackID: trackID)
            }
        }
        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self, weak player] observedPlayer, _ in
            Task { @MainActor in
                guard let self, let player, self.player === player else { return }
                self.isPlaying = observedPlayer.timeControlStatus != .paused
            }
        }
        didFinishObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player === player else { return }
                if self.repeatMode == .one { self.seek(to: 0); self.player?.play() } else { self.next() }
            }
        }
        didFailToFinishObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard let self, self.player === player else { return }
                self.handlePlaybackFailure(error, trackID: trackID)
            }
        }
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status, error: Error?, trackID: String) {
        if status == .failed { handlePlaybackFailure(error, trackID: trackID) }
    }

    private func handlePlaybackFailure(_ error: Error?, trackID: String) {
        guard currentTrack?.id == trackID else { return }
        isPlaying = false
        if !isUsingFallbackStream { connectionAvailable = false }
        if canUseFallbackStream, !isUsingFallbackStream, let fallbackURL = currentTrack?.fallbackStreamURL {
            isUsingFallbackStream = true
            stopPlayerOnly()
            startPlayer(source: fallbackURL, for: currentTrack!)
            return
        }
        errorMessage = "This song could not be played\(error.map { ": \($0.localizedDescription)" } ?? ".")"
    }

    private func stopPlayerOnly() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemStatusObservation = nil
        timeControlStatusObservation = nil
        if let didFinishObserver { NotificationCenter.default.removeObserver(didFinishObserver) }
        if let didFailToFinishObserver { NotificationCenter.default.removeObserver(didFailToFinishObserver) }
        didFinishObserver = nil
        didFailToFinishObserver = nil
        player?.pause()
        player = nil
    }

    private func startConnectionMonitoring() {
        if !isMonitoringNetwork {
            pathMonitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
                    guard let self else { return }
                    if path.status != .satisfied { self.connectionAvailable = false }
                }
            }
            pathMonitor.start(queue: pathMonitorQueue)
            isMonitoringNetwork = true
        }

        serverHealthTask?.cancel()
        serverHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let profile = self.profile else { return }
                do {
                    try await self.api.ping(profile: profile)
                    guard !Task.isCancelled else { return }
                    self.connectionAvailable = true
                } catch {
                    guard !Task.isCancelled else { return }
                    self.connectionAvailable = false
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func activateAudioSession(completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        audioSessionQueue.async {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
                Task { @MainActor in completion(.success(())) }
            } catch {
                Task { @MainActor in completion(.failure(error)) }
            }
        }
    }

    private func deactivateAudioSession() {
        audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    private func configureRemoteControls() {
        let controls = MPRemoteCommandCenter.shared(); controls.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }; controls.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }; controls.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }; controls.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
    }
    private func updateNowPlaying() { guard let currentTrack else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }; MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: currentTrack.title, MPMediaItemPropertyArtist: currentTrack.artist, MPMediaItemPropertyAlbumTitle: currentTrack.album, MPMediaItemPropertyPlaybackDuration: playbackDuration, MPNowPlayingInfoPropertyElapsedPlaybackTime: progress, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0] }
}
