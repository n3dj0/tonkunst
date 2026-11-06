import AVFoundation
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class OfflineLibrary {
    typealias Download = @Sendable (URL) async throws -> (URL, URLResponse)
    private var records: [String: OfflineRecord] = [:]
    private var activeProfile: ServerProfile?
    private var generation = 0
    private var revision = -1
    private var pendingDownloads: [String: Set<String>] = [:]
    private let defaults: UserDefaults
    private let downloadFile: Download
    private let repository: OfflineRepository
    private(set) var unassignedDownloadCount = 0

    var downloaded: [String: URL] { records.mapValues(\.url) }
    var savedTracks: [String: MediaTrack] { records.mapValues(\.track) }
    var downloading: Set<String> { activeProfile.flatMap { pendingDownloads[$0.id] } ?? [] }
    var tracks: [MediaTrack] {
        records.values.map { $0.track.authorizing(for: activeProfile) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    init(documentsRoot: URL? = nil, defaults: UserDefaults = .standard,
         profile: ServerProfile? = nil, manifestURL: URL? = nil,
         download: @escaping Download = { try await URLSession.shared.download(from: $0) }) {
        self.defaults = defaults
        self.downloadFile = download
        self.activeProfile = profile
        repository = OfflineRepository(documentsRoot: documentsRoot, manifestURL: manifestURL)
    }

    func selectAccount(_ profile: ServerProfile?) {
        generation += 1
        revision = -1
        records = [:]
        activeProfile = profile
    }

    func localURL(for track: MediaTrack) -> URL? {
        guard track.belongs(to: activeProfile) else { return nil }
        return records[track.id]?.url
    }
    func contains(_ track: MediaTrack) -> Bool { localURL(for: track) != nil }

    func restore() async throws {
        let generation = generation
        let snapshot = try await repository.restore(account: activeProfile?.id,
            legacyPaths: defaults.dictionary(forKey: "offlineTrackManifest") as? [String: String] ?? [:],
            legacyMetadata: defaults.data(forKey: "offlineTrackMetadata"))
        // Remove old plaintext values only after the new atomic archive is durable.
        defaults.removeObject(forKey: "offlineTrackManifest")
        defaults.removeObject(forKey: "offlineTrackMetadata")
        apply(snapshot, generation: generation)
    }

    func download(_ track: MediaTrack) async throws {
        guard let profile = activeProfile, track.belongs(to: profile) else { throw OfflineAudioError.accountRequired }
        let account = profile.id
        guard pendingDownloads[account, default: []].insert(track.id).inserted else { return }
        defer { pendingDownloads[account]?.remove(track.id) }
        let generation = generation
        try Task.checkCancellation()
        guard let url = track.fallbackStreamURL ?? track.streamURL else { throw JellyfinError.badResponse }
        let staged: (url: URL, fileExtension: String)
        do {
            staged = try await playableDownload(from: url, suggestedExtension: track.fileExtension)
        } catch OfflineAudioError.unsupportedFormat {
            guard let transcoded = transcodedMP3URL(from: track.fallbackStreamURL ?? url) else { throw OfflineAudioError.unsupportedFormat }
            staged = try await playableDownload(from: transcoded, suggestedExtension: "mp3")
        }
        // The repository consumes and cleans the staging file even if persistence fails.
        let snapshot = try await repository.commit(staged.url, extension: staged.fileExtension, track: track, account: account)
        apply(snapshot, generation: generation)
    }

    func remove(_ track: MediaTrack) async throws {
        guard let profile = activeProfile, track.belongs(to: profile) else { throw OfflineAudioError.accountRequired }
        let generation = generation
        let snapshot = try await repository.remove(track.id, account: profile.id)
        apply(snapshot, generation: generation)
    }

    func reconcile(with tracks: [MediaTrack]) async throws {
        guard let profile = activeProfile else { return }
        let generation = generation
        let snapshot = try await repository.reconcile(tracks.filter { $0.belongs(to: profile) }, account: profile.id)
        apply(snapshot, generation: generation)
    }

    private func apply(_ snapshot: OfflineSnapshot, generation: Int) {
        guard generation == self.generation, snapshot.revision >= revision else { return }
        records = snapshot.records
        unassignedDownloadCount = snapshot.unassignedCount
        revision = snapshot.revision
    }

    private nonisolated func playableDownload(from url: URL, suggestedExtension: String) async throws -> (url: URL, fileExtension: String) {
        let (temporaryURL, response) = try await downloadFile(url)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw JellyfinError.unavailable }
        let files = OfflineFiles(documentsRoot: nil)
        guard !files.isHLSPlaylist(at: temporaryURL) else { throw OfflineAudioError.unsupportedFormat }
        let known: Set<String> = ["m4a", "mp3", "flac", "aac", "ogg", "opus", "wav", "aiff", "caf"]
        let ext = files.detectedAudioExtension(at: temporaryURL) ?? (known.contains(suggestedExtension.lowercased()) ? suggestedExtension.lowercased() : "m4a")
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("tonkunst-\(UUID().uuidString).\(ext)")
        try FileManager.default.moveItem(at: temporaryURL, to: staged)
        do {
            let asset = AVURLAsset(url: staged)
            guard try await asset.load(.isPlayable), try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw OfflineAudioError.unsupportedFormat }
            try Task.checkCancellation()
            return (staged, ext)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw OfflineAudioError.unsupportedFormat
        }
    }

    private func transcodedMP3URL(from url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.path.hasSuffix("/stream") else { return nil }
        parts.path += ".mp3"
        parts.queryItems = (parts.queryItems ?? []).filter {
            !["static", "container", "audiocodec", "audiobitrate", "maxaudiochannels"].contains($0.name.lowercased())
        } + [URLQueryItem(name: "Static", value: "false"), URLQueryItem(name: "Container", value: "mp3"),
             URLQueryItem(name: "AudioCodec", value: "mp3"), URLQueryItem(name: "AudioBitRate", value: "320000"),
             URLQueryItem(name: "MaxAudioChannels", value: "2")]
        return parts.url
    }
}

enum OfflineAudioError: LocalizedError {
    case unsupportedFormat, accountRequired
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: String(localized: "Jellyfin returned audio that this device cannot play offline.", bundle: AppLocalization.bundle)
        case .accountRequired: String(localized: "Choose the account that owns this song to manage its download.", bundle: AppLocalization.bundle)
        }
    }
}

private struct OfflineRecord: Codable, Sendable {
    var url: URL
    var track: MediaTrack
    var relativePath: String? = nil
}

private struct OfflineSnapshot: Sendable {
    let records: [String: OfflineRecord]
    let unassignedCount: Int
    let revision: Int
}

/// No method suspends during a filesystem transaction. All mutations, JSON
/// encoding and file validation are serialized away from the UI actor.
private actor OfflineRepository {
    private struct Archive: Codable {
        var accounts: [String: [String: OfflineRecord]] = [:]
        var unassigned: [String: OfflineRecord] = [:]
        var migratedLegacy = false
    }
    private let files: OfflineFiles
    private let manifestURL: URL
    private var archive: Archive?
    private var revision = 0

    init(documentsRoot: URL?, manifestURL: URL?) {
        files = OfflineFiles(documentsRoot: documentsRoot)
        self.manifestURL = manifestURL ?? (documentsRoot ?? URL.applicationSupportDirectory.appendingPathComponent("Tonkunst"))
            .appendingPathComponent("offline-library.json")
    }

    func restore(account: String?, legacyPaths: [String: String], legacyMetadata: Data?) throws -> OfflineSnapshot {
        try prepare()
        guard var updated = archive else { throw CocoaError(.fileReadCorruptFile) }
        var migrationCopies: [(source: URL, destination: URL)] = []
        do {
            if !updated.migratedLegacy {
                let metadata = try legacyMetadata.map { try JSONDecoder().decode([String: MediaTrack].self, from: $0) } ?? [:]
                for (id, path) in legacyPaths {
                    guard let url = files.resolvedURL(for: path), !files.isHLSPlaylist(at: url) else { continue }
                    var track = metadata[id] ?? MediaTrack(id: id,
                        title: String(localized: "Unknown Song", bundle: AppLocalization.bundle),
                        artist: String(localized: "Unknown Artist", bundle: AppLocalization.bundle),
                        album: String(localized: "Unknown Album", bundle: AppLocalization.bundle),
                        duration: 0, fileExtension: url.pathExtension)
                    let owner = track.sourceAccountID
                    track = track.authorizing(with: nil)
                    track.accountID = owner
                    let ext = files.detectedAudioExtension(at: url) ?? url.pathExtension
                    track.fileExtension = ext
                    var destination = url
                    if let owner {
                        let target = try files.destination(for: track, id: id, account: owner, fileExtension: ext)
                        if target != url, !FileManager.default.fileExists(atPath: target.path) {
                            // Copy first. Old paths remain valid until the archive is durable.
                            try FileManager.default.copyItem(at: url, to: target)
                            migrationCopies.append((url, target))
                            destination = target
                        }
                    }
                    let record = OfflineRecord(url: destination, track: track)
                    if let owner { updated.accounts[owner, default: [:]][id] = record }
                    else { updated.unassigned[id] = record }
                }
                updated.migratedLegacy = true
            }
            // Resolve container changes and external Files deletions on restoration.
            if let account {
                var valid: [String: OfflineRecord] = [:]
                for (id, var record) in updated.accounts[account] ?? [:] {
                    let path = record.relativePath.map { "Documents/" + $0 } ?? record.url.path
                    guard let url = files.resolvedURL(for: path), !files.isHLSPlaylist(at: url) else { continue }
                    record.url = url
                    valid[id] = record
                }
                updated.accounts[account] = valid
            }
            try persist(updated)
        } catch {
            for copy in migrationCopies { try? FileManager.default.removeItem(at: copy.destination) }
            throw error
        }
        let retainedURLs = Set(updated.accounts.values.flatMap { $0.values.map(\.url) } + updated.unassigned.values.map(\.url))
        for copy in migrationCopies where !retainedURLs.contains(copy.source) {
            try? FileManager.default.removeItem(at: copy.source)
            files.removeEmptyFolders(startingAt: copy.source.deletingLastPathComponent())
        }
        return snapshot(account)
    }

    func commit(_ staged: URL, extension ext: String, track: MediaTrack, account: String) throws -> OfflineSnapshot {
        defer { try? FileManager.default.removeItem(at: staged) }
        try Task.checkCancellation()
        try prepare()
        guard var updated = archive else { throw CocoaError(.fileReadCorruptFile) }
        let destination = try files.destination(for: track, account: account, fileExtension: ext)
        let previous = updated.accounts[account]?[track.id]?.url
        var saved = track.authorizing(with: nil)
        saved.accountID = account
        saved.fileExtension = ext
        updated.accounts[account, default: [:]][track.id] = OfflineRecord(url: destination, track: saved)
        // Validate encoding before changing any owned audio.
        _ = try JSONEncoder().encode(updated)
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists {
            guard previous == destination else { throw CocoaError(.fileWriteFileExists) }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else { try FileManager.default.moveItem(at: staged, to: destination) }
        do { try persist(updated) }
        catch {
            if !exists { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
        if let previous, previous != destination {
            try? FileManager.default.removeItem(at: previous)
            files.removeEmptyFolders(startingAt: previous.deletingLastPathComponent())
        }
        return snapshot(account)
    }

    func remove(_ id: String, account: String) throws -> OfflineSnapshot {
        try prepare()
        guard var updated = archive else { throw CocoaError(.fileReadCorruptFile) }
        let url = updated.accounts[account]?[id]?.url
        // Stage the deletion so a failed manifest write can restore the audio.
        let tombstone = url?.deletingLastPathComponent().appendingPathComponent(".removed-\(UUID().uuidString)")
        var staged = false
        if let url, let tombstone {
            do { try FileManager.default.moveItem(at: url, to: tombstone); staged = true }
            catch CocoaError.fileNoSuchFile { }
        }
        updated.accounts[account]?.removeValue(forKey: id)
        do { try persist(updated) }
        catch {
            if staged, let url, let tombstone { try FileManager.default.moveItem(at: tombstone, to: url) }
            throw error
        }
        if staged, let tombstone { try FileManager.default.removeItem(at: tombstone) }
        if let url { files.removeEmptyFolders(startingAt: url.deletingLastPathComponent()) }
        return snapshot(account)
    }

    func reconcile(_ tracks: [MediaTrack], account: String) throws -> OfflineSnapshot {
        try prepare()
        guard var updated = archive else { throw CocoaError(.fileReadCorruptFile) }
        for track in tracks {
            guard var record = updated.accounts[account]?[track.id] else { continue }
            // Existing paths stay stable; changed tags update metadata only.
            var saved = track.authorizing(with: nil)
            saved.fileExtension = record.url.pathExtension
            record.track = saved
            updated.accounts[account]?[track.id] = record
        }
        try persist(updated)
        return snapshot(account)
    }

    private func prepare() throws {
        guard archive == nil else { return }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: manifestURL))
        } else { archive = Archive() }
    }

    private func persist(_ updated: Archive) throws {
        var updated = updated
        let root = try files.documentsDirectory().path + "/"
        for (account, records) in updated.accounts {
            for (id, var record) in records where record.url.path.hasPrefix(root) {
                record.relativePath = String(record.url.path.dropFirst(root.count))
                updated.accounts[account]?[id] = record
            }
        }
        for (id, var record) in updated.unassigned where record.url.path.hasPrefix(root) {
            record.relativePath = String(record.url.path.dropFirst(root.count))
            updated.unassigned[id] = record
        }
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: .atomic)
        archive = updated
        revision += 1
    }

    private func snapshot(_ account: String?) -> OfflineSnapshot {
        OfflineSnapshot(records: account.flatMap { archive?.accounts[$0] } ?? [:],
                        unassignedCount: archive?.unassigned.count ?? 0, revision: revision)
    }
}

private struct OfflineFiles: Sendable {
    let documentsRoot: URL?

    static func folderID(_ account: String) -> String {
        SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The Documents root is shown as "On My iPhone → Tonkunst" in Files.
    func documentsDirectory() throws -> URL {
        let root = try documentsRoot ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func destination(for track: MediaTrack?, id: String? = nil, account: String? = nil, fileExtension: String) throws -> URL {
        let artist = safeName(track?.artist ?? "Unknown Artist", fallback: "Unknown Artist", maxBytes: 100)
        let album = safeName(track?.album ?? "Unknown Album", fallback: "Unknown Album", maxBytes: 100)
        let title = safeName(track?.title ?? "Unknown Song", fallback: "Unknown Song", maxBytes: 100)
        let trackID = safeName(id ?? track?.id ?? "Track", fallback: "Track", maxBytes: 64)
        let ext = String(fileExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(10))
        let root = try documentsDirectory()
        let accountRoot = account.map { root.appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(Self.folderID($0), isDirectory: true) } ?? root
        let folder = accountRoot.appendingPathComponent(artist, isDirectory: true)
            .appendingPathComponent(album, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(title) [\(trackID)].\(ext.isEmpty ? "m4a" : ext)")
    }

    func safeName(_ name: String, fallback: String, maxBytes: Int) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let cleaned = name.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var result = ""
        for character in cleaned {
            guard result.utf8.count + String(character).utf8.count <= maxBytes else { break }
            result.append(character)
        }
        return result.isEmpty ? fallback : result
    }

    func removeEmptyFolders(startingAt folder: URL) {
        guard let root = try? documentsDirectory() else { return }
        var current = folder
        while current != root, current.path.hasPrefix(root.path + "/") {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: current.path), items.isEmpty else { return }
            try? FileManager.default.removeItem(at: current)
            current.deleteLastPathComponent()
        }
    }

    func detectedAudioExtension(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16) else { return nil }
        let bytes = [UInt8](data)
        if bytes.count >= 8, Array(bytes[4..<8]) == Array("ftyp".utf8) { return "m4a" }
        if data.starts(with: Data("fLaC".utf8)) { return "flac" }
        if data.starts(with: Data("OggS".utf8)) { return "ogg" }
        if bytes.count >= 2, bytes[0] == 0xff, (bytes[1] & 0xf6) == 0xf0 { return "aac" }
        if data.starts(with: Data("ID3".utf8)) || bytes.count >= 2 && bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0 { return "mp3" }
        if bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WAVE".utf8) { return "wav" }
        if data.starts(with: Data("caff".utf8)) { return "caf" }
        if bytes.count >= 12, Array(bytes[0..<4]) == Array("FORM".utf8), Array(bytes[8..<12]) == Array("AIFF".utf8) { return "aiff" }
        return nil
    }

    func resolvedURL(for storedPath: String) -> URL? {
        if storedPath.hasPrefix("Documents/"), let root = try? documentsDirectory() {
            let relative = String(storedPath.dropFirst("Documents/".count))
            let url = root.appendingPathComponent(relative)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        let oldURL = URL(fileURLWithPath: storedPath)
        if FileManager.default.fileExists(atPath: oldURL.path) { return oldURL }

        // Older manifests stored the complete sandbox path, whose container
        // identifier can change when iOS updates the app.
        guard oldURL.deletingLastPathComponent().lastPathComponent == "TonkunstDownloads",
              let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
        let currentURL = support.appendingPathComponent("TonkunstDownloads", isDirectory: true)
            .appendingPathComponent(oldURL.lastPathComponent)
        return FileManager.default.fileExists(atPath: currentURL.path) ? currentURL : nil
    }

    func isHLSPlaylist(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32),
              let header = String(data: data, encoding: .utf8) else { return false }
        return header.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
    }
}
