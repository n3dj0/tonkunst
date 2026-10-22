import AVFoundation
import MediaPlayer
import Network
import SwiftUI

@MainActor
final class MusicStore: NSObject, ObservableObject {
    @Published var profile: ServerProfile?
    @Published private(set) var savedProfiles: [ServerProfile] = []
    @Published private var cachedTracks: [MediaTrack] = []
    @Published var currentTrack: MediaTrack?
    @Published var isPlaying = false
    @Published var connectionAvailable = false
    @Published private(set) var connectionEnabled = true
    @Published private(set) var isConnecting = false
    @Published var isLoading = false
    @Published private var manualRefreshAvailableDates: [String: Date] = [:]
    @Published private var libraryRefreshDates = UserDefaults.standard.dictionary(forKey: "tonkunst.libraryRefreshDates") as? [String: Date] ?? [:]
    @Published private(set) var isRestoringSession = true
    @Published var errorMessage: String?
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var isShuffled = false
    @Published var progress: Double = 0
    @Published var playbackDuration: Double = 0
    let offline = OfflineLibrary()
    @Published private(set) var queue = PlaybackQueue() {
        didSet {
            guard !isRestoringQueue, let queueAccount else { return }
            do { try queueStorage.save(queue, account: queueAccount) }
            catch { errorMessage = "The Queue could not be saved: \(error.localizedDescription)" }
        }
    }
    private let queueStorage = QueueStorage()
    private var queueAccount: String?
    private var isRestoringQueue = false

    private func restoreQueue() {
        isRestoringQueue = true
        defer { isRestoringQueue = false }
        queueAccount = profile?.id ?? "local"
        do { queue = try queueStorage.load(account: queueAccount!, token: profile?.accessToken) }
        catch {
            queue = PlaybackQueue()
            errorMessage = "The saved Queue could not be read: \(error.localizedDescription)"
        }
        currentTrack = queue.current?.track
        playbackDuration = currentTrack?.duration ?? 0
        progress = 0
        isPlaying = false
    }

    typealias RepeatMode = PlaybackRepeatMode
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
    private var hasFinishedPlayback = false
    private var connectionGeneration = 0
    private var refreshGeneration: Int?
    private static let manualRefreshCooldown: TimeInterval = 10
    private static let connectionEnabledKey = "tonkunst.connectionEnabled"

    private var didStart = false
    private var remoteControlsConfigured = false

    func start() async {
        guard !didStart else { return }
        didStart = true
        async let offlineRestoration: Void = offline.restore()
        let sessionResult = await Task.detached(priority: .userInitiated) {
            try KeychainStore.load()
        }.result
        await offlineRestoration
        switch sessionResult {
        case .success(let session):
            savedProfiles = session.profiles
            profile = session.active
            connectionEnabled = UserDefaults.standard.object(forKey: Self.connectionEnabledKey) as? Bool ?? true
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
        restoreQueue()
        isRestoringSession = false
        if profile != nil && connectionEnabled {
            await refresh()
            startConnectionMonitoring()
        }
    }

    deinit {
        pathMonitor.cancel()
        serverHealthTask?.cancel()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let didFinishObserver { NotificationCenter.default.removeObserver(didFinishObserver) }
        if let didFailToFinishObserver { NotificationCenter.default.removeObserver(didFailToFinishObserver) }
    }

    // Keep metadata for reconnection, but only expose playable songs to browsing.
    var tracks: [MediaTrack] { connectionAvailable ? cachedTracks : offlineTracks }

    func canPlay(_ track: MediaTrack) -> Bool {
        offline.contains(track) || (connectionAvailable && track.streamURL != nil)
    }

    var offlineTracks: [MediaTrack] {
        let visibleIDs = Set(cachedTracks.map(\.id))
        return cachedTracks.filter { offline.contains($0) } + offline.tracks.filter { !visibleIDs.contains($0.id) }
    }
    var listenStatus: String {
        if profile != nil && !connectionEnabled { return "Disconnected from Jellyfin" }
        if isConnecting { return "Connecting to Jellyfin…" }
        return connectionAvailable ? "Connected to Jellyfin" : (offlineTracks.isEmpty ? "Jellyfin unavailable" : "Offline listening")
    }

    func signIn(server: String, username: String, password: String) async {
        isLoading = true; errorMessage = nil
        do {
            let authenticatedProfile = try await api.authenticate(server: server, username: username, password: password)
            savedProfiles = try KeychainStore.save(authenticatedProfile)
            connectionGeneration += 1
            connectionEnabled = true
            UserDefaults.standard.set(true, forKey: Self.connectionEnabledKey)
            stop()
            if profile?.id != authenticatedProfile.id { cachedTracks = [] }
            profile = authenticatedProfile
            restoreQueue()
            await refresh()
            startConnectionMonitoring()
        }
        catch {
            print("Jellyfin authentication failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    var lastLibraryRefresh: Date? {
        guard let profile else { return nil }
        return libraryRefreshDates[profile.id]
    }

    func refreshCooldownRemaining(at date: Date = Date()) -> Int {
        guard let profile, let availableAt = manualRefreshAvailableDates[profile.id] else { return 0 }
        return max(0, Int(ceil(availableAt.timeIntervalSince(date))))
    }

    func refresh(isUserInitiated: Bool = false) async {
        guard let profile, connectionEnabled else { return }
        let generation = connectionGeneration
        // Enforce limits here so repeated taps and other refresh controls cannot bypass them.
        guard refreshGeneration != generation else { return }
        if isUserInitiated {
            guard refreshCooldownRemaining() == 0 else { return }
        }
        refreshGeneration = generation
        isLoading = true
        errorMessage = nil
        defer {
            if isUserInitiated {
                manualRefreshAvailableDates[profile.id] = Date().addingTimeInterval(Self.manualRefreshCooldown)
            }
            if refreshGeneration == generation { refreshGeneration = nil }
            if connectionGeneration == generation { isLoading = false }
        }
        do {
            let fetchedTracks = try await api.fetchSongs(profile: profile)
            guard self.profile == profile, connectionEnabled, connectionGeneration == generation else { return }
            offline.reconcile(with: fetchedTracks)
            cachedTracks = fetchedTracks.map { item in
                var item = item
                item.isDownloaded = offline.contains(item)
                return item
            }
            connectionAvailable = true
            guard self.profile == profile, connectionEnabled, connectionGeneration == generation else { return }
            libraryRefreshDates[profile.id] = Date()
            UserDefaults.standard.set(libraryRefreshDates, forKey: "tonkunst.libraryRefreshDates")
        } catch {
            guard self.profile == profile, connectionEnabled, connectionGeneration == generation else { return }
            connectionAvailable = false
            if isUserInitiated { errorMessage = "Jellyfin is unavailable. Downloaded songs are still available offline." }
        }
    }

    func useSavedAccount(_ savedProfile: ServerProfile) {
        guard let savedProfile = savedProfiles.first(where: { $0.id == savedProfile.id }) else { return }
        stop()
        serverHealthTask?.cancel()
        connectionGeneration += 1
        connectionEnabled = true
        isConnecting = false
        UserDefaults.standard.set(true, forKey: Self.connectionEnabledKey)
        KeychainStore.activate(savedProfile)
        profile = savedProfile
        restoreQueue()
        cachedTracks = []
        connectionAvailable = false
        errorMessage = nil
        Task {
            await refresh()
            guard profile == savedProfile, connectionEnabled else { return }
            startConnectionMonitoring()
        }
    }

    func toggleConnection() {
        guard let profile else { return }

        if connectionEnabled && (connectionAvailable || isConnecting) {
            connectionGeneration += 1
            connectionEnabled = false
            isConnecting = false
            UserDefaults.standard.set(false, forKey: Self.connectionEnabledKey)
            serverHealthTask?.cancel()
            serverHealthTask = nil
            connectionAvailable = false
            isLoading = false
            if canUseFallbackStream && currentTrack != nil { stop() }
        } else {
            connectionGeneration += 1
            connectionEnabled = true
            isConnecting = true
            connectionAvailable = false
            UserDefaults.standard.set(true, forKey: Self.connectionEnabledKey)
            let generation = connectionGeneration
            serverHealthTask?.cancel()
            Task {
                await refresh()
                guard self.profile == profile, connectionEnabled, connectionGeneration == generation else { return }
                isConnecting = false
                startConnectionMonitoring()
            }
        }
    }

    func forgetSavedAccount(_ savedProfile: ServerProfile) {
        guard profile == nil else { return }
        do {
            savedProfiles = try KeychainStore.remove(savedProfile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        stop()
        serverHealthTask?.cancel()
        connectionGeneration += 1
        connectionEnabled = true
        isConnecting = false
        UserDefaults.standard.set(true, forKey: Self.connectionEnabledKey)
        KeychainStore.signOut()
        profile = nil; cachedTracks = []; connectionAvailable = false; errorMessage = nil
        restoreQueue()
    }

    func play(_ track: MediaTrack, preservingQueue: Bool = false) {
        let localSource = offline.localURL(for: track)
        guard let source = localSource ?? (connectionAvailable ? track.streamURL : nil) else { return }
        if currentTrack?.id == track.id, player != nil { togglePlay(); return }
        if !preservingQueue { queue.start(QueueEntry(track: track)) }
        stopPlayerOnly()
        currentTrack = track; progress = 0; playbackDuration = track.duration
        isUsingFallbackStream = false
        canUseFallbackStream = localSource == nil
        configureRemoteControls()
        startPlayer(source: source, for: track)
    }

    func togglePlay() {
        guard let player else { if let currentTrack { play(currentTrack, preservingQueue: true) }; return }
        if isPlaying {
            player.pause()
            isPlaying = false
            updateNowPlaying()
        } else {
            if hasFinishedPlayback { seek(to: 0) }
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
    func stop() { stopPlayerOnly(); currentTrack = nil; isPlaying = false; updateNowPlaying(); deactivateAudioSession() }
    func seek(to seconds: Double) {
        hasFinishedPlayback = false
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        progress = seconds
    }
    func skip(_ delta: TimeInterval) { seek(to: max(0, min(playbackDuration, progress + delta))) }

    func next() {
        advancePlayback(afterFinishing: false)
    }

    func startQueue() {
        guard !isPlaying else { return }
        if let entry = queue.current, canPlay(entry.track) {
            play(entry.track, preservingQueue: true)
        } else {
            next()
        }
    }

    private func advancePlayback(afterFinishing: Bool) {
        guard let entry = queue.advance(repeatMode: repeatMode, afterFinishing: afterFinishing, canPlay: canPlay) else {
            if afterFinishing {
                player?.pause()
                hasFinishedPlayback = true
                isPlaying = false
                updateNowPlaying()
            }
            return
        }
        playQueueTrack(entry.track)
    }

    private func playQueueTrack(_ track: MediaTrack) {
        stopPlayerOnly()
        currentTrack = nil
        play(track, preservingQueue: true)
    }

    func previous() {
        if progress > 4 { seek(to: 0); return }
        guard let entry = queue.previous(canPlay: canPlay) else { seek(to: 0); return }
        playQueueTrack(entry.track)
    }

    func addToQueue(_ track: MediaTrack) {
        if !queue.add(track) { errorMessage = "The Queue can hold up to 1,000 upcoming songs." }
    }

    func queuePlayNext(_ id: UUID) {
        if !queue.playNext(id) { errorMessage = "The Queue can hold up to 1,000 upcoming songs." }
    }

    func removeFromQueue(_ id: UUID) {
        let isCurrent = queue.current?.id == id
        queue.remove(id)
        if isCurrent {
            stopPlayerOnly()
            currentTrack = nil
            isPlaying = false
            advancePlayback(afterFinishing: false)
            if currentTrack == nil { updateNowPlaying(); deactivateAudioSession() }
        }
    }

    func moveInQueue(_ id: UUID, up: Bool) { queue.move(id, up: up) }

    func toggleShuffle() {
        isShuffled.toggle()
        if isShuffled { queue.shuffle() }
    }

    func cycleRepeat() { repeatMode = repeatMode.next }

    func toggleDownload(_ track: MediaTrack) async {
        if offline.contains(track) {
            offline.remove(track)
            cachedTracks = cachedTracks.map { var value = $0; value.isDownloaded = offline.contains(value); return value }
        }
        else {
            guard connectionEnabled && connectionAvailable else {
                errorMessage = "Connect to Jellyfin to download songs."
                return
            }
            do { try await offline.download(track); cachedTracks = cachedTracks.map { var value = $0; value.isDownloaded = offline.contains(value); return value } }
            catch { errorMessage = "Download failed: \(error.localizedDescription)" }
        }
    }

    private func startPlayer(source: URL, for track: MediaTrack) {
        hasFinishedPlayback = false
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
                self.advancePlayback(afterFinishing: true)
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
        let failedTrack = currentTrack!
        let wasStreaming = canUseFallbackStream
        let wasFallback = isUsingFallbackStream
        let generation = connectionGeneration
        stopPlayerOnly() // Detach both failure observers before handling this failure.
        updateNowPlaying()
        guard wasStreaming, let profile else {
            errorMessage = "This download could not be played. Remove it and download the song again."
            return
        }
        Task {
            do {
                try await api.ping(profile: profile)
                guard connectionGeneration == generation, currentTrack?.id == trackID, player == nil else { return }
                guard connectionEnabled else { return }
                connectionAvailable = true
                if !wasFallback, let fallbackURL = failedTrack.fallbackStreamURL {
                    isUsingFallbackStream = true
                    startPlayer(source: fallbackURL, for: failedTrack)
                } else {
                    errorMessage = "Jellyfin could not play this song. Try another song or download it again later."
                }
            } catch {
                guard connectionGeneration == generation, currentTrack?.id == trackID, player == nil else { return }
                connectionAvailable = false
                // Losing the home server is an expected offline transition.
                currentTrack = nil
                updateNowPlaying()
            }
        }
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

    func recheckConnection() {
        guard didStart, !isRestoringSession, profile != nil, connectionEnabled else { return }
        connectionAvailable = false
        startConnectionMonitoring()
    }

    private func startConnectionMonitoring() {
        guard connectionEnabled else { return }
        let generation = connectionGeneration
        if !isMonitoringNetwork {
            pathMonitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
                    guard let self else { return }
                    self.connectionAvailable = false
                    if path.status == .satisfied && self.connectionEnabled {
                        self.startConnectionMonitoring()
                    }
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
                    guard !Task.isCancelled, self.profile == profile, self.connectionEnabled, self.connectionGeneration == generation else { return }
                    self.connectionAvailable = true
                } catch {
                    guard !Task.isCancelled, self.profile == profile, self.connectionEnabled, self.connectionGeneration == generation else { return }
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
        guard !remoteControlsConfigured else { return }
        remoteControlsConfigured = true
        let controls = MPRemoteCommandCenter.shared(); controls.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }; controls.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }; controls.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }; controls.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
    }
    private func updateNowPlaying() { guard let currentTrack else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }; MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: currentTrack.title, MPMediaItemPropertyArtist: currentTrack.artist, MPMediaItemPropertyAlbumTitle: currentTrack.album, MPMediaItemPropertyPlaybackDuration: playbackDuration, MPNowPlayingInfoPropertyElapsedPlaybackTime: progress, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0] }
}
