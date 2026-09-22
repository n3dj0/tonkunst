# Tonkunst

Tonkunst is a native SwiftUI iPhone/iPad music client for a Jellyfin collection.

## Included

- LAN Jellyfin sign-in (including `http://` servers), with successful server connections and access tokens stored in the iOS Keychain
- Saved account selection after sign-out, with support for adding or forgetting accounts
- Songs, Artists, Playlists, Offline, and Search tabs
- Connection status that changes from Jellyfin-connected to offline-only
- Native `AVPlayer` playback, lock-screen controls, background audio, transport controls, shuffle, repeat, seek, and AirPlay
- Jellyfin universal AAC/M4A playback URLs so files such as MP3, AAC, FLAC, M4A, and Opus can be served in an iOS-compatible form
- Download/remove music for offline playback, stored in Files under **On My iPhone → Tonkunst → Artist → Album**, with an `iphone.gen3` availability indicator. Existing downloads are moved there when the app starts.
- Light and dark mode through SwiftUI’s system materials and semantic colors

## Run

1. Open `Tonkunst.xcodeproj` in Xcode 16 or later.
2. Choose an iOS 17+ simulator or a signed physical iPhone/iPad and run.
3. Open the account avatar and enter the LAN host of your Jellyfin server, for example `192.168.1.25`, select HTTP and port `8096`, then enter your Jellyfin account credentials.

After a successful sign-in, Tonkunst keeps the server address and Jellyfin access token in the Keychain. Sign Out ends the active session while leaving that saved account available to reconnect without entering the server or password again. The account screen also lets you add another account or swipe a saved account to forget it.

The app permits local HTTP because many home Jellyfin servers do not have TLS configured. For distribution, prefer HTTPS whenever your Jellyfin setup supports it.

You can copy downloaded audio from Files. Keep the files in their Tonkunst folders if you want the app to continue playing them offline.

## Playlists

Create a playlist with **+** in the Playlists tab, then add songs. Use **Edit** to reorder or remove songs, **Rename** to change its name, or swipe a playlist to delete it. Playlist playback follows its own order, including repeated songs. Long-press a song in a playlist to download it for offline listening.

Playlists and the song catalog are cached separately for each server/account. Offline edits and deletions survive app restarts and sync when Tonkunst reconnects. While the app is running, it checks for playlist changes roughly once a minute; pull to refresh for an immediate sync. Syncing requires access to Jellyfin and permission to edit the playlist. Audio downloads are separate from playlist syncing.

If both the device and server changed a playlist since the last sync, open it to choose **Use Server Version** or **Keep Both Versions**. Keeping both saves the device version as a new private playlist. An interrupted creation request requires review before retrying, since Jellyfin may already have created the playlist. Check the refreshed list before choosing **Try Creating Again**.

Playlist updates use Jellyfin's `POST /Playlists/{id}` endpoint with the name and ordered song IDs, leaving sharing settings unchanged. Servers must support that update endpoint. Conflict checks compare the last synced version with the fetched server version; Jellyfin does not provide an atomic compare-and-swap here, so simultaneous edits during a sync can still race.

Run the offline sync regression tests with `Tests/run-playlist-tests.sh` on macOS. These exercise the real persistence and sync coordinator with a mock server; live Jellyfin integration needs a connected server.
