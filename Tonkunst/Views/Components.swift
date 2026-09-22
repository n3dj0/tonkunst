import SwiftUI

struct Artwork: View {
    let track: MediaTrack?
    var size: CGFloat = 52
    var body: some View {
        Group { if let url = track?.artworkURL { AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { artworkFallback } } else { artworkFallback } }
            .frame(width: size, height: size)
            .clipShape(Rectangle())
    }
    private var artworkFallback: some View { Image("AppArtwork").resizable().scaledToFill() }
}

struct OfflineBadge: View { var body: some View { Image(systemName: "iphone.gen3").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityLabel("Available offline") } }

struct SongRow: View {
    @EnvironmentObject private var store: MusicStore
    let track: MediaTrack
    var body: some View {
        Button { store.play(track) } label: {
            HStack(spacing: 12) { Artwork(track: track, size: 48); VStack(alignment: .leading, spacing: 3) { Text(track.title).font(.body.weight(.medium)).lineLimit(1); Text("\(track.artist) · \(track.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if store.offline.contains(track) { OfflineBadge() }; Text(track.formattedDuration).font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
        }.buttonStyle(.plain).contextMenu { Button(store.offline.contains(track) ? "Remove Download" : "Download for Offline", systemImage: store.offline.contains(track) ? "trash" : "arrow.down.circle") { Task { await store.toggleDownload(track) } } }
    }
}

struct ConnectionPill: View {
    @EnvironmentObject private var store: MusicStore
    var body: some View { Label(store.listenStatus, systemImage: store.connectionAvailable ? "wifi" : "iphone.gen3").font(.caption.weight(.medium)).foregroundStyle(store.connectionAvailable ? Color.accentColor : .orange).padding(.horizontal, 10).padding(.vertical, 6).background(.thinMaterial, in: Capsule()) }
}
