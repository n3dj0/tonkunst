import SwiftUI
import AVKit

struct MiniPlayer: View {
    @EnvironmentObject private var store: MusicStore
    @Binding var expanded: Bool
    var body: some View {
        if let track = store.currentTrack {
            Button { expanded = true } label: {
                HStack(spacing: 11) {
                    Artwork(track: track, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { store.previous() } label: { Image(systemName: "backward.fill") }.buttonStyle(.borderless)
                    Button { store.togglePlay() } label: { Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").font(.title3) }.buttonStyle(.borderless)
                    Button { store.next() } label: { Image(systemName: "forward.fill") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive())
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack(spacing: 24) {
                    if let track = store.currentTrack {
                        Artwork(
                            track: track,
                            size: max(0, min(proxy.size.width - 56, max(285, proxy.size.height * 0.42)))
                        )
                            .shadow(color: .black.opacity(0.23), radius: 20, y: 10)
                        VStack(spacing: 6) {
                            Text(track.title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                            Text(track.artist).foregroundStyle(.secondary)
                            Text(track.album).font(.subheadline).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 26)
                        VStack(spacing: 7) {
                            Slider(value: Binding(get: { store.progress }, set: { store.seek(to: $0) }), in: 0...max(store.playbackDuration, 1))
                            HStack {
                                Text(time(store.progress)); Spacer()
                                Text("-\(time(max(0, store.playbackDuration - store.progress)))")
                            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 26)
                        HStack(spacing: 16) {
                            Button { store.isShuffled.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(store.isShuffled ? Color.accentColor : .primary) }
                                .accessibilityLabel("Shuffle")
                            Button { store.skip(-15) } label: { Image(systemName: "gobackward.15") }
                                .accessibilityLabel("Back 15 seconds")
                            Button { store.previous() } label: { Image(systemName: "backward.fill").font(.title2) }
                                .accessibilityLabel("Previous track")
                            Button { store.togglePlay() } label: { Image(systemName: store.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64)) }
                                .accessibilityLabel(store.isPlaying ? "Pause" : "Play")
                            Button { store.next() } label: { Image(systemName: "forward.fill").font(.title2) }
                                .accessibilityLabel("Next track")
                            Button { store.skip(15) } label: { Image(systemName: "goforward.15") }
                                .accessibilityLabel("Forward 15 seconds")
                            Button { store.cycleRepeat() } label: { Image(systemName: store.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(store.repeatMode == .off ? .primary : Color.accentColor) }
                                .accessibilityLabel("Repeat")
                        }
                        .font(.title3)
                        .buttonStyle(.plain)
                    } else {
                        ContentUnavailableView("Nothing Playing", systemImage: "music.note")
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    RoutePickerView()
                        .frame(width: 30, height: 30)
                        .accessibilityLabel("AirPlay")
                    if let track = store.currentTrack {
                        Button { Task { await store.toggleDownload(track) } } label: {
                            Image(systemName: store.offline.contains(track) ? "iphone.gen3" : "arrow.down.circle")
                        }
                        .accessibilityLabel(store.offline.contains(track) ? "Downloaded" : "Download")
                    }
                }
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    private func time(_ value: Double) -> String { String(format: "%d:%02d", Int(value) / 60, Int(value) % 60) }
}

struct RoutePickerView: UIViewRepresentable { func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.prioritizesVideoDevices = false; return view }; func updateUIView(_ uiView: AVRoutePickerView, context: Context) {} }
