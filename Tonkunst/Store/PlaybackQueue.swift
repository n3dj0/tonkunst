import Foundation

enum PlaybackRepeatMode: String, Sendable {
    case off, all, one

    var next: Self { self == .off ? .all : (self == .all ? .one : .off) }
    var accessibilityValue: String {
        switch self {
        case .off: return String(localized: "Off", bundle: AppLocalization.bundle)
        case .all: return String(localized: "All songs", bundle: AppLocalization.bundle)
        case .one: return String(localized: "One song", bundle: AppLocalization.bundle)
        }
    }
}

// Each occurrence has its own identity, including repeated songs.
struct QueueEntry: Identifiable, Codable, Sendable {
    var id = UUID()
    var track: MediaTrack
}

struct PlaybackQueue: Codable, Sendable {
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

    mutating func select(_ id: UUID, canPlay: (MediaTrack) -> Bool) -> QueueEntry? {
        guard let entry = (history + upcoming + (current.map { [$0] } ?? [])).first(where: { $0.id == id }),
              canPlay(entry.track) else { return nil }
        if current?.id != id {
            history.removeAll { $0.id == id }
            upcoming.removeAll { $0.id == id }
            start(entry)
        }
        return entry
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
            value.track = value.track.authorizing(with: token)
            return value
        }
        var result = self
        result.history = history.prefix(Self.historyLimit).map(entry)
        result.current = current.map(entry)
        result.upcoming = upcoming.prefix(Self.upcomingLimit).map(entry)
        return result
    }
}

struct QueueStorage: Sendable {
    var fileURL: URL = URL.applicationSupportDirectory
        .appendingPathComponent("Tonkunst/queues.json")

    func load(account: String, token: String?) throws -> PlaybackQueue {
        try read()[account]?.authorizing(with: token) ?? PlaybackQueue()
    }

    func save(_ queue: PlaybackQueue, account: String) throws {
        var accounts = try read()
        accounts[account] = queue.authorizing(with: nil)
        try write(accounts)
    }

    fileprivate func write(_ accounts: [String: PlaybackQueue]) throws {
        let data = try JSONEncoder().encode(accounts.mapValues { $0.authorizing(with: nil) })
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    fileprivate func read() throws -> [String: PlaybackQueue] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        return try JSONDecoder().decode([String: PlaybackQueue].self, from: Data(contentsOf: fileURL))
    }
}

/// Owns the archive and serializes writes outside the main actor. The store
/// chains save tasks; loading waits for those tasks before changing accounts.
actor QueueRepository {
    struct Restoration: Sendable {
        let queue: PlaybackQueue
        let recoveredArchive: URL?
    }
    private let storage: QueueStorage
    private var accounts: [String: PlaybackQueue]?
    private var recoveredArchive: URL?

    init(storage: QueueStorage = QueueStorage()) { self.storage = storage }

    func load(account: String, profile: ServerProfile?) throws -> Restoration {
        try prepare()
        let stored = accounts?[account] ?? PlaybackQueue()
        // Apply account-aware authorization to all retained occurrences.
        let object = stored.authorizing(with: nil).mappingTracks { $0.authorizing(for: profile) }
        let result = Restoration(queue: object, recoveredArchive: recoveredArchive)
        recoveredArchive = nil
        return result
    }

    func save(_ queue: PlaybackQueue, account: String) throws {
        try prepare()
        var updated = accounts ?? [:]
        updated[account] = queue.authorizing(with: nil)
        try storage.write(updated)
        accounts = updated
    }

    private func prepare() throws {
        guard accounts == nil else { return }
        do { accounts = try storage.read() }
        catch is DecodingError {
            let backup = storage.fileURL.deletingLastPathComponent()
                .appendingPathComponent("queues.corrupt-\(UUID().uuidString).json")
            // Never discard a corrupt archive or mask a filesystem failure.
            try FileManager.default.moveItem(at: storage.fileURL, to: backup)
            recoveredArchive = backup
            accounts = [:]
        }
    }
}

extension PlaybackQueue {
    func mappingTracks(_ transform: (MediaTrack) -> MediaTrack) -> Self {
        var result = self
        func entry(_ value: QueueEntry) -> QueueEntry {
            var value = value
            value.track = transform(value.track)
            return value
        }
        result.history = history.map(entry)
        result.current = current.map(entry)
        result.upcoming = upcoming.map(entry)
        return result
    }
}
