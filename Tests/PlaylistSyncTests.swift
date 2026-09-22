// Run with Tests/run-playlist-tests.sh. No server or credentials required.
import Foundation

final class MockPlaylistAPI: PlaylistRemoteServing {
    var remote: [RemotePlaylist] = []
    var saves = 0
    var deletions = 0
    var failure: Error?
    var beforeSave: (() -> Void)?
    func fetchPlaylists(profile: ServerProfile) async throws -> [RemotePlaylist] { remote }
    func savePlaylist(profile: ServerProfile, id: String?, content: PlaylistContent) async throws -> String {
        saves += 1
        beforeSave?()
        if let failure { throw failure }
        let id = id ?? UUID().uuidString
        remote.removeAll { $0.id == id }
        remote.append(RemotePlaylist(id: id, content: content))
        return id
    }
    func deletePlaylist(profile: ServerProfile, id: String) async throws {
        if let failure { throw failure }
        deletions += 1
        remote.removeAll { $0.id == id }
    }
}

// The production HTTP implementation uses UIKit. This executable tests the real
// persistence/sync coordinator with a deterministic transport on macOS.
struct JellyfinAPI: PlaylistRemoteServing {
    func fetchPlaylists(profile: ServerProfile) async throws -> [RemotePlaylist] { fatalError() }
    func savePlaylist(profile: ServerProfile, id: String?, content: PlaylistContent) async throws -> String { fatalError() }
    func deletePlaylist(profile: ServerProfile, id: String) async throws { fatalError() }
}

@main struct PlaylistSyncTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("playlists.json")
        let api = MockPlaylistAPI()
        let profile = ServerProfile(baseURL: "https://example.test", userID: "a", accessToken: "test", displayName: "A")
        let other = ServerProfile(baseURL: "https://example.test", userID: "b", accessToken: "test", displayName: "B")
        let library = PlaylistLibrary(fileURL: file, api: api)
        library.activate(profile)
        library.create(name: "  Road trip  ")
        assert(library.playlists[0].content.name == "Road trip")
        let id = library.playlists[0].id
        await library.sync(profile: profile) { false }
        assert(api.saves == 0 && library.playlists[0].dirty)
        let restored = PlaylistLibrary(fileURL: file, api: api)
        restored.activate(profile)
        assert(restored.playlists[0].id == id && restored.playlists[0].dirty)
        await library.sync(profile: profile) { true }
        assert(api.saves == 1 && !library.playlists[0].dirty)
        await library.sync(profile: profile) { true }
        assert(api.saves == 1, "Repeated sync must not create duplicates")

        let track = MediaTrack(id: "song", title: "Song", artist: "Artist", album: "Album", duration: 1, streamURL: URL(string: "https://example.test/Audio/song/stream?api_key=secret-token"), fileExtension: "mp3")
        library.cacheTracks([track], profile: profile)
        let cachedJSON = try String(contentsOf: file, encoding: .utf8)
        assert(!cachedJSON.contains("secret-token"), "Playlist persistence must not store access tokens")
        var content = library.playlists[0].content
        content.tracks = [track, track]
        library.edit(id, content: content)
        await library.sync(profile: profile) { true }
        assert(api.remote[0].content.tracks.count == 2, "Duplicate occurrences must survive syncing")
        api.remote[0].content.name = "Server rename"
        await library.sync(profile: profile) { true }
        assert(library.playlists[0].content.name == "Server rename")

        content = library.playlists[0].content
        content.name = "Device rename"
        library.edit(id, content: content)
        api.remote[0].content.name = "Another server rename"
        let count = api.saves
        await library.sync(profile: profile) { true }
        assert(library.playlists[0].conflict && api.saves == count)
        library.resolve(id, keepCopy: true)
        assert(library.playlists.count == 2)
        await library.sync(profile: profile) { true }
        assert(api.remote.count == 2 && library.playlists.allSatisfy { !$0.dirty })

        library.activate(other)
        assert(library.playlists.isEmpty && library.catalog.isEmpty)
        library.create(name: "Other account")
        library.activate(profile)
        assert(library.playlists.count == 2 && library.catalog.count == 1)
        let reload = PlaylistLibrary(fileURL: file, api: api)
        reload.activate(profile)
        assert(reload.catalog.count == 1 && reload.playlists.count == 2)

        library.delete(id)
        api.remote.firstIndex { $0.id == library.playlists.first { $0.id == id }!.serverID }.map { api.remote[$0].content.name = "Changed before deletion" }
        await library.sync(profile: profile) { true }
        assert(library.playlists.first { $0.id == id }!.conflict && api.deletions == 0)
        library.resolve(id, keepCopy: false)
        library.delete(id)
        await library.sync(profile: profile) { true }
        assert(api.deletions == 1 && library.playlists.count == 1)

        // Remote deletion with local edits must preserve those edits for review.
        let remaining = library.playlists[0].id
        var edited = library.playlists[0].content
        edited.name = "Keep my edits"
        library.edit(remaining, content: edited)
        api.remote = []
        await library.sync(profile: profile) { true }
        assert(library.playlists[0].conflict && library.playlists[0].remote == nil)
        library.resolve(remaining, keepCopy: true)
        await library.sync(profile: profile) { true }
        api.remote = []
        await library.sync(profile: profile) { true }
        assert(library.playlists.isEmpty, "Unedited server deletions should propagate")

        library.create(name: "Uncertain")
        api.failure = URLError(.timedOut)
        await library.sync(profile: profile) { true }
        let attempts = api.saves
        assert(library.playlists[0].creationUncertain)
        let interrupted = PlaylistLibrary(fileURL: file, api: api)
        interrupted.activate(profile)
        await interrupted.sync(profile: profile) { true }
        assert(api.saves == attempts, "Lost create responses must not cause automatic duplicates after restart")
        library.retryCreation(library.playlists[0].id)
        api.failure = PlaylistHTTPError(status: 403)
        await library.sync(profile: profile) { true }
        assert(!library.playlists[0].creationUncertain && library.playlists[0].dirty)
        api.failure = nil
        api.beforeSave = { library.activate(other) }
        await library.sync(profile: profile) { true }
        assert(library.playlists.count == 1 && library.playlists[0].content.name == "Other account")
        library.activate(profile)
        assert(!library.playlists[0].dirty, "An in-flight acknowledgement must persist to its original account")

        let badFile = directory.appendingPathComponent("corrupt.json")
        try Data("broken".utf8).write(to: badFile)
        let corrupt = PlaylistLibrary(fileURL: badFile, api: api)
        corrupt.activate(profile)
        corrupt.create(name: "Must not overwrite")
        let preserved = try Data(contentsOf: badFile)
        assert(corrupt.message != nil && String(data: preserved, encoding: .utf8) == "broken")
        print("Playlist sync tests passed: persistence, offline queue, duplicates, pull/push, conflicts, deletion, account isolation, uncertain creation, and corrupt storage.")
    }
}
