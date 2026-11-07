import Foundation
import Testing
@testable import TonkunstCore

struct LibrarySearchTests {
    @Test(arguments: ["SONATA", "bAcH", "KEYBOARD"])
    func searchesTitleArtistAndAlbumIgnoringCase(_ query: String) async throws {
        var track = testTrack()
        track.title = "Violin Sonata"
        track.artist = "Johann Sebastian Bach"
        track.album = "Keyboard Works"
        let results = try await LibrarySearch.results(for: query, in: [testTrack("other"), track])
        #expect(results == [track])
    }

    @Test func preservesLibraryOrderAndMetadata() async throws {
        var first = testTrack("z")
        first.album = "First Album"
        var last = testTrack("a")
        last.album = "Last Album"
        let results = try await LibrarySearch.results(for: "song", in: [first, last])
        #expect(results == [first, last])
    }

    @Test func emptyAndUnmatchedQueriesReturnNoSongs() async throws {
        let empty = try await LibrarySearch.results(for: "", in: [testTrack()])
        let unmatched = try await LibrarySearch.results(for: "missing", in: [testTrack()])
        #expect(empty.isEmpty)
        #expect(unmatched.isEmpty)
    }

    @Test @MainActor func cancellationPropagatesFromMainActor() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LibrarySearch.results(for: "song", in: [testTrack()])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
