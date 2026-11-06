# Swift / SwiftUI review — 6 November 2026

## Executive Summary

**Baseline health: 5/10.** The app has a useful value-based queue, main-actor UI state, Keychain account storage, atomic queue writes, and working queue regression tests. Its main risks are credential-bearing offline metadata, reentrant downloads, stale playback callbacks, and concurrency isolation that Swift 5 mode does not enforce. The compact codebase does not need Clean Architecture or a framework migration; it needs explicit service boundaries and ownership.

**First implementation batch: 6/10.** Seven tasks were implemented in the initial pass.

**Implementation update — 7 November 2026:** The remaining code changes are now implemented: account-scoped downloads with conservative migration, serialized persistence, a testable playback controller and platform adapters, typed API/storage errors, English/German localization, adaptive player layout, and privacy declarations. The score above is historical; hardware validation and profiling still need to be performed. Findings below describe the original baseline; the checklist records the current status.

Scope: all 11 Swift source files, the existing queue test harness, Info.plist, and Xcode build settings. Baseline queue tests passed. Initial Swift 6 checking fails at UIKit access in JellyfinAPI's default property initializer. Baseline line references below identify the reviewed implementation before edits.

## Critical Issues / Bugs

- **P1 — Credentials outside Keychain.** `OfflineLibraryDisk.saveManifest` encodes complete MediaTrack URLs into UserDefaults, including `api_key`. Old values must be scrubbed during restoration as well as on new writes. Queue persistence already removes its tokens. (`OfflineLibrary.swift:269–301`)
- **P1 — Download reentrancy and data loss.** Repeated actions can download the same ID concurrently; asynchronous validation allows competing callers to remove or replace one another's files. The staging cleanup is registered after destination creation, so a destination error leaks a temporary audio file. Removal errors are ignored while the app reports success. (`OfflineLibrary.swift:25–59,119–127`)
- **P1 — Cross-account download collisions.** Offline manifests and filenames use Jellyfin item ID without server/account identity. Two servers with the same ID can resolve to the wrong local audio; switching accounts also exposes a device-wide offline library. Introduce account-scoped identity and a conservative migration for existing files. (`OfflineLibrary.swift:6–23,191–203`; `MusicStore.swift:129–132`)
- **P1 — Playback command/callback ordering.** Lock-screen Play and Pause both toggle, so repeated Play can pause. Resume's asynchronous audio activation targets whichever player happens to be current when it finishes. Periodic callbacks lack player identity validation. (`MusicStore.swift:328–347,454–456,595–600`)
- **P1 — Swift 6 isolation.** A nonisolated service initializes UIKit state; detached restoration captures UserDefaults in a worker; Dispatch completion closures need Sendable semantics and teardown must respect actor isolation. Enable real compiler enforcement after fixes. (`JellyfinAPI.swift:17–19`; `OfflineLibrary.swift:137–147`; `MusicStore.swift:107–115,577–587`)
- **P2 — Cancellation and task ownership.** The API converts cancellation into server-unavailable errors; download validation converts cancellation into a format failure and may retry. Connection and playback recovery tasks are unowned; the health loop promotes weak self across its sleep, retaining the store during repeated checks. (`JellyfinAPI.swift:208–215`; `OfflineLibrary.swift:80–92`; `MusicStore.swift:220–228,254–261,502–521,560–574`)
- **P2 — Crash-prone assumptions.** Force-unwrapped normalized URLs/components in the API, queue account, failed track, and enum indexing are avoidable. Converting nonfinite/out-of-range duration values to Int can trap. (`JellyfinAPI.swift:69–114`; `MusicStore.swift:48,492`; `MediaModels.swift:44`; `PlayerViews.swift:124`; `Components.swift:111`)

## Architecture & Code Smells

- **P2 — Broad observation and duplicated state.** Every EnvironmentObject reader subscribes to all MusicStore changes, including progress every half second. The nested OfflineLibrary publishes independently, so its changes are not automatically forwarded by the parent. `isDownloaded` duplicates the manifest; `currentTrack` duplicates queue current state. Prefer property-based Observation, read-only public state, and explicit playback/session boundaries.
- **P2 — Main-actor persistence.** Every queue mutation decodes and rewrites all accounts synchronously. Download commit/reconciliation, manifest encoding, file probes, and post-sign-in Keychain operations also run on the main actor. Move disk ownership into a serial persistence actor with ordered writes, error delivery and flush semantics before moving code off-thread.
- **P2 — Weak seams for tests.** API, Keychain, player, defaults and disk storage are constructed internally. Extract narrow injected interfaces; keep the queue as a value type. Add deterministic URLProtocol tests and controllable playback/download clients.
- **P2 — Error reporting.** Refresh conflates HTTP/authentication, decoding and connectivity failures. A corrupt queue blocks subsequent saves. Surface recoverable failures with typed errors and an explicit recovery path; preserve the corrupt archive before resetting it.
- **P3 — API/readability.** Jellyfin DTOs expose wire-format PascalCase; use CodingKeys with idiomatic Swift properties. Dense single-line UI and playback functions hide control flow. Combine/Dispatch are not intrinsically defects: KVO, serial AVAudioSession work and framework bridges can remain when their lifetime and isolation are explicit.
- **P3 — Localization.** SwiftUI literal Text is generally extractable, but computed String labels, LocalizedError descriptions, metadata fallbacks, enum labels and formatted strings lack a String Catalog/localization path. Adopt String(localized:) and plural-aware resources, then verify an actual second locale. No translation files currently exist.

## Performance & SwiftUI Polish

- Move from whole-object invalidation to property-based observation; then profile before adding caches.
- Avoid synchronous filesystem probes and full-library sorting/grouping during unrelated playback updates. Persisted download metadata should be the UI source; validate files at restoration/playback boundaries.
- Artist detail receives a tracks snapshot; derive it from current store data so refreshes and removals appear immediately.
- MiniPlayer nests transport Buttons inside a Button, with undersized unlabeled icon targets. Use sibling controls with explicit labels and adequate touch targets.
- Now Playing has a fixed sheet height and a non-scrolling VStack; audit small devices, landscape and accessibility text sizes. Debounce slider seeking rather than submitting a seek for every drag update.
- Ambient animation already respects Reduce Motion, Reduce Transparency, contrast and scene phase. Check energy use of the 15 Hz gradient and multiple mounted tabs with Instruments; no measured redraw or memory claim is made here.

## Security & Privacy

Keychain uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; no hardcoded credentials were found. Local-network purpose text and background-audio capability are present. HTTP is an intentional LAN feature and carries credentials in plaintext on that connection. Both NSAllowsArbitraryLoads and NSAllowsLocalNetworking are present; on current iOS, the local-network key overrides the broad key, so this is not evidence that ATS is globally disabled. Remove the obsolete broad declaration and verify LAN HTTP on a device. Add the required-reason UserDefaults privacy declaration before distribution and review actual device identifier usage. Avoid endpoint logging.

References: [Swift 6 adoption](https://developer.apple.com/documentation/swift/adoptingswift6), [SwiftUI Observation](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app), [ATS local networking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

## Prioritized to-do list

First implementation batch:

- [x] R1: Strip credentials from offline metadata, including migration; share the queue's URL sanitization and test persistence.
- [x] R2: Deduplicate in-flight downloads; preserve cancellation, clean staging files, replace owned files safely, and propagate deletion failures.
- [x] R3: Make Play/Pause idempotent, guard asynchronous playback callbacks, retain/remove command registrations, and remove unsafe unwraps.
- [x] R4: Own/cancel connection and playback recovery tasks; preserve network cancellation and release the store between health checks.
- [x] R5: Use property-based Observation and restrict externally mutable state; derive artist detail from current data. Removed the unused isDownloaded flag so the manifest owns availability.
- [x] R6: Remove API URL force unwraps, guard invalid time values, inject API device identity/session, and enable Swift 6 checking.
- [x] R7: Fix MiniPlayer control structure and accessibility labels/targets.
- [x] R8: Added Swift Testing coverage for playback intent, delayed callbacks, interruptions, account collisions/switching, migration failures/retries, relative paths, corrupt Queue recovery, API errors, and German localization/plurals. The legacy Queue harness is retained. Packaged-app and hardware validation are tracked separately below.

Second implementation batch:

- [x] R9: Download archives and file paths are scoped by server/account. Legacy ownership is inferred only from explicit account metadata or complete Jellyfin audio URLs. Ambiguous files stay in Files, counted in Account & Settings, and never become the current account's downloads. Migration copies before committing the archive; a failed commit leaves the original paths intact.
- [x] R10: QueueRepository and OfflineRepository serialize file access off MainActor. Queue saves are ordered and flushed on backgrounding. AccountRepository moves Keychain reads/writes off the UI thread. PlaybackController owns playback intent/state; AVPlayerDriver, AudioSessionService and SystemMediaControls handle platform behavior. MusicStore derives currentTrack from queue.current rather than storing a second selection.
- [x] R11: Added English/German String Catalogs with plural variants, localized computed labels/errors and permission text, and lowerCamelCase DTOs with CodingKeys. HTTP 401/403, server errors, malformed responses and cancellation remain distinct. Expired sessions stop background reconnect attempts. Corrupt Queue archives are backed up before starting a new Queue. Manifest failures propagate; failed deletion saves restore the original audio.
- [x] R12: Now Playing scrolls and uses separate transport rows with adequate targets. Scrubbing previews locally and seeks once at the end; VoiceOver adjusts in five-second steps. Only the position subview observes progress ticks. Playback pauses on headphone removal and follows interruption resume permission without overriding a manual pause.
- [x] R13: Added the app-only UserDefaults required reason (CA92.1), declared no tracking, localized the LAN purpose string, and removed the obsolete NSAllowsArbitraryLoads key while retaining NSAllowsLocalNetworking. Jellyfin now receives a random installation identifier rather than identifierForVendor.

Remaining validation (requires a working app build/device environment):

- [ ] Build, link and launch the packaged iOS app; current Icon Composer export is blocked by inaccessible CoreSimulator services.
- [ ] Check lock-screen commands, AirPlay, real interruptions/headphone removal and LAN HTTP/HTTPS against a Jellyfin server.
- [ ] Check VoiceOver, German text, accessibility text sizes, landscape, cold launch and Files behavior on iPhone/iPad.
- [ ] Profile scrolling, main-thread activity, memory and gradient energy use with Instruments. Confirm App Store privacy answers against the final distribution configuration.

## Refactored Code

Production changes are in the source, rather than examples waiting to be integrated:

| Area | Implementation |
| --- | --- |
| Credential sanitization and safe time conversion | [MediaModels.swift](Tonkunst/Models/MediaModels.swift) |
| URL construction, injected transport and cancellation | [JellyfinAPI.swift](Tonkunst/Services/JellyfinAPI.swift) |
| Download ownership, replacement, cleanup and migration | [OfflineLibrary.swift](Tonkunst/Services/OfflineLibrary.swift) |
| Queue/session orchestration and ordered background saves | [MusicStore.swift](Tonkunst/Store/MusicStore.swift) |
| Playback intent and injected driver/session interfaces | [PlaybackController.swift](Tonkunst/Services/PlaybackController.swift) |
| AVPlayer, AVAudioSession, remote commands and system interruptions | [SystemPlayback.swift](Tonkunst/Services/SystemPlayback.swift) |
| Sibling transport controls and touch targets | [PlayerViews.swift](Tonkunst/Views/PlayerViews.swift) |
| Fresh artist detail data and environment migration | [LibraryViews.swift](Tonkunst/Views/LibraryViews.swift) |
| Swift Testing harness | [Package.swift](Package.swift), [core tests](Tests/CoreTests) |

PlaybackController owns separate identities for a loaded driver and the latest playback intent. A pause, stop, replacement or canceled activation invalidates the previous intent. Its injected driver/session interfaces let tests hold an activation open and deliver old callbacks deterministically. Remote Play and Pause call separate idempotent operations.

OfflineRepository owns account-indexed records and filesystem transactions. The facade applies returned snapshots only if their account generation and revision are current, so a download that finishes after an account switch is saved for its original account without appearing in the new account. Credentials are removed before encoding. Migration retains legacy defaults until the new archive is saved successfully.

The app's framework adapters remain on MainActor. AVAudioSession activation uses a serial Dispatch queue behind an async interface. File work, JSON encoding/decoding and Keychain operations run in their respective actors.

### Validation

- `swift test`: 32 tests in five suites passed, including parameterized time/address/HTTP cases, injected playback clients, real local WAV validation, migration/save failures and German plurals (macOS 15+ core-services harness).
- `Tests/run-playback-tests.sh`: selection, occurrence identity, queue limits, repeat, ordering, account queue isolation and token-free persistence passed.
- All 13 application Swift files compiled to arm64 iOS 26 machine code with `-swift-version 6 -strict-concurrency=complete`, both `-Onone -g` and `-O`, using the installed Xcode 27.2 SDK. No Swift diagnostics.
- English/German String Catalogs compile; compiler-extracted localization keys are covered. Privacy and project property lists pass `plutil -lint`.
- `git diff --check`: passed.
- A full generic-device Xcode build was attempted. Icon Composer/asset catalog export fails while CoreSimulator services are inaccessible. App linking, signing, launch, lock-screen commands, audio interruptions and visual QA were not verified. Swift compilation was validated separately; this is not a successful packaged-app build.

The README reflects the actual iOS 26 deployment target and Xcode 26 / Swift 6.2 minimum. No new permissions were requested, no user accounts or Queues were reset, and tests did not download from a real Jellyfin server. Privacy references: [required UserDefaults reason](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons), [local ATS exception](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).
