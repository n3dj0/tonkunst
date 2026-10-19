import Foundation

enum PlaybackRepeatMode: String {
    case off, all, one

    var next: Self { self == .off ? .all : (self == .all ? .one : .off) }
    var accessibilityValue: String {
        switch self {
        case .off: return "Off"
        case .all: return "All songs"
        case .one: return "One song"
        }
    }
}

// Each occurrence has its own identity, including repeated songs.
struct QueueEntry: Identifiable, Codable {
    var id = UUID()
    var track: MediaTrack
}

struct PlaybackQueue: Codable {
    static let historyLimit = 100
    static let upcomingLimit = 1000
    private(set) var history: [QueueEntry] = [] // newest first
    private(set) var current: QueueEntry?
    private(set) var upcoming: [QueueEntry] = [] // next first
    var isFull: Bool { upcoming.count >= Self.upcomingLimit }

    @discardableResult mutating func add(_ track: MediaTrack) -> Bool {
        guard !isFull else { return false }
        upcoming.append(QueueEntry(track: track))
        return true
    }

    mutating func start(_ entry: QueueEntry) {
        if let current {
            history.insert(current, at: 0)
            history = Array(history.prefix(Self.historyLimit))
        }
        current = entry
    }

    mutating func advance(repeatMode: PlaybackRepeatMode, afterFinishing: Bool,
                          canPlay: (MediaTrack) -> Bool) -> QueueEntry? {
        if afterFinishing, repeatMode == .one, let current, canPlay(current.track) { return current }
        if let index = upcoming.firstIndex(where: { canPlay($0.track) }) {
            let entry = upcoming.remove(at: index)
            start(entry)
            return entry
        }
        if repeatMode == .all {
            let cycle = history.reversed() + (current.map { [$0] } ?? [])
            if let first = cycle.first(where: { canPlay($0.track) }) {
                let playable = cycle.filter { canPlay($0.track) }
                // Preserve unavailable upcoming entries and enforce the limit.
                upcoming += playable.dropFirst().prefix(Self.upcomingLimit - upcoming.count)
                    .map { QueueEntry(track: $0.track) }
                let entry = QueueEntry(track: first.track)
                start(entry)
                return entry
            }
        }
        return nil
    }

    mutating func previous(canPlay: (MediaTrack) -> Bool) -> QueueEntry? {
        guard !isFull, let index = history.firstIndex(where: { canPlay($0.track) }) else { return nil }
        if let current { upcoming.insert(current, at: 0) }
        current = history.remove(at: index)
        return current
    }

    @discardableResult mutating func playNext(_ id: UUID) -> Bool {
        if let index = upcoming.firstIndex(where: { $0.id == id }) {
            upcoming.insert(upcoming.remove(at: index), at: 0)
            return true
        }
        guard !isFull, let entry = (history + (current.map { [$0] } ?? [])).first(where: { $0.id == id }) else { return false }
        upcoming.insert(QueueEntry(track: entry.track), at: 0)
        return true
    }

    mutating func remove(_ id: UUID) {
        history.removeAll { $0.id == id }
        upcoming.removeAll { $0.id == id }
        if current?.id == id { current = nil }
    }

    func canMove(_ id: UUID, up: Bool) -> Bool {
        if let index = upcoming.firstIndex(where: { $0.id == id }) {
            return upcoming.indices.contains(index + (up ? 1 : -1))
        }
        if let index = history.firstIndex(where: { $0.id == id }) {
            return history.indices.contains(index + (up ? -1 : 1))
        }
        return false
    }

    mutating func move(_ id: UUID, up: Bool) {
        guard canMove(id, up: up) else { return }
        if let index = upcoming.firstIndex(where: { $0.id == id }) {
            upcoming.swapAt(index, index + (up ? 1 : -1))
        } else if let index = history.firstIndex(where: { $0.id == id }) {
            history.swapAt(index, index + (up ? -1 : 1))
        }
    }

    mutating func shuffle() { upcoming.shuffle() }
}

// Credentials remain in Keychain; only token-free metadata is written to disk.
extension PlaybackQueue {
    func authorizing(with token: String?) -> PlaybackQueue {
        func entry(_ value: QueueEntry) -> QueueEntry {
            var value = value
            // Restore authentication on Jellyfin URLs even after stripping their old token.
            func authorizedURL(_ original: URL?) -> URL? {
                guard let original,
                      var parts = URLComponents(url: original, resolvingAgainstBaseURL: false) else { return original }
                parts.queryItems = (parts.queryItems ?? []).filter { $0.name.lowercased() != "api_key" }
                if let token { parts.queryItems?.append(URLQueryItem(name: "api_key", value: token)) }
                return parts.url
            }
            value.track.artworkURL = authorizedURL(value.track.artworkURL)
            value.track.streamURL = authorizedURL(value.track.streamURL)
            value.track.fallbackStreamURL = authorizedURL(value.track.fallbackStreamURL)
            return value
        }
        var result = self
        result.history = history.prefix(Self.historyLimit).map(entry)
        result.current = current.map(entry)
        result.upcoming = upcoming.prefix(Self.upcomingLimit).map(entry)
        return result
    }
}

struct QueueStorage {
    var fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tonkunst/queues.json")

    func load(account: String, token: String?) throws -> PlaybackQueue {
        try read()[account]?.authorizing(with: token) ?? PlaybackQueue()
    }

    func save(_ queue: PlaybackQueue, account: String) throws {
        var accounts = try read()
        accounts[account] = queue.authorizing(with: nil)
        let data = try JSONEncoder().encode(accounts)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func read() throws -> [String: PlaybackQueue] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        return try JSONDecoder().decode([String: PlaybackQueue].self, from: Data(contentsOf: fileURL))
    }
}
