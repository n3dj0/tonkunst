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

// Queue indices identify occurrences, so duplicate songs in a playlist stay distinct.
struct PlaybackOrder {
    private var indices: [Int] = []
    private var position = 0
    private var shuffled = false

    var currentIndex: Int? { indices.isEmpty ? nil : indices[position] }

    mutating func reset(count: Int, startingAt index: Int, shuffled: Bool) {
        self.shuffled = shuffled
        guard (0..<count).contains(index) else { indices = []; position = 0; return }
        if shuffled {
            indices = [index] + (0..<count).filter { $0 != index }.shuffled()
            position = 0
        } else {
            indices = Array(0..<count)
            position = index
        }
    }

    mutating func setShuffled(_ enabled: Bool) {
        guard enabled != shuffled else { return }
        reset(count: indices.count, startingAt: currentIndex ?? 0, shuffled: enabled)
    }

    mutating func advance(repeatMode: PlaybackRepeatMode, afterFinishing: Bool = false) -> Int? {
        guard let currentIndex else { return nil }
        // Repeat One applies to natural completion; Next still skips the song.
        if afterFinishing && repeatMode == .one { return currentIndex }
        if position + 1 < indices.count {
            position += 1
        } else {
            guard repeatMode == .all else { return nil }
            position = 0
        }
        return self.currentIndex
    }

    mutating func previous(repeatMode: PlaybackRepeatMode) -> Int? {
        guard !indices.isEmpty else { return nil }
        if position > 0 { position -= 1 }
        else if repeatMode == .all { position = indices.count - 1 }
        else { return nil }
        return currentIndex
    }
}
