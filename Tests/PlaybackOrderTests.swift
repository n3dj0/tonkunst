// Run with Tests/run-playback-tests.sh. No audio device or server required.
@main struct PlaybackOrderTests {
    static func main() {
        var order = PlaybackOrder()
        assert(order.advance(repeatMode: .all) == nil)
        assert(order.previous(repeatMode: .all) == nil)

        order.reset(count: 3, startingAt: 1, shuffled: false)
        assert(order.currentIndex == 1)
        assert(order.advance(repeatMode: .off, afterFinishing: true) == 2)
        assert(order.advance(repeatMode: .off, afterFinishing: true) == nil)
        assert(order.currentIndex == 2)
        assert(order.advance(repeatMode: .all, afterFinishing: true) == 0)
        assert(order.previous(repeatMode: .all) == 2)

        order.reset(count: 3, startingAt: 0, shuffled: false)
        assert(order.previous(repeatMode: .off) == nil)
        assert(order.advance(repeatMode: .one, afterFinishing: true) == 0)
        assert(order.advance(repeatMode: .one) == 1, "Next must skip even with Repeat One")
        assert(order.advance(repeatMode: .one, afterFinishing: true) == 1)
        assert(order.previous(repeatMode: .one) == 0)

        // Exercise many random orders, checking invariants instead of a lucky permutation.
        for _ in 0..<100 {
            order.reset(count: 8, startingAt: 3, shuffled: true)
            var played = [order.currentIndex!]
            while let index = order.advance(repeatMode: .off, afterFinishing: true) {
                played.append(index)
                assert(played.count <= 8, "Shuffle with Repeat Off must end")
            }
            assert(played.first == 3 && Set(played) == Set(0..<8))
            assert(played.count == 8, "Every queue occurrence must play exactly once")
            for index in played.dropLast().reversed() {
                assert(order.previous(repeatMode: .off) == index, "Previous must retrace shuffled playback")
            }
            assert(order.previous(repeatMode: .off) == nil)
            assert(order.previous(repeatMode: .all) == played.last)
            assert(order.advance(repeatMode: .all, afterFinishing: true) == played.first)
            assert(order.advance(repeatMode: .one, afterFinishing: true) == played.first)
            assert(order.advance(repeatMode: .one) == played[1])
            let current = order.currentIndex!
            order.setShuffled(false)
            assert(order.currentIndex == current, "Turning shuffle off must retain the current occurrence")
            assert(order.advance(repeatMode: .all) == (current + 1) % 8)
            let beforeShuffle = order.currentIndex!
            order.setShuffled(true)
            assert(order.currentIndex == beforeShuffle)
            var remaining = [beforeShuffle]
            while let index = order.advance(repeatMode: .off) { remaining.append(index) }
            assert(remaining.count == 8 && Set(remaining).count == 8)
        }

        // A one-song queue must stop unless a repeat mode explicitly asks to replay.
        for shuffled in [false, true] {
            order.reset(count: 1, startingAt: 0, shuffled: shuffled)
            assert(order.advance(repeatMode: .off, afterFinishing: true) == nil)
            assert(order.advance(repeatMode: .one, afterFinishing: true) == 0)
            assert(order.advance(repeatMode: .all, afterFinishing: true) == 0)
            assert(order.advance(repeatMode: .one) == nil)
        }

        order.reset(count: 0, startingAt: 0, shuffled: true)
        assert(order.currentIndex == nil)
        order.reset(count: 2, startingAt: 5, shuffled: false)
        assert(order.currentIndex == nil)

        var mode = PlaybackRepeatMode.off
        mode = mode.next; assert(mode == .all)
        mode = mode.next; assert(mode == .one)
        mode = mode.next; assert(mode == .off)
        print("Playback tests passed: shuffle traversal/history, mode changes, repeat modes, manual skips, queue boundaries, and empty/single-song queues.")
    }
}
