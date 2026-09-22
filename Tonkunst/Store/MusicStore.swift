import AVFoundation
import MediaPlayer
import SwiftUI

@MainActor
final class MusicStore: NSObject, ObservableObject {
    @Published var profile: ServerProfile? = KeychainStore.load()
    @Published var tracks: [MediaTrack] = []
    @Published var currentTrack: MediaTrack?
    @Published var isPlaying = false
    @Published var connectionAvailable = false
    @Published var isLoading = false
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

    override init() {
        super.init()
        configureAudio()
        configureRemoteControls()
        if profile != nil { Task { await refresh() } }
    }

    deinit { if let timeObserver { player?.removeTimeObserver(timeObserver) } }

    var offlineTracks: [MediaTrack] { tracks.filter { offline.contains($0) } }
    var listenStatus: String { connectionAvailable ? "Connected to Jellyfin" : (offlineTracks.isEmpty ? "Jellyfin unavailable" : "Offline listening") }

    func signIn(server: String, username: String, password: String) async {
        isLoading = true; errorMessage = nil
        do { profile = try await api.authenticate(server: server, username: username, password: password); KeychainStore.save(profile!); await refresh() }
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

    func signOut() { stop(); profile = nil; tracks = []; connectionAvailable = false; KeychainStore.remove() }

    func play(_ track: MediaTrack) {
        guard let source = offline.localURL(for: track) ?? (connectionAvailable ? track.streamURL : nil) else { errorMessage = "This song is not downloaded and Jellyfin is unavailable."; return }
        if currentTrack?.id == track.id { togglePlay(); return }
        stopPlayerOnly()
        currentTrack = track; progress = 0; playbackDuration = track.duration
        player = AVPlayer(url: source)
        observePlayer()
        activateAudioSession { [weak self] in
            self?.player?.play()
            self?.isPlaying = true
            self?.updateNowPlaying()
        }
    }

    func togglePlay() {
        guard let player else { if let currentTrack { play(currentTrack) }; return }
        if isPlaying {
            player.pause()
            isPlaying = false
            updateNowPlaying()
        } else {
            activateAudioSession { [weak self] in
                self?.player?.play()
                self?.isPlaying = true
                self?.updateNowPlaying()
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
        if offline.contains(track) { offline.remove(track) }
        else { do { try await offline.download(track); tracks = tracks.map { var value = $0; value.isDownloaded = offline.contains(value); return value } } catch { errorMessage = "Download failed: \(error.localizedDescription)" } }
    }

    private func observePlayer() {
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.progress = time.seconds.isFinite ? time.seconds : 0; self?.updateNowPlaying() }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in Task { @MainActor in if self?.repeatMode == .one { self?.seek(to: 0); self?.player?.play() } else { self?.next() } } }
    }
    private func stopPlayerOnly() { if let timeObserver { player?.removeTimeObserver(timeObserver); self.timeObserver = nil }; player?.pause(); player = nil }
    private func configureAudio() {
        audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        }
    }

    private func activateAudioSession(completion: @escaping @MainActor () -> Void) {
        audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(true)
            Task { @MainActor in completion() }
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
