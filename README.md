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
