import Network
import Observation
import SwiftUI
import UIKit

struct ConnectionModeNotice: Identifiable, Equatable {
    let id = UUID()
    let isOnline: Bool

    var title: String { isOnline ? String(localized: "Online Mode", bundle: AppLocalization.bundle) : String(localized: "Offline Mode", bundle: AppLocalization.bundle) }
    var systemImage: String { isOnline ? "wifi" : "wifi.slash" }
}

@MainActor
@Observable
final class MusicStore {
    private(set) var profile: ServerProfile?
    private(set) var savedProfiles: [ServerProfile] = []
    private var cachedTracks: [MediaTrack] = [] {
        didSet { cachedTracksRevision &+= 1 }
    }
    private var cachedTracksRevision = 0
    var currentTrack: MediaTrack? { queue.current?.track }
    var isPlaying: Bool { playback.isPlaying }
    private(set) var connectionAvailable = false
    private(set) var connectionEnabled = true
    private(set) var isConnecting = false
    private(set) var connectionModeNotice: ConnectionModeNotice?
    private(set) var isLoading = false
    private var manualRefreshAvailableDates: [String: Date] = [:]
    private var libraryRefreshDates = UserDefaults.standard.dictionary(forKey: "tonkunst.libraryRefreshDates") as? [String: Date] ?? [:]
    private(set) var isRestoringSession = true
    var errorMessage: String?
    private(set) var repeatMode: RepeatMode = .off
    private(set) var isShuffled = false
    var progress: Double { playback.progress }
    var playbackDuration: Double { playback.hasDriver ? playback.duration : (currentTrack?.duration ?? 0) }
    let offline: OfflineLibrary
    private let playback: PlaybackController
    private let mediaControls: SystemMediaControls
    private(set) var queue = PlaybackQueue() {
        didSet {
            guard !isRestoringQueue, let queueAccount else { return }
            let snapshot = queue
            let previous = queueSaveTask
            let repository = queueRepository
            queueSaveTask = Task { [weak self] in
                await previous?.value
                do { try await repository.save(snapshot, account: queueAccount) }
                catch { self?.errorMessage = String(localized: "The Queue could not be saved: \(error.localizedDescription)", bundle: AppLocalization.bundle) }
            }
        }
    }
    private let queueRepository: QueueRepository
    private var queueSaveTask: Task<Void, Never>?
    private var queueAccount: String?
    private var isRestoringQueue = false
    private let accounts = AccountRepository()

    init(api: JellyfinAPI? = nil, offline: OfflineLibrary? = nil,
         queueRepository: QueueRepository = QueueRepository(), playback: PlaybackController? = nil) {
        let defaults = UserDefaults.standard
        let deviceID = defaults.string(forKey: "tonkunst.deviceID") ?? UUID().uuidString
        defaults.set(deviceID, forKey: "tonkunst.deviceID")
        self.api = api ?? JellyfinAPI(deviceID: deviceID)
        self.offline = offline ?? OfflineLibrary()
        self.queueRepository = queueRepository
        self.playback = playback ?? PlaybackController(audioSession: AudioSessionService(), factory: { AVPlayerDriver(url: $0) })
        mediaControls = SystemMediaControls()
        self.playback.onEvent = { [weak self] event in
            switch event {
            case .finished: self?.advancePlayback(afterFinishing: true)
            case .failed(let error):
                guard let self, let track = self.currentTrack else { return }
                self.handlePlaybackFailure(error, trackID: track.id)
            case .audioSessionFailed(let error):
                self?.errorMessage = String(localized: "Audio could not start: \(error.localizedDescription)", bundle: AppLocalization.bundle)
            }
        }
        self.playback.onSnapshot = { [weak mediaControls] in mediaControls?.update($0) }
        mediaControls.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .play: self.resume()
            case .pause: self.pause()
            case .next: self.next()
            case .previous: self.previous()
            case .interruptionBegan:
                self.cancelPlaybackRecovery()
                self.playback.interruptionBegan()
            case .interruptionEnded(let resume): self.playback.interruptionEnded(shouldResume: resume)
            }
        }
    }

    private func prepareAccountContent() {
        isRestoringSession = true
        isRestoringQueue = true
        queueAccount = nil
        queue = PlaybackQueue()
        isRestoringQueue = false
        offline.selectAccount(profile)
    }

    private func restoreAccountContent() async {
        guard !Task.isCancelled else { return }
        let generation = connectionGeneration
        defer { if connectionGeneration == generation { isRestoringSession = false } }
        do { try await offline.restore(knownProfiles: savedProfiles) }
        catch { if connectionGeneration == generation { errorMessage = error.localizedDescription } }
        await queueSaveTask?.value
        guard connectionGeneration == generation else { return }
        let account = profile?.id ?? "local"
        do {
            let restored = try await queueRepository.load(account: account, profile: profile)
            guard connectionGeneration == generation else { return }
            isRestoringQueue = true
            queue = restored.queue
            isRestoringQueue = false
            queueAccount = account
            if restored.recoveredArchive != nil {
                errorMessage = String(localized: "The saved Queue was damaged. A backup was preserved and a new Queue is ready.", bundle: AppLocalization.bundle)
            }
        } catch {
            errorMessage = String(localized: "The saved Queue could not be read: \(error.localizedDescription)", bundle: AppLocalization.bundle)
        }
    }

    func flushPersistence() async { await queueSaveTask?.value }

    typealias RepeatMode = PlaybackRepeatMode
    private let api: JellyfinAPI
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.tonkunst.network-path")
    private var isMonitoringNetwork = false
    private var serverHealthTask: Task<Void, Never>?
    private var connectionNoticeTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var playbackRecoveryTask: Task<Void, Never>?
    private var isUsingFallbackStream = false
    private var canUseFallbackStream = false
    private var connectionGeneration = 0
    private var refreshGeneration: Int?
    private static let manualRefreshCooldown: TimeInterval = 10
    private static let connectionEnabledKey = "tonkunst.connectionEnabled"

    private var didStart = false

    func start() async {
        guard !didStart else { return }
        didStart = true
        let sessionResult = await accounts.load()
        switch sessionResult {
        case .success(let session):
            savedProfiles = session.profiles
            profile = session.active
            connectionEnabled = UserDefaults.standard.object(forKey: Self.connectionEnabledKey) as? Bool ?? true
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
        prepareAccountContent()
        await restoreAccountContent()
        if profile != nil && connectionEnabled {
            await refresh()
            startConnectionMonitoring()
        }
    }

    isolated deinit {
        pathMonitor.cancel()
        serverHealthTask?.cancel()
        connectionNoticeTask?.cancel()
        connectionTask?.cancel()
        playbackRecoveryTask?.cancel()
    }

    // Keep metadata for reconnection, but only expose playable songs to browsing.
    var tracks: [MediaTrack] { connectionAvailable ? cachedTracks : offlineTracks }

    struct LibraryRevision: Equatable {
        let cachedTracks: Int
        let offlineTracks: Int
        let isOnline: Bool
    }

    /// An inexpensive search invalidation key; comparing full track arrays on
    /// every keystroke would put library-sized work back on the UI thread.
    var libraryRevision: LibraryRevision {
        LibraryRevision(cachedTracks: cachedTracksRevision,
                        offlineTracks: offline.contentRevision,
                        isOnline: connectionAvailable)
    }

    func canPlay(_ track: MediaTrack) -> Bool {
        track.belongs(to: profile) && (offline.contains(track) || (connectionAvailable && track.streamURL != nil))
    }

    private func canStartPlayback(_ track: MediaTrack) -> Bool {
        canPlay(track)
    }

    var offlineTracks: [MediaTrack] {
        let visibleIDs = Set(cachedTracks.map(\.id))
        return cachedTracks.filter { offline.contains($0) } + offline.tracks.filter { !visibleIDs.contains($0.id) }
    }
    var listenStatus: String {
        if profile != nil && !connectionEnabled { return String(localized: "Disconnected from Jellyfin", bundle: AppLocalization.bundle) }
        if isConnecting { return String(localized: "Connecting to Jellyfin…", bundle: AppLocalization.bundle) }
        return connectionAvailable ? String(localized: "Connected to Jellyfin", bundle: AppLocalization.bundle) : (offline.isEmpty ? String(localized: "Jellyfin unavailable", bundle: AppLocalization.bundle) : String(localized: "Offline listening", bundle: AppLocalization.bundle))
    }

    func signIn(server: String, username: String, password: String) async {
        guard !isLoading else { return }
        isLoading = true; errorMessage = nil
        var generation = connectionGeneration
        defer { if connectionGeneration == generation { isLoading = false } }
        do {
            let authenticatedProfile = try await api.authenticate(server: server, username: username, password: password)
            try Task.checkCancellation()
            guard connectionGeneration == generation else { return }
            savedProfiles = try await accounts.save(authenticatedProfile)
            guard connectionGeneration == generation else { return }
            KeychainStore.activate(authenticatedProfile)
            clearConnectionModeNotice()
            connectionGeneration += 1
            generation = connectionGeneration
            connectionTask?.cancel()
            serverHealthTask?.cancel()
            connectionEnabled = true
            UserDefaults.standard.set(true, forKey: Self.connectionEnabledKey)
            stop()
            if profile?.id != authenticatedProfile.id { cachedTracks = [] }
            profile = authenticatedProfile
            prepareAccountContent()
            await restoreAccountContent()
            await refresh()
            guard !Task.isCancelled, connectionGeneration == generation, profile == authenticatedProfile, connectionEnabled else { return }
            startConnectionMonitoring()
        }
        catch is CancellationError { }
        catch {
            if connectionGeneration == generation { errorMessage = error.localizedDescription }
        }
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
        if isUserInitiated { errorMessage = nil }
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
            do { try await offline.reconcile(with: fetchedTracks) }
            catch { errorMessage = String(localized: "Offline metadata could not be saved: \(error.localizedDescription)", bundle: AppLocalization.bundle) }
            guard self.profile == profile, connectionEnabled, connectionGeneration == generation else { return }
            cachedTracks = fetchedTracks
            connectionAvailable = true
            guard self.profile == profile, connectionEnabled, connectionGeneration == generation else { return }
            libraryRefreshDates[profile.id] = Date()
            UserDefaults.standard.set(libraryRefreshDates, forKey: "tonkunst.libraryRefreshDates")
        } catch is CancellationError {
            return
        } catch {
            guard self.profile == profile, connectionEnabled, connectionGeneration == generation else { return }
            connectionAvailable = false
            if (error as? JellyfinError) == .sessionExpired {
                connectionEnabled = false
                isConnecting = false
                UserDefaults.standard.set(false, forKey: Self.connectionEnabledKey)
                serverHealthTask?.cancel()
            }
            if isUserInitiated || (error as? JellyfinError) == .sessionExpired { errorMessage = error.localizedDescription }
        }
    }

    func useSavedAccount(_ savedProfile: ServerProfile) {
        guard let savedProfile = savedProfiles.first(where: { $0.id == savedProfile.id }) else { return }
        clearConnectionModeNotice()
        stop()
        serverHealthTask?.cancel()
        connectionTask?.cancel()
        connectionGeneration += 1
        connectionEnabled = true
        isConnecting = false
        UserDefaults.standard.set(true, forKey: Self.connectionEnabledKey)
        KeychainStore.activate(savedProfile)
        profile = savedProfile
        prepareAccountContent()
        cachedTracks = []
        connectionAvailable = false
        errorMessage = nil
        let generation = connectionGeneration
        connectionTask = Task { [weak self] in
            guard let self else { return }
            await restoreAccountContent()
            await refresh()
            guard !Task.isCancelled, profile == savedProfile, connectionEnabled, connectionGeneration == generation else { return }
            startConnectionMonitoring()
        }
    }

    func toggleConnection() {
        guard let profile else { return }
        clearConnectionModeNotice()

        if connectionEnabled && (connectionAvailable || isConnecting) {
            connectionGeneration += 1
            connectionEnabled = false
            isConnecting = false
            UserDefaults.standard.set(false, forKey: Self.connectionEnabledKey)
            serverHealthTask?.cancel()
            connectionTask?.cancel()
            serverHealthTask = nil
            connectionAvailable = false
            isLoading = false
            if canUseFallbackStream && currentTrack != nil { stop() }
            showConnectionModeNotice(isOnline: false)
        } else {
            connectionGeneration += 1
            connectionEnabled = true
            isConnecting = true
            connectionAvailable = false
            UserDefaults.standard.set(true, forKey: Self.connectionEnabledKey)
            let generation = connectionGeneration
            serverHealthTask?.cancel()
            connectionTask?.cancel()
            connectionTask = Task { [weak self] in
                guard let self else { return }
                await refresh()
                guard !Task.isCancelled, self.profile == profile, connectionEnabled, connectionGeneration == generation else { return }
                isConnecting = false
                showConnectionModeNotice(isOnline: connectionAvailable)
                startConnectionMonitoring()
            }
        }
    }

    private func showConnectionModeNotice(isOnline: Bool) {
        clearConnectionModeNotice()
        let notice = ConnectionModeNotice(isOnline: isOnline)
        connectionModeNotice = notice
        UIAccessibility.post(notification: .announcement, argument: notice.title)
        connectionNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            guard let self, self.connectionModeNotice?.id == notice.id else { return }
            self.connectionModeNotice = nil
            self.connectionNoticeTask = nil
        }
    }

    private func clearConnectionModeNotice() {
        connectionNoticeTask?.cancel()
        connectionNoticeTask = nil
        connectionModeNotice = nil
    }

    func forgetSavedAccount(_ savedProfile: ServerProfile) {
        guard profile == nil else { return }
        let generation = connectionGeneration
        connectionTask?.cancel()
        connectionTask = Task { [weak self, accounts] in
            do {
                let profiles = try await accounts.remove(savedProfile)
                guard !Task.isCancelled, let self, self.connectionGeneration == generation else { return }
                self.savedProfiles = profiles
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func signOut() {
        clearConnectionModeNotice()
        stop()
        serverHealthTask?.cancel()
        connectionTask?.cancel()
        connectionGeneration += 1
        connectionEnabled = true
        isConnecting = false
        UserDefaults.standard.set(true, forKey: Self.connectionEnabledKey)
        KeychainStore.signOut()
        isLoading = false
        profile = nil; cachedTracks = []; connectionAvailable = false; errorMessage = nil
        prepareAccountContent()
        connectionTask = Task { [weak self] in await self?.restoreAccountContent() }
    }

    func play(_ track: MediaTrack, preservingQueue: Bool = false) {
        let localSource = offline.localURL(for: track)
        guard let source = localSource ?? (connectionAvailable ? track.streamURL : nil) else { return }
        guard track.belongs(to: profile) else { return }
        if currentTrack?.id == track.id, playback.hasDriver { togglePlay(); return }
        if !preservingQueue { queue.start(QueueEntry(track: track)) }
        stopPlayerOnly()
        isUsingFallbackStream = false
        canUseFallbackStream = localSource == nil
        mediaControls.configure()
        playback.load(source, track: track)
    }

    func togglePlay() { if isPlaying { pause() } else { resume() } }
    func pause() {
        cancelPlaybackRecovery()
        playback.pause()
    }
    func resume() {
        if playback.hasDriver { playback.resume() }
        else if let currentTrack { play(currentTrack, preservingQueue: true) }
    }
    func stop() { stopPlayerOnly() }
    func seek(to seconds: Double) { playback.seek(to: seconds) }
    func skip(_ delta: TimeInterval) { seek(to: progress + delta) }

    func next() {
        advancePlayback(afterFinishing: false)
    }

    func startQueue() {
        guard !isPlaying else { return }
        if let entry = queue.current, canStartPlayback(entry.track) {
            play(entry.track, preservingQueue: true)
        } else {
            next()
        }
    }

    private func advancePlayback(afterFinishing: Bool) {
        guard let entry = queue.advance(repeatMode: repeatMode, afterFinishing: afterFinishing, canPlay: canStartPlayback) else {
            return
        }
        playQueueTrack(entry.track)
    }

    private func playQueueTrack(_ track: MediaTrack) {
        stopPlayerOnly()
        play(track, preservingQueue: true)
    }

    func previous() {
        if progress > 4 { seek(to: 0); return }
        guard let entry = queue.previous(canPlay: canStartPlayback) else { seek(to: 0); return }
        playQueueTrack(entry.track)
    }

    func addToQueue(_ track: MediaTrack) {
        guard track.belongs(to: profile), !isRestoringSession else { return }
        if !queue.add(track) { errorMessage = String(localized: "The Queue can hold up to 1,000 upcoming songs.", bundle: AppLocalization.bundle) }
    }

    func playFromQueue(_ id: UUID) {
        guard let entry = queue.select(id, canPlay: canStartPlayback) else { return }
        playQueueTrack(entry.track)
    }

    func queuePlayNext(_ id: UUID) {
        if !queue.playNext(id) { errorMessage = String(localized: "The Queue can hold up to 1,000 upcoming songs.", bundle: AppLocalization.bundle) }
    }

    func removeFromQueue(_ id: UUID) {
        let isCurrent = queue.current?.id == id
        queue.remove(id)
        if isCurrent {
            stopPlayerOnly()
            advancePlayback(afterFinishing: false)
        }
    }

    func moveInQueue(_ id: UUID, up: Bool) { queue.move(id, up: up) }

    func toggleShuffle() {
        isShuffled.toggle()
        if isShuffled { queue.shuffle() }
    }

    func cycleRepeat() { repeatMode = repeatMode.next }

    func toggleDownload(_ track: MediaTrack) async {
        guard !offline.downloading.contains(track.id) else { return }
        if offline.contains(track) {
            do { try await offline.remove(track) }
            catch { errorMessage = String(localized: "Download could not be removed: \(error.localizedDescription)", bundle: AppLocalization.bundle) }
        }
        else {
            guard connectionEnabled && connectionAvailable else {
                errorMessage = String(localized: "Connect to Jellyfin to download songs.", bundle: AppLocalization.bundle)
                return
            }
            do { try await offline.download(track) }
            catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            catch { errorMessage = String(localized: "Download failed: \(error.localizedDescription)", bundle: AppLocalization.bundle) }
        }
    }

    private func handlePlaybackFailure(_ error: Error?, trackID: String) {
        guard let failedTrack = currentTrack, failedTrack.id == trackID else { return }
        let wasStreaming = canUseFallbackStream
        let wasFallback = isUsingFallbackStream
        let generation = connectionGeneration
        stopPlayerOnly() // Detach both failure observers before handling this failure.
        guard wasStreaming, let profile else {
            errorMessage = String(localized: "This download could not be played. Remove it and download the song again.", bundle: AppLocalization.bundle)
            return
        }
        playbackRecoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await api.ping(profile: profile)
                guard !Task.isCancelled, connectionGeneration == generation, currentTrack?.id == trackID, !playback.hasDriver else { return }
                guard connectionEnabled else { return }
                connectionAvailable = true
                if !wasFallback, let fallbackURL = failedTrack.fallbackStreamURL {
                    isUsingFallbackStream = true
                    playback.load(fallbackURL, track: failedTrack)
                } else {
                    errorMessage = String(localized: "Jellyfin could not play this song. Try another song or download it again later.", bundle: AppLocalization.bundle)
                }
            } catch is CancellationError { return }
            catch {
                guard connectionGeneration == generation, currentTrack?.id == trackID, !playback.hasDriver else { return }
                connectionAvailable = false
                // Losing the home server is an expected offline transition.
            }
        }
    }

    private func stopPlayerOnly() {
        cancelPlaybackRecovery()
        playback.stop()
    }

    private func cancelPlaybackRecovery() {
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
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
                guard await self?.checkServerHealth(generation: generation) == true else { return }
                // Do not promote weak self across the sleep: the store owns this task.
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
            }
        }
    }

    private func checkServerHealth(generation: Int) async -> Bool {
        guard let profile, connectionEnabled, connectionGeneration == generation else { return false }
        let available: Bool
        do {
            try await api.ping(profile: profile)
            available = true
        } catch is CancellationError { return false }
        catch { available = false }
        guard !Task.isCancelled, self.profile == profile, connectionEnabled, connectionGeneration == generation else { return false }
        connectionAvailable = available
        return true
    }

}
