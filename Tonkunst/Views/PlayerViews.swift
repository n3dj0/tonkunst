import SwiftUI
import AVKit

struct MiniPlayer: View {
    @Environment(MusicStore.self) private var store
    @Binding var expanded: Bool
    var body: some View {
        if let track = store.currentTrack {
            HStack(spacing: 0) {
                Button { expanded = true } label: {
                    HStack(spacing: 11) {
                        Artwork(track: track, size: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Now Playing: \(track.title), \(track.artist)")
                .accessibilityHint("Opens playback controls")

                Button { store.previous() } label: {
                    Image(systemName: "backward.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Previous track")
                Button { store.togglePlay() } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel(store.isPlaying ? String(localized: "Pause", bundle: AppLocalization.bundle) : String(localized: "Play", bundle: AppLocalization.bundle))
                Button { store.next() } label: {
                    Image(systemName: "forward.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Next track")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 10)
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .tint(.primary)
            .glassEffect(.regular.interactive())
        }
    }
}

struct NowPlayingView: View {
    @Environment(MusicStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                        if let track = store.currentTrack {
                            Artwork(track: track, size: max(0, min(proxy.size.width - 56, max(160, min(360, proxy.size.height * 0.4)))))
                                .shadow(color: .black.opacity(0.23), radius: 20, y: 10)
                                .accessibilityHidden(true)
                            VStack(spacing: 6) {
                                Text(track.title).font(.title2.weight(.bold))
                                Text(track.artist).foregroundStyle(.secondary)
                                Text(track.album).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.center)
                            .accessibilityElement(children: .combine)
                            PlaybackPositionView()
                            transportControls
                        } else {
                            ContentUnavailableView("Nothing Playing", systemImage: "music.note")
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: max(0, proxy.size.height))
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    RoutePickerView().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
                    if let track = store.currentTrack {
                        Button { Task { await store.toggleDownload(track) } } label: {
                            Image(systemName: store.offline.contains(track) ? "iphone.gen3" : "arrow.down.circle")
                        }
                        .accessibilityLabel(store.offline.contains(track) ? String(localized: "Downloaded", bundle: AppLocalization.bundle) : String(localized: "Download", bundle: AppLocalization.bundle))
                        .disabled(store.offline.downloading.contains(track.id))
                    }
                }
            }
            .ambientScreen()
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var transportControls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 32) {
                Button { store.previous() } label: { Image(systemName: "backward.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel("Previous track")
                Button { store.togglePlay() } label: {
                    Image(systemName: store.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64)).frame(width: 72, height: 72)
                }
                .accessibilityLabel(store.isPlaying ? String(localized: "Pause", bundle: AppLocalization.bundle) : String(localized: "Play", bundle: AppLocalization.bundle))
                Button { store.next() } label: { Image(systemName: "forward.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel("Next track")
            }
            HStack(spacing: 24) {
                Button { store.toggleShuffle() } label: {
                    Image(systemName: "shuffle").frame(width: 44, height: 44)
                        .background(store.isShuffled ? Color.primary.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Shuffle")
                .accessibilityValue(store.isShuffled ? String(localized: "On", bundle: AppLocalization.bundle) : String(localized: "Off", bundle: AppLocalization.bundle))
                .accessibilityAddTraits(store.isShuffled ? .isSelected : [])
                Button { store.skip(-15) } label: { Image(systemName: "gobackward.15").frame(width: 44, height: 44) }
                    .accessibilityLabel("Back 15 seconds")
                Button { store.skip(15) } label: { Image(systemName: "goforward.15").frame(width: 44, height: 44) }
                    .accessibilityLabel("Forward 15 seconds")
                Button { store.cycleRepeat() } label: {
                    Image(systemName: store.repeatMode == .one ? "repeat.1" : "repeat").frame(width: 44, height: 44)
                        .background(store.repeatMode != .off ? Color.primary.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Repeat")
                .accessibilityValue(store.repeatMode.accessibilityValue)
                .accessibilityAddTraits(store.repeatMode != .off ? .isSelected : [])
            }
        }
        .font(.title2).buttonStyle(.plain)
    }
}

// Progress ticks invalidate only the slider and time labels.
private struct PlaybackPositionView: View {
    @Environment(MusicStore.self) private var store
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var scrubbingEntryID: UUID?

    var body: some View {
        VStack(spacing: 7) {
            Slider(value: Binding(get: { isScrubbing ? scrubPosition : store.progress }, set: { scrubPosition = $0 }),
                   in: 0...max(store.playbackDuration, 1), onEditingChanged: { editing in
                if editing {
                    scrubPosition = store.progress
                    scrubbingEntryID = store.queue.current?.id
                    isScrubbing = true
                } else {
                    if isScrubbing, scrubbingEntryID == store.queue.current?.id { store.seek(to: scrubPosition) }
                    isScrubbing = false
                    scrubbingEntryID = nil
                }
            })
            .disabled(store.playbackDuration <= 0)
            .accessibilityLabel("Playback position")
            .accessibilityValue(PlaybackTime.formatted(store.progress))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: store.seek(to: store.progress + 5)
                case .decrement: store.seek(to: store.progress - 5)
                @unknown default: break
                }
            }
            HStack {
                Text(PlaybackTime.formatted(isScrubbing ? scrubPosition : store.progress))
                Spacer()
                Text("-\(PlaybackTime.formatted(max(0, store.playbackDuration - (isScrubbing ? scrubPosition : store.progress))))")
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460)
        .onChange(of: store.queue.current?.id) { _, _ in
            isScrubbing = false
            scrubbingEntryID = nil
        }
    }

}

struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = .label
        uiView.activeTintColor = .label
    }
}
