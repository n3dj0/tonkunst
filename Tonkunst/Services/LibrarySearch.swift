import Foundation

enum LibrarySearch {
    /// Always scan on the concurrent executor, even when called by a SwiftUI
    /// task on MainActor. Cancellation propagates from the caller's task.
    @concurrent
    static func results(for query: String, in tracks: [MediaTrack]) async throws -> [MediaTrack] {
        try Task.checkCancellation()
        guard !query.isEmpty else { return [] }
        var results: [MediaTrack] = []
        for track in tracks {
            try Task.checkCancellation()
            if track.title.localizedCaseInsensitiveContains(query) ||
                track.artist.localizedCaseInsensitiveContains(query) ||
                track.album.localizedCaseInsensitiveContains(query) {
                results.append(track)
            }
        }
        return results
    }
}
