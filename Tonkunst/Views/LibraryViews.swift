import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: MusicStore
    @State private var selectedTab = 0
    @State private var showPlayer = false
    @State private var showAccount = false
    @State private var displayedError: String?
    @State private var isShowingError = false
    var body: some View {
        TabView(selection: $selectedTab) {
            SongsView(showAccount: $showAccount).miniPlayerInset(expanded: $showPlayer).tabItem { Label("Songs", systemImage: "music.note.list") }.tag(0)
            ArtistsView(showAccount: $showAccount).miniPlayerInset(expanded: $showPlayer).tabItem { Label("Artists", systemImage: "person.2") }.tag(1)
            PlaylistsView(showAccount: $showAccount).miniPlayerInset(expanded: $showPlayer).tabItem { Label("Playlists", systemImage: "music.note.list") }.tag(2)
            OfflineView(showAccount: $showAccount).miniPlayerInset(expanded: $showPlayer).tabItem { Label("Offline", systemImage: "iphone.gen3") }.tag(3)
            SearchView(showAccount: $showAccount).miniPlayerInset(expanded: $showPlayer).tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(4)
        }
        .sheet(isPresented: $showPlayer) {
            NowPlayingView()
                .environmentObject(store)
                .presentationDetents([.height(640)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAccount) { AccountView().environmentObject(store) }
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

private extension View {
    /// Keeps the custom Liquid Glass player above the tab bar without
    /// allocating any space until `MiniPlayer` has a current track to show.
    func miniPlayerInset(expanded: Binding<Bool>) -> some View {
        safeAreaInset(edge: .bottom, spacing: 8) {
            MiniPlayer(expanded: expanded)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
    }
}

private extension View {
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
    var body: some View {
        Text("Tonkunst")
            .font(.system(size: 27, weight: .regular, design: .serif))
            .tracking(-0.8)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Tonkunst")
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
                    List(songs) { SongRow(track: $0) }
                        .listStyle(.plain)
                        .tonkunstBrandVisibility($isBrandVisible)
                        .refreshable { await store.refresh() }
                        .overlay {
                            if songs.isEmpty {
                                if filter.isEmpty {
                                    ContentUnavailableView(
                                        "No Songs Yet",
                                        systemImage: "music.note",
                                        description: Text(store.connectionAvailable
                                            ? "Your Jellyfin music library is empty."
                                            : "Connect to Jellyfin to browse your music.")
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
            .listStyle(.plain)
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
    let artist: String
    let tracks: [MediaTrack]
    @State private var filter = ""
    @State private var isSearchRevealed = false

    private var filteredTracks: [MediaTrack] {
        filter.isEmpty ? tracks : tracks.filter { $0.matches(filter) }
    }

    var body: some View {
        Group {
            if filteredTracks.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                List(filteredTracks) { SongRow(track: $0) }
                    .listStyle(.plain)
                    .revealSearchOnPull($isSearchRevealed)
            }
        }
        .navigationTitle(artist)
        .navigationBarTitleDisplayMode(.inline)
        .pullToSearch(isRevealed: isSearchRevealed, text: $filter, prompt: "Songs, albums")
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var store: MusicStore
    @Binding var showAccount: Bool
    var body: some View {
        PlaylistBrowser(library: store.playlistLibrary, showAccount: $showAccount)
    }
}

private struct PlaylistBrowser: View {
    @EnvironmentObject private var store: MusicStore
    @ObservedObject var library: PlaylistLibrary
    @Binding var showAccount: Bool
    @State private var showCreate = false
    @State private var name = ""
    @State private var deleting: SavedPlaylist?

    var body: some View {
        NavigationStack {
            List {
                if let message = library.message {
                    Section { Text(message).foregroundStyle(.red); Button("Retry Sync") { sync() } }
                }
                if library.isSyncing { ProgressView("Syncing playlists…") }
                ForEach(library.playlists) { playlist in
                    NavigationLink {
                        PlaylistDetail(library: library, id: playlist.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.content.name)
                            Text(status(playlist)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if !playlist.deleted && !playlist.conflict && !playlist.creationUncertain {
                            Button("Delete", role: .destructive) { deleting = playlist }
                                .disabled(library.isSyncing)
                        }
                    }
                }
            }
            .overlay {
                if library.playlists.isEmpty && !library.isSyncing && library.message == nil {
                    ContentUnavailableView("Your Playlists", systemImage: "music.note.list",
                        description: Text(store.profile == nil ? "Connect to Jellyfin to create and sync playlists." : "Tap + to create a playlist. Changes made offline sync when you reconnect."))
                }
            }
            .refreshable { await store.syncPlaylists() }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ConnectionPill()
                    Button { name = ""; showCreate = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New playlist")
                        .disabled(store.profile == nil || library.isSyncing)
                    AccountButton(showAccount: $showAccount)
                }
            }
            .alert("New Playlist", isPresented: $showCreate) {
                TextField("Playlist name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Create") { library.create(name: name); sync() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.isSyncing)
            }
            .confirmationDialog("Delete playlist from this device and Jellyfin?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete Playlist", role: .destructive) {
                    if let deleting { library.delete(deleting.id); sync() }
                    deleting = nil
                }
            } message: { Text("Songs stay in your music library. Offline deletions sync when you reconnect.") }
            .task { await store.syncPlaylists() }
        }
    }

    private func sync() { Task { await store.syncPlaylists() } }
    private func status(_ playlist: SavedPlaylist) -> String {
        if playlist.creationUncertain { return "Creation needs review" }
        if playlist.conflict { return "Changes need review" }
        if playlist.deleted { return "Waiting to delete from Jellyfin" }
        return "\(playlist.content.tracks.count) songs" + (playlist.dirty ? " · Waiting to sync" : " · Synced")
    }
}

private struct PlaylistDetail: View {
    @EnvironmentObject private var store: MusicStore
    @ObservedObject var library: PlaylistLibrary
    let id: UUID
    @State private var showSongs = false
    @State private var showRename = false
    @State private var showRetry = false
    @State private var name = ""
    private var playlist: SavedPlaylist? { library.playlists.first { $0.id == id } }

    var body: some View {
        Group {
            if let playlist {
                List {
                    if playlist.creationUncertain {
                        Section("Creation needs review") {
                            Text("Jellyfin may have created this playlist, but the response was lost. Refresh and check the server playlists before trying again to avoid a duplicate.")
                            Button("Refresh from Jellyfin") { sync() }
                            Button("Try Creating Again") { showRetry = true }
                            Button("Discard Device Draft", role: .destructive) { library.resolve(id, keepCopy: false) }
                        }
                    }
                    if playlist.conflict {
                        Section("Changes on both devices") {
                            Text(playlist.remote == nil ? "This playlist was removed from Jellyfin. Your device changes are still here." : "Jellyfin and this device have different changes. Keep the server version, or also save your device version as a new private playlist.")
                            Button("Keep Both Versions") { library.resolve(id, keepCopy: true); sync() }
                            Button("Use Server Version", role: .destructive) { library.resolve(id, keepCopy: false) }
                        }
                    }
                    if let message = library.message { Text(message).foregroundStyle(.red) }
                    if playlist.deleted {
                        Text("Waiting to delete from Jellyfin.")
                        Button("Cancel Deletion") { library.cancelDeletion(id) }
                    } else {
                        Section {
                            Button { store.playPlaylist(playable(playlist.content.tracks)) } label: { Label("Play", systemImage: "play.fill") }
                                .disabled(playlist.content.tracks.isEmpty)
                            Button { showSongs = true } label: { Label("Add Songs", systemImage: "plus") }
                                .disabled(library.isSyncing || playlist.conflict || playlist.creationUncertain)
                        }
                        Section {
                            ForEach(Array(playlist.content.tracks.enumerated()), id: \.offset) { index, track in
                                Button { store.playPlaylist(playable(playlist.content.tracks), startingAt: index) } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(track.title).foregroundStyle(.primary)
                                            Text(track.artist).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if store.offline.contains(track) { Image(systemName: "arrow.down.circle.fill") }
                                    }
                                }
                                .contextMenu {
                                    Button(store.offline.contains(track) ? "Remove Download" : "Download Song") {
                                        Task { await store.toggleDownload(track) }
                                    }
                                }
                            }
                            .onDelete { offsets in
                                var content = playlist.content
                                content.tracks.remove(atOffsets: offsets)
                                library.edit(id, content: content); sync()
                            }
                            .onMove { offsets, destination in
                                var content = playlist.content
                                content.tracks.move(fromOffsets: offsets, toOffset: destination)
                                library.edit(id, content: content); sync()
                            }
                            .deleteDisabled(library.isSyncing || playlist.conflict || playlist.creationUncertain)
                            .moveDisabled(library.isSyncing || playlist.conflict || playlist.creationUncertain)
                        } footer: {
                            Text(playlist.content.tracks.isEmpty ? "Add songs to start your playlist." : (playlist.dirty ? "Changes saved on this device. Waiting to sync." : "Synced with Jellyfin. Download songs to play them offline."))
                        }
                    }
                }
                .navigationTitle(playlist.content.name)
                .toolbar {
                    EditButton().disabled(library.isSyncing || playlist.conflict || playlist.creationUncertain || playlist.deleted)
                    Button("Rename") { name = playlist.content.name; showRename = true }
                        .disabled(library.isSyncing || playlist.conflict || playlist.creationUncertain || playlist.deleted)
                }
                .refreshable { await store.syncPlaylists() }
            } else {
                ContentUnavailableView("Playlist Removed", systemImage: "music.note.list")
            }
        }
        .sheet(isPresented: $showSongs) {
            PlaylistSongPicker(library: library) { selected in
                guard var content = self.playlist?.content else { return }
                content.tracks += selected
                library.edit(id, content: content); sync()
            }
        }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Playlist name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard var content = playlist?.content else { return }
                content.name = name
                library.edit(id, content: content); sync()
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.isSyncing)
        }
        .alert("Create another playlist?", isPresented: $showRetry) {
            Button("Cancel", role: .cancel) {}
            Button("Create") { library.retryCreation(id); sync() }
        } message: { Text("If the earlier request succeeded, this will create a duplicate on Jellyfin.") }
    }
    private func sync() { Task { await store.syncPlaylists() } }
    private func playable(_ tracks: [MediaTrack]) -> [MediaTrack] {
        tracks.map { track in store.tracks.first { $0.id == track.id } ?? track }
    }
}

private struct PlaylistSongPicker: View {
    @EnvironmentObject private var store: MusicStore
    @ObservedObject var library: PlaylistLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: [MediaTrack] = []
    let add: ([MediaTrack]) -> Void
    private var songs: [MediaTrack] {
        let tracks = store.tracks + store.playlistLibrary.catalog + store.playlistLibrary.playlists.flatMap { $0.content.tracks }
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted && (query.isEmpty || $0.matches(query)) }
    }
    var body: some View {
        NavigationStack {
            List(songs) { track in
                Button {
                    if selected.contains(where: { $0.id == track.id }) { selected.removeAll { $0.id == track.id } }
                    else { selected.append(track) }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(track.title).foregroundStyle(.primary)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selected.contains(where: { $0.id == track.id }) { Image(systemName: "checkmark") }
                    }
                }
            }
            .overlay { if songs.isEmpty { ContentUnavailableView("No Songs", systemImage: "music.note", description: Text("Connect to Jellyfin to load your music library.")) } }
            .searchable(text: $query, prompt: "Songs, artists, albums")
            .navigationTitle("Add Songs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selected.count))") { add(selected); dismiss() }
                        .disabled(selected.isEmpty || library.isSyncing)
                }
            }
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
                    List(offlineTracks) { SongRow(track: $0) }
                        .listStyle(.plain)
                        .tonkunstBrandVisibility($isBrandVisible)
                        .revealSearchOnPull($isSearchRevealed)
                }
            }
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
    @State private var isBrandVisible = true
    
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
                    List(results) { SongRow(track: $0) }
                        .listStyle(.plain)
                        .tonkunstBrandVisibility($isBrandVisible)
                }
            }
            .navigationTitle(isBrandVisible ? "" : "Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search your collection")
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
