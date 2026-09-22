import Foundation
import Combine

struct PlaylistHTTPError: LocalizedError {
    let status: Int
    var errorDescription: String? {
        switch status {
        case 401: return "Sign in again to sync playlists."
        case 403: return "Your Jellyfin account cannot edit this playlist."
        default: return "Playlist sync failed (HTTP \(status)). Your device changes are saved."
        }
    }
}

struct PlaylistContent: Codable, Equatable {
    var name: String
    var tracks: [MediaTrack]

    // Stream URLs and metadata can change without changing the playlist.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.tracks.map(\.id) == rhs.tracks.map(\.id)
    }
}

struct RemotePlaylist {
    var id: String
    var content: PlaylistContent
}

struct SavedPlaylist: Codable, Identifiable {
    var id = UUID()
    var serverID: String?
    var content: PlaylistContent
    var baseline: PlaylistContent?
    var deleted = false
    var conflict = false
    var remote: PlaylistContent?
    // A create request cannot safely be automatically retried after a lost response.
    var creationUncertain = false
    var dirty: Bool { serverID == nil || deleted || content != baseline }

    mutating func reconcile(_ latest: PlaylistContent?) {
        remote = latest
        if dirty {
            if !deleted && latest == content {
                baseline = latest
                conflict = false
            } else {
                conflict = latest != baseline
            }
        } else if let latest {
            content = latest
            baseline = latest
            conflict = false
        }
    }
}

protocol PlaylistRemoteServing {
    func fetchPlaylists(profile: ServerProfile) async throws -> [RemotePlaylist]
    func savePlaylist(profile: ServerProfile, id: String?, content: PlaylistContent) async throws -> String
    func deletePlaylist(profile: ServerProfile, id: String) async throws
}

@MainActor
final class PlaylistLibrary: ObservableObject {
    @Published private(set) var playlists: [SavedPlaylist] = []
    @Published private(set) var catalog: [MediaTrack] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var message: String?
    private struct Archive: Codable {
        var accounts: [String: [SavedPlaylist]] = [:]
        var catalogs: [String: [MediaTrack]] = [:]
    }
    private var archive = Archive()
    private var accounts: [String: [SavedPlaylist]] { archive.accounts }
    private var accountID: String?
    private var storageAvailable = true
    private let api: any PlaylistRemoteServing
    private let fileURL: URL

    init(fileURL: URL? = nil, api: any PlaylistRemoteServing = JellyfinAPI()) {
        self.api = api
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tonkunst/playlists.json")
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: self.fileURL))
            }
        } catch {
            storageAvailable = false
            message = "Saved playlists could not be read. \(error.localizedDescription)"
        }
    }

    func activate(_ profile: ServerProfile?) {
        accountID = profile?.id
        if let profile {
            archive.accounts[profile.id] = (accounts[profile.id] ?? []).map { authorized($0, token: profile.accessToken) }
            archive.catalogs[profile.id] = (archive.catalogs[profile.id] ?? []).map { authorized($0, token: profile.accessToken) }
        }
        playlists = accountID.flatMap { accounts[$0] } ?? []
        catalog = accountID.flatMap { archive.catalogs[$0] } ?? []
        if storageAvailable { message = nil }
    }

    @discardableResult
    private func commit(_ values: [SavedPlaylist], account: String) -> Bool {
        guard storageAvailable else { return false }
        var updated = archive
        updated.accounts[account] = values
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var onDisk = updated
            onDisk.accounts = updated.accounts.mapValues { $0.map { authorized($0, token: nil) } }
            onDisk.catalogs = updated.catalogs.mapValues { $0.map { authorized($0, token: nil) } }
            try JSONEncoder().encode(onDisk).write(to: fileURL, options: .atomic)
            archive = updated
            if accountID == account { playlists = values }
            return true
        } catch {
            message = "Playlists could not be saved on this device. \(error.localizedDescription)"
            return false
        }
    }

    // Keep access tokens in Keychain, not the playlist cache. Rehydrate URLs
    // with the active account's current token after loading or signing in again.
    private func authorized(_ track: MediaTrack, token: String?) -> MediaTrack {
        func url(_ url: URL?) -> URL? {
            guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            var query = (parts.queryItems ?? []).filter { $0.name.lowercased() != "api_key" }
            if let token { query.append(URLQueryItem(name: "api_key", value: token)) }
            parts.queryItems = query.isEmpty ? nil : query
            return parts.url
        }
        var track = track
        track.streamURL = url(track.streamURL)
        track.fallbackStreamURL = url(track.fallbackStreamURL)
        track.artworkURL = url(track.artworkURL)
        return track
    }

    private func authorized(_ playlist: SavedPlaylist, token: String?) -> SavedPlaylist {
        var playlist = playlist
        playlist.content.tracks = playlist.content.tracks.map { authorized($0, token: token) }
        if let baseline = playlist.baseline { playlist.baseline?.tracks = baseline.tracks.map { authorized($0, token: token) } }
        if let remote = playlist.remote { playlist.remote?.tracks = remote.tracks.map { authorized($0, token: token) } }
        return playlist
    }

    func cacheTracks(_ tracks: [MediaTrack], profile: ServerProfile) {
        guard accountID == profile.id else { return }
        let old = archive.catalogs[profile.id]
        archive.catalogs[profile.id] = tracks
        if commit(playlists, account: profile.id) { catalog = tracks }
        else { archive.catalogs[profile.id] = old }
    }

    func create(name: String) {
        guard !isSyncing, let accountID else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        _ = commit(playlists + [SavedPlaylist(content: PlaylistContent(name: name, tracks: []))], account: accountID)
    }

    func edit(_ id: UUID, content: PlaylistContent) {
        guard !isSyncing, let accountID, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var values = playlists
        var content = content
        content.name = content.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.name.isEmpty else { return }
        guard !values[index].conflict, !values[index].creationUncertain, !values[index].deleted else { return }
        values[index].content = content
        _ = commit(values, account: accountID)
    }

    func cancelDeletion(_ id: UUID) {
        guard !isSyncing, let accountID else { return }
        var values = playlists
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        values[index].deleted = false
        _ = commit(values, account: accountID)
    }

    func delete(_ id: UUID) {
        guard !isSyncing, let accountID else { return }
        var values = playlists
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        guard !values[index].conflict, !values[index].creationUncertain else { return }
        if values[index].serverID == nil { values.remove(at: index) }
        else { values[index].deleted = true }
        _ = commit(values, account: accountID)
    }

    /// Keep the server version, optionally retaining local edits as a new private playlist.
    func resolve(_ id: UUID, keepCopy: Bool) {
        guard !isSyncing, let accountID else { return }
        var values = playlists
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        let old = values.remove(at: index)
        if keepCopy {
            var content = old.content
            content.name += " (device copy)"
            values.append(SavedPlaylist(content: content))
        }
        if let remote = old.remote, let serverID = old.serverID {
            values.append(SavedPlaylist(id: old.id, serverID: serverID, content: remote, baseline: remote))
        }
        _ = commit(values, account: accountID)
    }

    func retryCreation(_ id: UUID) {
        guard !isSyncing, let accountID else { return }
        var values = playlists
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        values[index].creationUncertain = false
        _ = commit(values, account: accountID)
    }

    func sync(profile: ServerProfile, isConnected: () -> Bool) async {
        guard !isSyncing, storageAvailable, accountID == profile.id, isConnected() else { return }
        isSyncing = true
        message = nil
        defer { isSyncing = false }
        let account = profile.id
        do {
            let remote = try await api.fetchPlaylists(profile: profile)
            guard accountID == account, isConnected() else { return }
            var values = accounts[account] ?? []
            let knownIDs = Set(values.compactMap(\.serverID))
            for index in values.indices {
                if let serverID = values[index].serverID {
                    values[index].reconcile(remote.first { $0.id == serverID }?.content)
                }
            }
            values.removeAll { item in
                item.serverID != nil && !remote.contains { $0.id == item.serverID } && (!item.dirty || item.deleted)
            }
            for item in remote where !knownIDs.contains(item.id) {
                values.append(SavedPlaylist(serverID: item.id, content: item.content, baseline: item.content))
            }
            guard commit(values, account: account) else { return }
            for id in values.map(\.id) {
                guard accountID == account, isConnected() else { return }
                guard let index = values.firstIndex(where: { $0.id == id }) else { continue }
                var item = values[index]
                guard item.dirty, !item.conflict, !item.creationUncertain else { continue }
                do {
                    if item.deleted, let serverID = item.serverID {
                        try await api.deletePlaylist(profile: profile, id: serverID)
                        values.remove(at: index)
                    } else {
                        if item.serverID == nil {
                            item.creationUncertain = true
                            values[index] = item
                            guard commit(values, account: account) else { return }
                        }
                        let serverID = try await api.savePlaylist(profile: profile, id: item.serverID, content: item.content)
                        item.serverID = serverID
                        item.baseline = item.content
                        item.creationUncertain = false
                        values[index] = item
                    }
                    guard commit(values, account: account) else { return }
                } catch {
                    // A definitive HTTP rejection did not create anything; transport errors may have.
                    if let http = error as? PlaylistHTTPError, (400..<500).contains(http.status) {
                        values[index].creationUncertain = false
                        guard commit(values, account: account) else { return }
                    }
                    if accountID == account { message = error.localizedDescription }
                }
            }
        } catch {
            if accountID == account { message = error.localizedDescription }
        }
    }
}
