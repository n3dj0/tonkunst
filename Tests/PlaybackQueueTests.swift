import Foundation

@main struct QueueTests {
    static func track(_ id: Int) -> MediaTrack {
        MediaTrack(id: String(id), title: "Song \(id)", artist: "Artist", album: "Album", duration: 60, fileExtension: "mp3")
    }
    static func main() {
        var queue = PlaybackQueue()
        assert(queue.advance(repeatMode: .off, afterFinishing: false, canPlay: { _ in true }) == nil)
        for i in 0..<1000 { assert(queue.add(track(i))) }
        assert(!queue.add(track(1000)))
        let first = queue.advance(repeatMode: .off, afterFinishing: false, canPlay: { _ in true })!
        assert(first.track.id == "0" && queue.upcoming.count == 999)
        assert(queue.add(track(0)))
        assert(queue.previous(canPlay: { _ in true }) == nil)
        for _ in 0..<110 { _ = queue.advance(repeatMode: .off, afterFinishing: false, canPlay: { _ in true }) }
        assert(queue.history.count == 100 && queue.history.first?.track.id == "109")
        assert(queue.history.last?.track.id == "10")
        let current = queue.current!
        assert(queue.advance(repeatMode: .one, afterFinishing: true, canPlay: { _ in true })?.id == current.id)
        assert(queue.history.count == 100)
        assert(queue.advance(repeatMode: .one, afterFinishing: false, canPlay: { _ in true })?.id != current.id)
        assert(queue.previous(canPlay: { _ in true })?.id == current.id)
        let last = queue.upcoming.last!
        assert(queue.playNext(last.id) && queue.upcoming.first?.id == last.id)
        queue.move(last.id, up: true)
        assert(queue.upcoming[1].id == last.id)
        queue.move(last.id, up: false)
        assert(queue.upcoming.first?.id == last.id)
        queue.remove(last.id)
        assert(!queue.upcoming.contains { $0.id == last.id })
        assert(queue.playNext(current.id))
        assert(queue.upcoming.first?.track.id == current.track.id && queue.upcoming.first?.id != current.id)
        let ids = Set(queue.upcoming.map(\.id))
        queue.shuffle()
        assert(ids == Set(queue.upcoming.map(\.id)))
        queue = PlaybackQueue()
        queue.start(QueueEntry(track: track(1)))
        assert(queue.advance(repeatMode: .off, afterFinishing: true, canPlay: { _ in true }) == nil)
        assert(queue.advance(repeatMode: .all, afterFinishing: true, canPlay: { _ in true })?.track.id == "1")
        queue.remove(queue.current!.id)
        assert(queue.current == nil)
        queue = PlaybackQueue()
        assert(queue.add(track(1)) && queue.add(track(2)))
        assert(queue.advance(repeatMode: .off, afterFinishing: true, canPlay: { $0.id == "2" })?.track.id == "2")
        assert(queue.upcoming.first?.track.id == "1" && queue.history.isEmpty)
        assert(queue.advance(repeatMode: .all, afterFinishing: true, canPlay: { _ in false }) == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = QueueStorage(fileURL: directory.appendingPathComponent("queues.json"))
        var saved = PlaybackQueue()
        var song = track(7)
        song.streamURL = URL(string: "https://music.example/Audio/7/universal?api_key=secret-token")
        saved.start(QueueEntry(track: song))
        saved.start(QueueEntry(track: track(8)))
        assert(saved.add(song) && saved.add(song))
        do {
            try storage.save(saved, account: "account-a")
            try storage.save(PlaybackQueue(), account: "account-b")
            let restored = try storage.load(account: "account-a", token: "new-token")
            assert(restored.current?.id == saved.current?.id)
            assert(restored.history.map(\.id) == saved.history.map(\.id))
            assert(restored.upcoming.map(\.id) == saved.upcoming.map(\.id))
            assert(restored.upcoming[0].track.streamURL!.absoluteString.contains("api_key=new-token"))
            let json = try String(contentsOf: storage.fileURL, encoding: .utf8)
            assert(!json.contains("secret-token") && !json.contains("new-token"))
            let other = try storage.load(account: "account-b", token: nil)
            assert(other.current == nil && other.upcoming.isEmpty)
            var edited = restored
            edited.remove(edited.upcoming[0].id)
            try storage.save(edited, account: "account-a")
            let reread = try storage.load(account: "account-a", token: nil)
            assert(reread.upcoming.count == 1)
            try Data("invalid archive".utf8).write(to: storage.fileURL)
            do { try storage.save(saved, account: "account-a"); assertionFailure("Corrupt data must not be overwritten") }
            catch { }
        } catch { fatalError("Persistence test failed: \(error)") }
        print("Queue persistence tests passed: restoration, occurrence identities, account isolation, edits, credential stripping and corrupt storage.")
        print("Queue tests passed: limits, history, duplicates, ordering, removal, shuffle, repeat and unavailable songs.")
    }
}
