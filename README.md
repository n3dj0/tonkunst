# Tonkunst

Tonkunst is a native SwiftUI iPhone/iPad music client for a Jellyfin collection.

## Included

- LAN Jellyfin sign-in (including `http://` servers), with successful server connections and access tokens stored in the iOS Keychain
- Saved account selection after sign-out, with support for adding or forgetting accounts
- Songs, Artists, Queue, Offline, and Search tabs
- Connection status that changes from Jellyfin-connected to offline-only
- Native `AVPlayer` playback, lock-screen controls, background audio, transport controls, shuffle, repeat, seek, and AirPlay
- Jellyfin universal AAC/M4A playback URLs so files such as MP3, AAC, FLAC, M4A, and Opus can be served in an iOS-compatible form
- Download/remove music for offline playback, stored in Files under **On My iPhone → Tonkunst → Artist → Album**, with an `iphone.gen3` availability indicator. Existing downloads are moved there when the app starts.
- Light and dark mode through SwiftUI’s system materials and semantic colors

## Run

1. Open `Tonkunst.xcodeproj` in Xcode 16 or later.
2. Choose an iOS 17+ simulator or a signed physical iPhone/iPad and run.
3. Open the account avatar and enter the LAN host of your Jellyfin server, for example `192.168.1.25`, select HTTP and port `8096`, then enter your Jellyfin account credentials.

At launch, Tonkunst shows its opening interface while the saved account and offline files restore in the background. Downloaded songs are available while the server refresh completes. Lock-screen media controls initialize when playback first starts. To check cold-start behavior, terminate the app and launch it from the Home Screen without the debugger, both with and without network access and with a populated offline library.

After a successful sign-in, Tonkunst keeps the server address and Jellyfin access token in the Keychain. Sign Out ends the active session while leaving that saved account available to reconnect without entering the server or password again. The account screen also lets you add another account or swipe a saved account to forget it.

The app permits local HTTP because many home Jellyfin servers do not have TLS configured. For distribution, prefer HTTPS whenever your Jellyfin setup supports it.

Manual library refreshes have a 10-second cooldown after each attempt, including failures. The account screen shows a countdown until refreshing is available again. Pull to refresh shares the same limit, and overlapping library requests are ignored. Automatic connection refreshes can run during the manual cooldown.

You can copy downloaded audio from Files. Keep the files in their Tonkunst folders if you want the app to continue playing them offline.

## Queue and playback

Long-press a song in any song list and choose **Add to Queue**. The Queue holds up to 1,000 upcoming occurrences and the latest 100 played occurrences. Duplicate songs are supported. Tap a song in the library to play it immediately while retaining upcoming songs. With no current song, use **Start Queue**.

The Queue opens centered on the bold current song. Upcoming songs are above it, with the next song closest to the current song. Shaded played songs are below, newest first. Long-press for **Play Next**, **Delete from Queue**, **Move Up**, or **Move Down**. Movement follows the visual direction within upcoming or played songs; the current song remains the boundary. Play Next on a played/current song adds a new occurrence. Deleting the current song advances playback. The Queue is saved on this device after each change and restored after app relaunch, including history, the current song, and upcoming songs. Playback stays paused and resumes the current song from its beginning. Each account has its own saved Queue; switching accounts or signing out does not delete it. It does not sync to Jellyfin.

Shuffle randomizes upcoming songs when enabled; turning it off retains that visible order. Previous returns to a played song (or restarts after four seconds), placing the current song back in upcoming; at the upcoming limit it restarts instead. Repeat cycles Off → All songs → One song. All replays retained history and the current song after upcoming songs finish. One repeats on completion; Next still advances. Unavailable songs remain queued and are skipped until playable.

Run `Tests/run-playback-tests.sh` for Queue limits, duplicates, history, ordering, repeat, and removal regression tests.

## Ambient backgrounds

Tap the **Tonkunst** wordmark in any tab's header to cycle through Standard → Aurora → Dusk → Lagoon → Ember → Standard. The selection is saved on the device and shared across tabs, detail screens, and sheets. Standard retains the system light/dark background; each gradient adapts to the current appearance and drifts over a two-minute cycle.

The wordmark remains visually unchanged and is a labeled, 44-point-high button for VoiceOver and other assistive controls. Reduce Motion freezes the gradient. Reduce Transparency freezes and further mutes it; Increase Contrast strengthens the neutral background overlay. Animation pauses while the app is inactive. Gradient modes make list and form rows transparent so the animation covers the entire screen, including beneath Liquid Glass controls. Standard restores the native row backgrounds.

For visual QA, cycle all five choices in light and dark mode, including populated lists, search results, Queue actions, Account & Settings, and Now Playing. Check persistence after relaunch, VoiceOver's background value, and the Reduce Motion, Reduce Transparency, and Increase Contrast settings.
