import Foundation
import Testing
@testable import TonkunstCore

struct QueueRepositoryTests {
    @Test func corruptArchiveIsBackedUpAndSubsequentSavesWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queues.json")
        let invalid = Data("damaged archive".utf8)
        try invalid.write(to: url)
        let repository = QueueRepository(storage: QueueStorage(fileURL: url))
        let restored = try await repository.load(account: testProfile().id, profile: testProfile())
        #expect(restored.queue.current == nil)
        let backup = try #require(restored.recoveredArchive)
        #expect(try Data(contentsOf: backup) == invalid)
        var queue = PlaybackQueue()
        queue.start(QueueEntry(track: testTrack()))
        try await repository.save(queue, account: testProfile().id)
        let nextLaunch = QueueRepository(storage: QueueStorage(fileURL: url))
        let next = try await nextLaunch.load(account: testProfile().id, profile: testProfile())
        #expect(next.queue.current?.id == queue.current?.id)
        #expect(next.recoveredArchive == nil)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("secret"))
    }

    @Test func accountAuthorizationNeverAddsTokensToForeignURLs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = QueueRepository(storage: QueueStorage(fileURL: root.appendingPathComponent("queues.json")))
        var queue = PlaybackQueue()
        var foreign = testTrack()
        foreign.accountID = "https://another.example|another-user"
        queue.start(QueueEntry(track: foreign))
        try await repository.save(queue, account: testProfile().id)
        let restored = try await repository.load(account: testProfile().id, profile: testProfile())
        #expect(restored.queue.current?.track.streamURL?.query == nil)
        #expect(restored.queue.current?.track.belongs(to: testProfile()) == false)
        var own = testTrack()
        own.artworkURL = URL(string: "https://foreign.example/art?api_key=old")
        let authorized = own.authorizing(for: testProfile())
        #expect(authorized.artworkURL?.query == nil)
    }
}
