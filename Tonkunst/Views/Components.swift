import SwiftUI

struct Artwork: View {
    let track: MediaTrack?
    var size: CGFloat = 52
    private let cornerRadius: CGFloat = 12

    var body: some View {
        Group { if let url = track?.artworkURL { AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { artworkFallback } } else { artworkFallback } }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
    private var artworkFallback: some View { Image("AppArtwork").resizable().scaledToFill() }
}

struct OfflineBadge: View { var body: some View { Image(systemName: "iphone.gen3").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityLabel("Available offline") } }

struct SongRow: View {
    @Environment(MusicStore.self) private var store
    let track: MediaTrack
    var action: (() -> Void)? = nil
    var body: some View {
        Button {
            if let action { action() } else { store.play(track) }
        } label: {
            HStack(spacing: 12) { Artwork(track: track, size: 48); VStack(alignment: .leading, spacing: 3) { Text(track.title).font(.body.weight(.medium)).lineLimit(1); Text("\(track.artist) · \(track.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if store.offline.contains(track) { OfflineBadge() }; Text(track.formattedDuration).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .buttonStyle(.plain)
        .disabled(!store.canPlay(track))
        .contextMenu {
            Button("Add to Queue", systemImage: "text.badge.plus") { store.addToQueue(track) }
            Button(store.offline.contains(track) ? String(localized: "Remove Download", bundle: AppLocalization.bundle) : String(localized: "Download for Offline", bundle: AppLocalization.bundle),
                   systemImage: store.offline.contains(track) ? "trash" : "arrow.down.circle") {
                Task { await store.toggleDownload(track) }
            }
            .disabled(store.offline.downloading.contains(track.id))
        }
    }
}

struct ConnectionPill: View {
    @Environment(MusicStore.self) private var store

    private var willDisconnect: Bool {
        store.connectionEnabled && (store.connectionAvailable || store.isConnecting)
    }

    private var statusLabel: some View {
        Label(store.listenStatus, systemImage: store.isConnecting ? "arrow.clockwise" : (store.connectionAvailable ? "checkmark.circle.fill" : "iphone.gen3"))
            .font(.caption.weight(.medium))
            .foregroundStyle(store.connectionAvailable ? .green : .orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }

    var body: some View {
        if store.profile != nil {
            Button { store.toggleConnection() } label: { statusLabel }
                .buttonStyle(.plain)
                .accessibilityLabel(willDisconnect ? String(localized: "Disconnect from Jellyfin", bundle: AppLocalization.bundle) : String(localized: "Connect to Jellyfin", bundle: AppLocalization.bundle))
        } else {
            statusLabel
        }
    }
}

private struct ConnectionModeToastModifier: ViewModifier {
    @Environment(MusicStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                ZStack {
                    if let notice = store.connectionModeNotice {
                        Label(notice.title, systemImage: notice.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .labelStyle(ConnectionModeToastLabelStyle(isOnline: notice.isOnline))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .glassEffect(.regular, in: Capsule())
                            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                            .padding(.horizontal, 16)
                            // Float below the navigation controls without moving the list.
                            .padding(.top, 60)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(notice.title)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                            .id(notice.id)
                    }
                }
                .allowsHitTesting(false)
                .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.25), value: store.connectionModeNotice)
            }
    }
}

private struct ConnectionModeToastLabelStyle: LabelStyle {
    let isOnline: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon
                .font(.title3.weight(.semibold))
                .foregroundStyle(isOnline ? .green : .orange)
            configuration.title
        }
    }
}

// Shared by every screen and sheet; raw values are persisted across launches.
enum AmbientStyle: String, CaseIterable {
    case standard, aurora, dusk, lagoon, ember

    static let storageKey = "ambientBackground"
    var title: String {
        switch self {
        case .standard: String(localized: "Standard", bundle: AppLocalization.bundle)
        case .aurora: String(localized: "Aurora", bundle: AppLocalization.bundle)
        case .dusk: String(localized: "Dusk", bundle: AppLocalization.bundle)
        case .lagoon: String(localized: "Lagoon", bundle: AppLocalization.bundle)
        case .ember: String(localized: "Ember", bundle: AppLocalization.bundle)
        }
    }
    var next: Self {
        switch self {
        case .standard: .aurora
        case .aurora: .dusk
        case .dusk: .lagoon
        case .lagoon: .ember
        case .ember: .standard
        }
    }

    var colors: [Color] {
        switch self {
        case .standard: return []
        case .aurora: return [Color(red: 0.12, green: 0.65, blue: 0.48), Color(red: 0.28, green: 0.25, blue: 0.85), Color(red: 0.15, green: 0.48, blue: 0.78)]
        case .dusk: return [Color(red: 0.62, green: 0.25, blue: 0.68), Color(red: 0.88, green: 0.39, blue: 0.48), Color(red: 0.38, green: 0.30, blue: 0.78)]
        case .lagoon: return [Color(red: 0.04, green: 0.48, blue: 0.64), Color(red: 0.10, green: 0.66, blue: 0.61), Color(red: 0.22, green: 0.38, blue: 0.75)]
        case .ember: return [Color(red: 0.82, green: 0.35, blue: 0.20), Color(red: 0.76, green: 0.53, blue: 0.18), Color(red: 0.65, green: 0.24, blue: 0.42)]
        }
    }
}

private struct AmbientBackground: View {
    let style: AmbientStyle
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion || reduceTransparency || scenePhase != .active)) { context in
            let phase = reduceMotion || reduceTransparency ? 0 : context.date.timeIntervalSinceReferenceDate / 120 * 2 * .pi
            let x = 0.5 + 0.45 * sin(phase)
            let y = 0.5 + 0.45 * cos(phase)
            ZStack {
                LinearGradient(colors: style.colors, startPoint: UnitPoint(x: x, y: y), endPoint: UnitPoint(x: 1 - x, y: 1 - y))
                // Bound luminance throughout the animation so semantic text stays legible.
                (scheme == .dark ? Color.black : Color.white)
                    .opacity(reduceTransparency ? 0.96 : (contrast == .increased ? 0.94 : 0.86))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AmbientScreenModifier: ViewModifier {
    @AppStorage(AmbientStyle.storageKey) private var selection = AmbientStyle.standard.rawValue
    private var style: AmbientStyle { AmbientStyle(rawValue: selection) ?? .standard }

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(style == .standard ? .automatic : .hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if style != .standard { AmbientBackground(style: style) }
            }
    }
}

private struct AmbientRowsModifier: ViewModifier {
    @AppStorage(AmbientStyle.storageKey) private var selection = AmbientStyle.standard.rawValue

    func body(content: Content) -> some View {
        content.listRowBackground(
            (AmbientStyle(rawValue: selection) ?? .standard) == .standard ? nil : Color.clear
        )
    }
}

extension View {
    func connectionModeToast() -> some View { modifier(ConnectionModeToastModifier()) }
    func ambientRows() -> some View { modifier(AmbientRowsModifier()) }
    func ambientScreen() -> some View { modifier(AmbientScreenModifier()) }
}
