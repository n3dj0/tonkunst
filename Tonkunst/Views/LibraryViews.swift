import SwiftUI
import UIKit

struct LibraryView: View {
    @Environment(MusicStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var showPlayer = false
    @State private var showAccount = false
    @State private var displayedError: String?
    @State private var isShowingError = false
    var body: some View {
        TabView(selection: $selectedTab) {
            SongsView(showAccount: $showAccount).miniPlayerContainer(expanded: $showPlayer).tabItem { Label("Songs", systemImage: "music.note.list") }.tag(0)
            ArtistsView(showAccount: $showAccount).miniPlayerContainer(expanded: $showPlayer).tabItem { Label("Artists", systemImage: "person.2") }.tag(1)
            QueueView(showAccount: $showAccount).miniPlayerContainer(expanded: $showPlayer).tabItem { Label("Queue", systemImage: "music.note.list") }.tag(2)
            OfflineView(showAccount: $showAccount).miniPlayerContainer(expanded: $showPlayer).tabItem { Label("Offline", systemImage: "iphone.gen3") }.tag(3)
            SearchView(showAccount: $showAccount).miniPlayerContainer(expanded: $showPlayer).tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(4)
        }
        .connectionModeToast(isEnabled: !showAccount)
        .sheet(isPresented: $showPlayer) {
            NowPlayingView()
                .environment(store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAccount) {
            AccountView()
                .environment(store)
                .presentationDetents([.height(560), .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.recheckConnection() }
            if phase == .background {
                Task {
                    let token = UIApplication.shared.beginBackgroundTask(withName: String(localized: "Save Queue", bundle: AppLocalization.bundle))
                    await store.flushPersistence()
                    if token != .invalid { UIApplication.shared.endBackgroundTask(token) }
                }
            }
        }
        .onChange(of: store.errorMessage) { _, errorMessage in
            displayedError = errorMessage
            isShowingError = errorMessage != nil
        }
        .alert("Tonkunst", isPresented: $isShowingError) {
            Button("OK") {
                displayedError = nil
                store.errorMessage = nil
            }
        } message: {
            Text(displayedError ?? "")
        }
    }
}

private struct MiniPlayerClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private extension EnvironmentValues {
    var miniPlayerClearance: CGFloat {
        get { self[MiniPlayerClearanceKey.self] }
        set { self[MiniPlayerClearanceKey.self] = newValue }
    }
}

private struct MiniPlayerContainer: ViewModifier {
    @Environment(MusicStore.self) private var store
    @Binding var expanded: Bool
    @State private var playerHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.miniPlayerClearance, store.currentTrack == nil ? 0 : playerHeight)
            .overlay(alignment: .bottom) {
                if store.currentTrack != nil {
                    MiniPlayer(expanded: $expanded)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            playerHeight = height
                        }
                }
            }
    }
}

private struct MiniPlayerScrollClearance: ViewModifier {
    @Environment(\.miniPlayerClearance) private var clearance

    func body(content: Content) -> some View {
        // Extend the scrollable content without shrinking the list's viewport:
        // rows still pass behind the floating glass, and the last row clears it.
        content.contentMargins(.bottom, clearance, for: .scrollContent)
    }
}

private extension View {
    func miniPlayerContainer(expanded: Binding<Bool>) -> some View {
        modifier(MiniPlayerContainer(expanded: expanded))
    }

    func miniPlayerScrollClearance() -> some View {
        modifier(MiniPlayerScrollClearance())
    }
}

private extension View {
    /// Gives every tab the same breathing room below the fixed navigation header.
    func libraryHeaderSpacing() -> some View {
        safeAreaPadding(.top, 8)
    }

    /// The brand belongs to the top bar only while a collection is at rest.
    /// Once its content moves, the normal screen title keeps the navigation bar clear.
    func tonkunstBrandVisibility(_ isVisible: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top < 8
        } action: { _, isAtTop in
            withAnimation(.easeOut(duration: 0.15)) {
                isVisible.wrappedValue = isAtTop
            }
        }
    }

    @ViewBuilder
    func pullToSearch(
        isRevealed: Bool,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        if isRevealed {
            searchable(text: text, placement: .toolbar, prompt: Text(LocalizedStringKey(prompt)))
        } else {
            self
        }
    }

    /// SwiftUI can leave a searchable drawer open on a newly mounted list.
    /// Add it only after the user pulls past the list's top edge.
    func revealSearchOnPull(_ isRevealed: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            if offset < -20 {
                isRevealed.wrappedValue = true
            }
        }
    }
}

private struct TonkunstBrand: View {
    @AppStorage(AmbientStyle.storageKey) private var selection = AmbientStyle.standard.rawValue
    private var style: AmbientStyle { AmbientStyle(rawValue: selection) ?? .standard }

    var body: some View {
        Button { selection = style.next.rawValue } label: {
            Text("Tonkunst")
                .font(.system(size: 27, weight: .regular, design: .serif))
                .tracking(-0.8)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel("Tonkunst")
        .accessibilityValue("\(style.title) background")
        .accessibilityHint("Changes the background. Five backgrounds available.")
    }
}

struct ScreenHeader: View {
    let title: String
    var body: some View { HStack { Text(title).font(.largeTitle.weight(.bold)); Spacer(); ConnectionPill() }.padding(.horizontal).padding(.top, 10) }
}

struct SongsView: View {
    @Environment(MusicStore.self) private var store
    @Binding var showAccount: Bool
    @State private var filter = ""
    @State private var isBrandVisible = true
    @State private var isSearchRevealed = false
    private var songs: [MediaTrack] { filter.isEmpty ? store.tracks : store.tracks.filter { $0.matches(filter) } }

    var body: some View {
        NavigationStack {
            Group {
                if store.isRestoringSession {
                    ProgressView("Opening Tonkunst…")
                } else if store.profile == nil {
                    WelcomeView(showAccount: $showAccount)
                } else if store.isLoading && store.tracks.isEmpty {
                    ProgressView("Loading your music…")
                } else {
                    List(songs) { track in
                        SongRow(track: track).ambientRows()
                    }
                        .listStyle(.plain)
                        .miniPlayerScrollClearance()
                        .tonkunstBrandVisibility($isBrandVisible)
                        .refreshable { await store.refresh(isUserInitiated: true) }
                        .overlay {
                            if songs.isEmpty {
                                if filter.isEmpty {
                                    ContentUnavailableView(
                                        store.connectionAvailable ? String(localized: "No Songs Yet", bundle: AppLocalization.bundle) : String(localized: "No Downloaded Songs", bundle: AppLocalization.bundle),
                                        systemImage: "music.note",
                                        description: Text(store.connectionAvailable
                                            ? String(localized: "Your Jellyfin music library is empty.", bundle: AppLocalization.bundle)
                                            : String(localized: "Connect to Jellyfin and download songs to listen offline.", bundle: AppLocalization.bundle))
                                    )
                                } else {
                                    ContentUnavailableView.search(text: filter)
                                }
                            }
                        }
                        .revealSearchOnPull($isSearchRevealed)
                        .pullToSearch(isRevealed: isSearchRevealed, text: $filter, prompt: String(localized: "Songs, artists, albums", bundle: AppLocalization.bundle))
                }
            }
            .libraryHeaderSpacing()
            .ambientScreen()
            .navigationTitle(isBrandVisible ? "" : String(localized: "Songs", bundle: AppLocalization.bundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isBrandVisible { TonkunstBrand() }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ConnectionPill()
                    AccountButton(showAccount: $showAccount)
                }
            }
        }
    }
}

struct ArtistsView: View {
    @Environment(MusicStore.self) private var store
    @Binding var showAccount: Bool
    @State private var filter = ""
    @State private var isBrandVisible = true
    @State private var isSearchRevealed = false

    private var artists: [(name: String, tracks: [MediaTrack])] {
        Dictionary(grouping: store.tracks, by: \.artist)
            .map { ($0.key, $0.value) }
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    ForEach(artists, id: \.name) { artist in
                        NavigationLink {
                            ArtistTracksView(artist: artist.name)
                        } label: {
                            HStack(spacing: MediaListLayout.spacing) {
                                Circle()
                                    .fill(Color.accentColor.gradient)
                                    .frame(width: MediaListLayout.artworkSize, height: MediaListLayout.artworkSize)
                                    .overlay {
                                        Text(String(artist.name.prefix(1)))
                                            .font(.title3.weight(.bold))
                                            .foregroundStyle(Color(uiColor: .systemBackground))
                                    }
                                MarqueeText(text: artist.name, isActive: store.currentTrack?.artist == artist.name)
                                Text("\(artist.tracks.count)")
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                            .mediaListRow()
                        }
                        .listRowInsets(MediaListLayout.insets)
                    }
                }
                .ambientRows()
            }
            .listStyle(.plain)
            .miniPlayerScrollClearance()
            .tonkunstBrandVisibility($isBrandVisible)
            .revealSearchOnPull($isSearchRevealed)
            .overlay {
                if artists.isEmpty {
                    if filter.isEmpty {
                        ContentUnavailableView(
                            "No Artists",
                            systemImage: "person.2",
                            description: Text("Artists from your music library will appear here.")
                        )
                    } else {
                        ContentUnavailableView.search(text: filter)
                    }
                }
            }
            .libraryHeaderSpacing()
            .ambientScreen()
            .navigationTitle(isBrandVisible ? "" : String(localized: "Artists", bundle: AppLocalization.bundle))
            .navigationBarTitleDisplayMode(.inline)
            .pullToSearch(isRevealed: isSearchRevealed, text: $filter, prompt: String(localized: "Search artists", bundle: AppLocalization.bundle))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isBrandVisible { TonkunstBrand() }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ConnectionPill()
                    AccountButton(showAccount: $showAccount)
                }
            }
        }
    }
}

private struct ArtistTracksView: View {
    @Environment(MusicStore.self) private var store
    let artist: String
    @State private var filter = ""
    @State private var isSearchRevealed = false

    private var filteredTracks: [MediaTrack] {
        store.tracks.filter { $0.artist == artist && store.canPlay($0) && (filter.isEmpty || $0.matches(filter)) }
    }

    var body: some View {
        Group {
            if filteredTracks.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                List(filteredTracks) { track in
                    SongRow(track: track).ambientRows()
                }
                    .listStyle(.plain)
                    .miniPlayerScrollClearance()
                    .revealSearchOnPull($isSearchRevealed)
            }
        }
        .ambientScreen()
        .navigationTitle(artist)
        .navigationBarTitleDisplayMode(.inline)
        .pullToSearch(isRevealed: isSearchRevealed, text: $filter, prompt: String(localized: "Songs, albums", bundle: AppLocalization.bundle))
    }
}

private enum QueueRowState {
    case upcoming, current, played
    var title: String {
        switch self {
        case .upcoming: String(localized: "Upcoming", bundle: AppLocalization.bundle)
        case .current: String(localized: "Now Playing", bundle: AppLocalization.bundle)
        case .played: String(localized: "Played", bundle: AppLocalization.bundle)
        }
    }
}

private struct QueueListRow: Identifiable {
    let entry: QueueEntry
    let state: QueueRowState
    var id: UUID { entry.id }
}

struct QueueView: View {
    @Environment(MusicStore.self) private var store
    @Environment(\.miniPlayerClearance) private var playerClearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var showAccount: Bool
    @State private var isBrandVisible = true
    @State private var selectionAnimationID: UUID?

    private var isEmpty: Bool {
        store.queue.current == nil && store.queue.history.isEmpty && store.queue.upcoming.isEmpty
    }

    private var rows: [QueueListRow] {
        var rows = store.queue.upcoming.reversed().map { QueueListRow(entry: $0, state: .upcoming) }
        if let entry = store.queue.current { rows.append(QueueListRow(entry: entry, state: .current)) }
        rows += store.queue.history.map { QueueListRow(entry: $0, state: .played) }
        return rows
    }

    private var queueMovementAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.45)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty {
                    ContentUnavailableView("Your Queue", systemImage: "music.note.list",
                        description: Text("Long-press a song in any list and choose Add to Queue."))
                } else {
                    GeometryReader { geometry in
                        ScrollViewReader { proxy in
                            List {
                                Section {
                                    if store.queue.upcoming.isEmpty {
                                        ContentUnavailableView("Up Next", systemImage: "text.badge.plus",
                                            description: Text("Long-press a song in any list and choose Add to Queue. Your upcoming songs will appear here."))
                                            .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height / 2 - 40))
                                            .listRowInsets(EdgeInsets())
                                            .listRowSeparator(.hidden)
                                            .listRowBackground(Color.clear)
                                    }
                                    // One collection preserves each occurrence's identity as it moves between states.
                                    ForEach(rows) { row in
                                        queueRow(row.entry, state: row.state, proxy: proxy)
                                    }
                                }
                                .listSectionSeparator(.hidden, edges: .all)
                            }
                            .listStyle(.plain)
                            .animation(queueMovementAnimation, value: store.queue.current?.id)
                            .contentMargins(.top, store.queue.upcoming.isEmpty ? 0 : max(0, geometry.size.height / 2 - 40), for: .scrollContent)
                            .contentMargins(.bottom, max(playerClearance, geometry.size.height / 2 - 40), for: .scrollContent)
                            .tonkunstBrandVisibility($isBrandVisible)
                            .onAppear {
                                if let id = store.queue.current?.id { proxy.scrollTo(id, anchor: .center) }
                            }
                            .onChange(of: store.queue.current?.id) { _, id in
                                guard selectionAnimationID == nil, let id else { return }
                                withAnimation(queueMovementAnimation) { proxy.scrollTo(id, anchor: .center) }
                            }
                            .onChange(of: store.queue.upcoming.isEmpty) { _, _ in
                                guard selectionAnimationID == nil, let id = store.queue.current?.id else { return }
                                withAnimation(queueMovementAnimation) { proxy.scrollTo(id, anchor: .center) }
                            }
                        }
                    }
                }
            }
            .onChange(of: isEmpty) { _, empty in
                if empty { isBrandVisible = true }
            }
            .libraryHeaderSpacing()
            .ambientScreen()
            .navigationTitle(isBrandVisible ? "" : String(localized: "Queue", bundle: AppLocalization.bundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isBrandVisible { TonkunstBrand() }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Start Queue", systemImage: "play.fill") { store.startQueue() }
                        .labelStyle(.iconOnly)
                        .disabled(store.isPlaying || !(
                            store.queue.current.map { store.canPlay($0.track) } == true ||
                            store.queue.upcoming.contains { store.canPlay($0.track) }
                        ))
                    ConnectionPill()
                    AccountButton(showAccount: $showAccount)
                }
            }
        }
    }

    private func queueRow(_ entry: QueueEntry, state: QueueRowState, proxy: ScrollViewProxy) -> some View {
        Button {
            selectQueueEntry(entry.id, proxy: proxy)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if state == .current {
                    HStack(spacing: 4) {
                        Text(state.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(uiColor: .secondaryLabel), in: RoundedRectangle(cornerRadius: 3))
                            .layoutPriority(1)
                        Color(uiColor: .secondaryLabel)
                            .frame(height: 1)
                            .accessibilityHidden(true)
                    }
                }
                TrackRowLabel(track: entry.track,
                              subtitle: state == .current ? entry.track.artist : "\(entry.track.artist) · \(state.title)",
                              isOffline: store.offline.contains(entry.track),
                              isActive: state == .current,
                              titleWeight: state == .current ? .bold : .regular,
                              isDurationSecondary: false)
            }
            .mediaListRow()
        }
        .buttonStyle(.plain)
        .disabled(!store.canPlay(entry.track))
        .accessibilityHint("Play this song from the beginning")
        .foregroundStyle(state == .played ? .secondary : .primary)
        .listRowInsets(MediaListLayout.insets)
        .listRowSeparator(.hidden, edges: .all)
        .listRowBackground(queueRowBackground(entry, state: state))
        .contextMenu {
            Button("Add to Queue", systemImage: "text.badge.plus") { store.addToQueue(entry.track) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { store.queuePlayNext(entry.id) }
            Button("Move Up", systemImage: "arrow.up") { store.moveInQueue(entry.id, up: true) }
                .disabled(!store.queue.canMove(entry.id, up: true))
            Button("Move Down", systemImage: "arrow.down") { store.moveInQueue(entry.id, up: false) }
                .disabled(!store.queue.canMove(entry.id, up: false))
            Button("Delete from Queue", systemImage: "trash", role: .destructive) { store.removeFromQueue(entry.id) }
        }
    }

    private func selectQueueEntry(_ id: UUID, proxy: ScrollViewProxy) {
        let animationID = UUID()
        selectionAnimationID = animationID
        withAnimation(queueMovementAnimation, completionCriteria: .removed) {
            store.playFromQueue(id)
        } completion: {
            // A newer tap owns the final scroll if the user selects songs in quick succession.
            guard selectionAnimationID == animationID else { return }
            selectionAnimationID = nil
            guard let currentID = store.queue.current?.id else { return }
            withAnimation(queueMovementAnimation) { proxy.scrollTo(currentID, anchor: .center) }
        }
    }

    @ViewBuilder
    private func queueRowBackground(_ entry: QueueEntry, state: QueueRowState) -> some View {
        if state == .current {
            Color.clear
                .overlay(alignment: .bottom) {
                    Color(uiColor: .secondaryLabel)
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                }
                .accessibilityHidden(true)
        } else {
            ZStack(alignment: .bottom) {
                state == .played ? Color.gray.opacity(0.15) : Color.clear
                // Own the dividers so neither neighbor can add a line against the current song.
                if state == .played || store.queue.current == nil || entry.id != store.queue.upcoming.first?.id {
                    Divider()
                        .padding(.leading, MediaListLayout.horizontalInset + MediaListLayout.artworkSize + MediaListLayout.spacing)
                        .padding(.trailing, 16)
                }
            }
        }
    }
}

struct OfflineView: View {
    @Environment(MusicStore.self) private var store
    @Binding var showAccount: Bool
    @State private var filter = ""
    @State private var isBrandVisible = true
    @State private var isSearchRevealed = false

    private var offlineTracks: [MediaTrack] {
        filter.isEmpty ? store.offlineTracks : store.offlineTracks.filter { $0.matches(filter) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.offlineTracks.isEmpty {
                    ContentUnavailableView(
                        "No Offline Music",
                        systemImage: "arrow.down.circle",
                        description: Text("Download songs from your library to listen without a connection.")
                    )
                } else if offlineTracks.isEmpty {
                    ContentUnavailableView.search(text: filter)
                } else {
                    List(offlineTracks) { track in
                        SongRow(track: track).ambientRows()
                    }
                        .listStyle(.plain)
                        .miniPlayerScrollClearance()
                        .tonkunstBrandVisibility($isBrandVisible)
                        .revealSearchOnPull($isSearchRevealed)
                }
            }
            .libraryHeaderSpacing()
            .ambientScreen()
            .navigationTitle(isBrandVisible ? "" : String(localized: "Offline", bundle: AppLocalization.bundle))
            .navigationBarTitleDisplayMode(.inline)
            .pullToSearch(isRevealed: isSearchRevealed, text: $filter, prompt: String(localized: "Songs, artists, albums", bundle: AppLocalization.bundle))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isBrandVisible { TonkunstBrand() }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ConnectionPill()
                    AccountButton(showAccount: $showAccount)
                }
            }
        }
    }
}

struct SearchView: View {
    @Environment(MusicStore.self) private var store
    @Binding var showAccount: Bool
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool
    
    private var results: [MediaTrack] {
        store.tracks.filter { $0.matches(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    ContentUnavailableView(
                        "Search Your Music",
                        systemImage: "magnifyingglass",
                        description: Text("Find songs, artists and albums.")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { track in
                        SongRow(track: track).ambientRows()
                    }
                        .listStyle(.plain)
                        .miniPlayerScrollClearance()
                }
            }
            .libraryHeaderSpacing()
            .ambientScreen()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: String(localized: "Search your collection", bundle: AppLocalization.bundle))
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .searchFocused($isSearchFocused)
            .onAppear {
                DispatchQueue.main.async {
                    isSearchFocused = true
                }
            }
            .onDisappear {
                isSearchFocused = false
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    TonkunstBrand()
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ConnectionPill()
                    AccountButton(showAccount: $showAccount)
                }
            }
        }
    }
}

private extension MediaTrack {
    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query) ||
        artist.localizedCaseInsensitiveContains(query) ||
        album.localizedCaseInsensitiveContains(query)
    }
}

struct AccountButton: View {
    @Environment(MusicStore.self) private var store
    @Binding var showAccount: Bool
    var body: some View {
        Button { showAccount = true } label: { ProfileAvatar(url: store.profile?.avatarURL) }
            .buttonStyle(.plain)
            .accessibilityLabel("Account and settings")
    }
}

struct WelcomeView: View {
    @Environment(MusicStore.self) private var store
    @Binding var showAccount: Bool

    var body: some View {
        VStack(spacing: 18) {
            Artwork(track: nil, size: 106)
            Text("Your music, beautifully yours.")
                .font(.title2.weight(.bold))
            Text("Connect Tonkunst to your Jellyfin server and take your collection anywhere.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)
            Button(store.savedProfiles.isEmpty ? String(localized: "Connect to Jellyfin", bundle: AppLocalization.bundle) : String(localized: "Choose Saved Account", bundle: AppLocalization.bundle)) {
                showAccount = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProfileAvatar: View {
    let url: String?
    var body: some View {
        Group {
            if let url, let imageURL = URL(string: url) {
                AsyncImage(url: imageURL) { $0.resizable().scaledToFill() } placeholder: { fallback }
            } else {
                fallback
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }
    private var fallback: some View {
        Image(systemName: "person.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.12), in: Circle())
    }
}
