import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: MusicStore
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
        .sheet(isPresented: $showPlayer) {
            NowPlayingView()
                .environmentObject(store)
                .presentationDetents([.height(640)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAccount) {
            AccountView()
                .environmentObject(store)
                .presentationDetents([.height(560), .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.recheckConnection() }
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
    @EnvironmentObject private var store: MusicStore
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
            searchable(text: text, placement: .toolbar, prompt: prompt)
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
    @EnvironmentObject private var store: MusicStore
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
                                        store.connectionAvailable ? "No Songs Yet" : "No Downloaded Songs",
                                        systemImage: "music.note",
                                        description: Text(store.connectionAvailable
                                            ? "Your Jellyfin music library is empty."
                                            : "Connect to Jellyfin and download songs to listen offline.")
                                    )
                                } else {
                                    ContentUnavailableView.search(text: filter)
                                }
                            }
                        }
                        .revealSearchOnPull($isSearchRevealed)
                        .pullToSearch(isRevealed: isSearchRevealed, text: $filter, prompt: "Songs, artists, albums")
                }
            }
            .libraryHeaderSpacing()
            .ambientScreen()
            .navigationTitle(isBrandVisible ? "" : "Songs")
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
    @EnvironmentObject private var store: MusicStore
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
                            ArtistTracksView(artist: artist.name, tracks: artist.tracks)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color.accentColor.gradient)
                                    .frame(width: 45, height: 45)
                                    .overlay {
                                        Text(String(artist.name.prefix(1)))
                                            .font(.title3.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                Text(artist.name)
                                Spacer()
                                Text("\(artist.tracks.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                        ContentUnavailableView("No Artists", systemImage: "person.2")
                    } else {
                        ContentUnavailableView.search(text: filter)
                    }
                }
            }
            .libraryHeaderSpacing()
            .ambientScreen()
            .navigationTitle(isBrandVisible ? "" : "Artists")
            .navigationBarTitleDisplayMode(.inline)
            .pullToSearch(isRevealed: isSearchRevealed, text: $filter, prompt: "Search artists")
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
    @EnvironmentObject private var store: MusicStore
    let artist: String
    let tracks: [MediaTrack]
    @State private var filter = ""
    @State private var isSearchRevealed = false

    private var filteredTracks: [MediaTrack] {
        tracks.filter { store.canPlay($0) && (filter.isEmpty || $0.matches(filter)) }
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
        .pullToSearch(isRevealed: isSearchRevealed, text: $filter, prompt: "Songs, albums")
    }
}

struct QueueView: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.miniPlayerClearance) private var playerClearance
    @Binding var showAccount: Bool
    @State private var isBrandVisible = true

    private var isEmpty: Bool {
        store.queue.current == nil && store.queue.history.isEmpty && store.queue.upcoming.isEmpty
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
                                ForEach(Array(store.queue.upcoming.reversed())) { entry in
                                    queueRow(entry, state: "Upcoming")
                                }
                                if let entry = store.queue.current {
                                    queueRow(entry, state: "Now Playing")
                                        .id("current")
                                }
                                ForEach(store.queue.history) { entry in
                                    queueRow(entry, state: "Played")
                                }
                            }
                            .listStyle(.plain)
                            .contentMargins(.top, max(0, geometry.size.height / 2 - 40), for: .scrollContent)
                            .contentMargins(.bottom, max(playerClearance, geometry.size.height / 2 - 40), for: .scrollContent)
                            .tonkunstBrandVisibility($isBrandVisible)
                            .onAppear { proxy.scrollTo("current", anchor: .center) }
                            .onChange(of: store.queue.current?.id) { _, _ in
                                withAnimation { proxy.scrollTo("current", anchor: .center) }
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
            .navigationTitle(isBrandVisible ? "" : "Queue")
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

    private func queueRow(_ entry: QueueEntry, state: String) -> some View {
        HStack(spacing: 12) {
            Artwork(track: entry.track, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.track.title).fontWeight(state == "Now Playing" ? .bold : .regular)
                Text("\(entry.track.artist) · \(state)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.offline.contains(entry.track) { OfflineBadge() }
            Text(entry.track.formattedDuration).font(.caption.monospacedDigit())
        }
        .foregroundStyle(state == "Played" ? .secondary : .primary)
        .listRowBackground(state == "Played" ? Color.gray.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
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
}

struct OfflineView: View {
    @EnvironmentObject private var store: MusicStore
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
            .navigationTitle(isBrandVisible ? "" : "Offline")
            .navigationBarTitleDisplayMode(.inline)
            .pullToSearch(isRevealed: isSearchRevealed, text: $filter, prompt: "Songs, artists, albums")
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
    @EnvironmentObject private var store: MusicStore
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
            .searchable(text: $query, prompt: "Search your collection")
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
    @EnvironmentObject private var store: MusicStore
    @Binding var showAccount: Bool
    var body: some View {
        Button { showAccount = true } label: { ProfileAvatar(url: store.profile?.avatarURL) }
            .buttonStyle(.plain)
            .accessibilityLabel("Account and settings")
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var store: MusicStore
    @Binding var showAccount: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image("AppArtwork")
                .resizable()
                .scaledToFill()
                .frame(width: 106, height: 106)
                .clipShape(Rectangle())
            Text("Your music, beautifully yours.")
                .font(.title2.weight(.bold))
            Text("Connect Tonkunst to your Jellyfin server and take your collection anywhere.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)
            Button(store.savedProfiles.isEmpty ? "Connect to Jellyfin" : "Choose Saved Account") {
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
    private var fallback: some View { Image(systemName: "person.fill").font(.caption).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity).background(.tint, in: Circle()) }
}
