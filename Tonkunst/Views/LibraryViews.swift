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
}

private struct TonkunstBrand: View {
    var body: some View {
        Text("Tonkunst")
            .font(.system(size: 24, weight: .regular, design: .serif))
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
    private var songs: [MediaTrack] { filter.isEmpty ? store.tracks : store.tracks.filter { $0.matches(filter) } }
    var body: some View { NavigationStack { Group { if store.isRestoringSession { ProgressView("Opening Tonkunst…") } else if store.profile == nil { WelcomeView(showAccount: $showAccount) } else if store.isLoading && store.tracks.isEmpty { ProgressView("Loading your music…") } else if songs.isEmpty { if filter.isEmpty { ContentUnavailableView("No Songs Yet", systemImage: "music.note", description: Text(store.connectionAvailable ? "Your Jellyfin music library is empty." : "Connect to Jellyfin to browse your music.")) } else { ContentUnavailableView.search(text: filter) } } else { List(songs) { SongRow(track: $0) }.listStyle(.plain).tonkunstBrandVisibility($isBrandVisible).refreshable { await store.refresh() } } }.navigationTitle("Songs").searchable(text: $filter, prompt: "Songs, artists, albums").toolbar { ToolbarItem(placement: .topBarLeading) { if isBrandVisible { TonkunstBrand() } }.sharedBackgroundVisibility(.hidden); ToolbarItemGroup(placement: .topBarTrailing) { ConnectionPill(); AccountButton(showAccount: $showAccount) } } } }
}

struct ArtistsView: View {
    @EnvironmentObject private var store: MusicStore
    @Binding var showAccount: Bool
    @State private var filter = ""
    @State private var isBrandVisible = true

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
            .overlay {
                if artists.isEmpty {
                    if filter.isEmpty {
                        ContentUnavailableView("No Artists", systemImage: "person.2")
                    } else {
                        ContentUnavailableView.search(text: filter)
                    }
                }
            }
            .navigationTitle("Artists")
            .searchable(text: $filter, prompt: "Search artists")
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
            }
        }
        .navigationTitle(artist)
        .searchable(text: $filter, prompt: "Songs, albums")
    }
}

struct PlaylistsView: View {
    @Binding var showAccount: Bool
    var body: some View { NavigationStack { ContentUnavailableView("Your Playlists", systemImage: "music.note.list", description: Text("Jellyfin playlist sync will appear here as soon as playlists are added to your library.")).navigationTitle("Playlists").toolbar { ToolbarItem(placement: .topBarLeading) { TonkunstBrand() }.sharedBackgroundVisibility(.hidden); ToolbarItemGroup(placement: .topBarTrailing) { ConnectionPill(); AccountButton(showAccount: $showAccount) } } } }
}

struct OfflineView: View {
    @EnvironmentObject private var store: MusicStore
    @Binding var showAccount: Bool
    @State private var filter = ""
    @State private var isBrandVisible = true

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
                }
            }
            .navigationTitle("Offline")
            .searchable(text: $filter, prompt: "Songs, artists, albums")
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
            .navigationTitle("Search")
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
