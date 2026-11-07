import Foundation
import Observation
import Synchronization
import Testing
@testable import TonkunstCore

@Suite(.serialized)
@MainActor
struct OfflineLibraryTests {
    @Test func legacyMetadataMigrationRemovesCredentials() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.close() }
        let track = testTrack()
        let audio = fixture.root.appendingPathComponent("old.wav")
        try waveAudio().write(to: audio)
        fixture.defaults.set([track.id: audio.path], forKey: "offlineTrackManifest")
        fixture.defaults.set(try JSONEncoder().encode([track.id: track]), forKey: "offlineTrackMetadata")
        let library = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile())
        try await library.restore()
        #expect(library.localURL(for: track) != nil)
        let data = try Data(contentsOf: fixture.root.appendingPathComponent("offline-library.json"))
        #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
        #expect(library.savedTracks[track.id]?.streamURL?.query == nil)
    }

    @Test func duplicateDownloadsUseOneRequestAndPublishAvailability() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.close() }
        let gate = DownloadGate(root: fixture.root)
        let library = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile(), download: { try await gate.download($0) })
        let changed = Mutex(false)
        #expect(library.isEmpty)
        let initialRevision = library.contentRevision
        let contentChanged = Mutex(false)
        withObservationTracking {
            _ = library.contentRevision
        } onChange: {
            contentChanged.withLock { $0 = true }
        }
        withObservationTracking {
            _ = library.contains(testTrack())
        } onChange: {
            changed.withLock { $0 = true }
        }
        let first = Task { try await library.download(testTrack()) }
        await gate.waitUntilStarted()
        #expect(library.downloading == [testTrack().id])
        #expect(library.contentRevision == initialRevision)
        try await library.download(testTrack())
        #expect(await gate.count == 1)
        await gate.release()
        try await first.value
        #expect(library.downloading.isEmpty)
        #expect(library.localURL(for: testTrack()) != nil)
        #expect(!library.isEmpty)
        #expect(changed.withLock { $0 })
        #expect(contentChanged.withLock { $0 })
        #expect(library.contentRevision != initialRevision)
        let downloadedRevision = library.contentRevision
        let metadata = try Data(contentsOf: fixture.root.appendingPathComponent("offline-library.json"))
        #expect(!String(decoding: metadata, as: UTF8.self).contains("secret"))
        try await library.remove(testTrack())
        #expect(!library.contains(testTrack()))
        #expect(library.isEmpty)
        #expect(library.contentRevision != downloadedRevision)
        let removedRevision = library.contentRevision
        library.selectAccount(nil)
        #expect(library.contentRevision != removedRevision)
    }

    @Test func cancellationCleansTemporaryFileWithoutRetry() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.close() }
        let gate = DownloadGate(root: fixture.root)
        let library = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile(), download: { try await gate.download($0) })
        let task = Task { try await library.download(testTrack()) }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await gate.count == 1)
        #expect(library.downloading.isEmpty)
        #expect(!library.contains(testTrack()))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("response.wav").path))
    }

    @Test func destinationFailureCleansValidatedStagingFile() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.close() }
        let rootFile = fixture.root.appendingPathComponent("not-a-folder")
        try Data().write(to: rootFile)
        let before = try stagedDownloads()
        let library = OfflineLibrary(documentsRoot: rootFile, defaults: fixture.defaults, profile: testProfile(), download: { url in
            let file = fixture.root.appendingPathComponent("response.wav")
            try waveAudio().write(to: file)
            return (file, try response(for: url))
        })
        await #expect(throws: (any Error).self) { try await library.download(testTrack()) }
        #expect(try stagedDownloads() == before)
        #expect(library.downloading.isEmpty)
        #expect(!library.contains(testTrack()))
    }

    @Test func removingFileAlreadyDeletedInFilesClearsManifest() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.close() }
        let file = fixture.root.appendingPathComponent("old.wav")
        try waveAudio().write(to: file)
        fixture.defaults.set([testTrack().id: file.path], forKey: "offlineTrackManifest")
        fixture.defaults.set(try JSONEncoder().encode([testTrack().id: testTrack()]), forKey: "offlineTrackMetadata")
        let library = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile())
        try await library.restore()
        try FileManager.default.removeItem(at: #require(library.localURL(for: testTrack())))
        try await library.remove(testTrack())
        #expect(!library.contains(testTrack()))
        #expect(library.tracks.isEmpty)
    }

    @Test func replacementAndNetworkFailurePreserveOwnedAudio() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.close() }
        let source = ImmediateDownloads(root: fixture.root)
        let library = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile(),
                                     download: { try await source.download($0) })
        try await library.download(testTrack())
        let original = try #require(library.localURL(for: testTrack()))
        try await library.download(testTrack())
        #expect(library.localURL(for: testTrack()) == original)
        #expect(try Data(contentsOf: original) == waveAudio())
        await source.failNextRequest()
        await #expect(throws: URLError.self) { try await library.download(testTrack()) }
        #expect(library.localURL(for: testTrack()) == original)
        #expect(try Data(contentsOf: original) == waveAudio())
        #expect(library.downloading.isEmpty)
    }

    @Test func identicalItemIDsAreIsolatedAcrossAccountsAndRelaunches() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.close() }
        let source = ImmediateDownloads(root: fixture.root)
        let library = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile(),
                                     download: { try await source.download($0) })
        try await library.download(testTrack())
        let firstURL = try #require(library.localURL(for: testTrack()))
        var otherProfile = testProfile()
        otherProfile.baseURL = "https://another.example/jellyfin"
        var otherTrack = testTrack()
        otherTrack.accountID = otherProfile.id
        library.selectAccount(otherProfile)
        try await library.restore()
        #expect(!library.contains(testTrack()))
        #expect(!library.contains(otherTrack))
        try await library.download(otherTrack)
        let otherURL = try #require(library.localURL(for: otherTrack))
        #expect(firstURL != otherURL)
        #expect(!library.contains(testTrack()))
        try await library.remove(otherTrack)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        let restored = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile())
        try await restored.restore()
        #expect(restored.localURL(for: testTrack()) == firstURL)
        #expect(!restored.contains(otherTrack))
    }

    @Test func switchingAccountsDuringDownloadDoesNotPublishOtherAccountsFiles() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.close() }
        let gate = DownloadGate(root: fixture.root)
        let library = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile(),
                                     download: { try await gate.download($0) })
        let first = Task { try await library.download(testTrack()) }
        await gate.waitUntilStarted()
        var other = testProfile()
        other.userID = "other-user"
        library.selectAccount(other)
        try await library.restore()
        await gate.release()
        try await first.value
        #expect(library.tracks.isEmpty)
        #expect(library.downloading.isEmpty)
        library.selectAccount(testProfile())
        try await library.restore()
        #expect(library.contains(testTrack()))
    }

    @Test func legacyOwnershipIsInferredOnlyFromCompleteJellyfinURLs() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.close() }
        var known = testTrack("known")
        known.accountID = nil
        known.fallbackStreamURL = URL(string: "https://music.example/jellyfin/Audio/known/stream?UserId=user&api_key=secret")
        var unknown = testTrack("unknown")
        unknown.accountID = nil
        let knownFile = fixture.root.appendingPathComponent("known.wav")
        let unknownFile = fixture.root.appendingPathComponent("unknown.wav")
        try waveAudio().write(to: knownFile)
        try waveAudio().write(to: unknownFile)
        fixture.defaults.set([known.id: knownFile.path, unknown.id: unknownFile.path], forKey: "offlineTrackManifest")
        fixture.defaults.set(try JSONEncoder().encode([known.id: known, unknown.id: unknown]), forKey: "offlineTrackMetadata")
        let library = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile())
        try await library.restore()
        #expect(library.contains(known))
        #expect(!library.contains(unknown))
        #expect(library.unassignedDownloadCount == 1)
        #expect(fixture.defaults.data(forKey: "offlineTrackMetadata") == nil)
        let archive = try Data(contentsOf: fixture.root.appendingPathComponent("offline-library.json"))
        #expect(!String(decoding: archive, as: UTF8.self).contains("secret"))
        #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).contains { $0.contains("unknown") })
    }

    @Test func manifestFailureDoesNotPublishOrLeaveANewAudioFile() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.close() }
        let blocked = fixture.root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let source = ImmediateDownloads(root: fixture.root)
        let library = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile(),
            manifestURL: blocked.appendingPathComponent("manifest.json"), download: { try await source.download($0) })
        await #expect(throws: (any Error).self) { try await library.download(testTrack()) }
        #expect(!library.contains(testTrack()))
        #expect(library.downloading.isEmpty)
        let paths = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path)
        #expect(!paths.contains { $0.hasSuffix(".wav") })
    }

    @Test func failedMigrationKeepsOriginalFilesAndCanBeRetried() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.close() }
        let audio = fixture.root.appendingPathComponent("legacy.wav")
        try waveAudio().write(to: audio)
        fixture.defaults.set([testTrack().id: audio.path], forKey: "offlineTrackManifest")
        fixture.defaults.set(try JSONEncoder().encode([testTrack().id: testTrack()]), forKey: "offlineTrackMetadata")
        let blocked = fixture.root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let failed = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile(),
                                    manifestURL: blocked.appendingPathComponent("manifest.json"))
        await #expect(throws: (any Error).self) { try await failed.restore() }
        #expect(try Data(contentsOf: audio) == waveAudio())
        #expect(fixture.defaults.data(forKey: "offlineTrackMetadata") != nil)
        let retry = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile())
        try await retry.restore()
        #expect(retry.localURL(for: testTrack()) != nil)
        #expect(fixture.defaults.data(forKey: "offlineTrackMetadata") == nil)
    }

    @Test func relativePathsSurviveSandboxContainerChanges() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.close() }
        let source = ImmediateDownloads(root: fixture.root)
        let library = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile(),
                                     download: { try await source.download($0) })
        try await library.download(testTrack())
        let originalURL = try #require(library.localURL(for: testTrack()))
        let manifest = fixture.root.appendingPathComponent("offline-library.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var accounts = try #require(json["accounts"] as? [String: [String: [String: Any]]])
        accounts[testProfile().id]?[testTrack().id]?["url"] = "file:///old/sandbox/unavailable.wav"
        json["accounts"] = accounts
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        let restored = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile())
        try await restored.restore()
        #expect(restored.localURL(for: testTrack()) == originalURL)
    }

    @Test func failedDeletionSaveRestoresAudioAndAvailability() async throws {
        let fixture = try OfflineFixture()
        defer { fixture.close() }
        let stateFolder = fixture.root.appendingPathComponent("state")
        let source = ImmediateDownloads(root: fixture.root)
        let library = OfflineLibrary(documentsRoot: fixture.root, defaults: fixture.defaults, profile: testProfile(),
            manifestURL: stateFolder.appendingPathComponent("offline.json"), download: { try await source.download($0) })
        try await library.download(testTrack())
        let audio = try #require(library.localURL(for: testTrack()))
        try FileManager.default.removeItem(at: stateFolder)
        try Data().write(to: stateFolder)
        await #expect(throws: (any Error).self) { try await library.remove(testTrack()) }
        #expect(library.contains(testTrack()))
        #expect(try Data(contentsOf: audio) == waveAudio())
    }

    private func stagedDownloads() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("tonkunst-") })
    }
}

@MainActor
private struct OfflineFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "com.tonkunst.tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }
    func close() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor DownloadGate {
    let root: URL
    private(set) var count = 0
    private var started: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    init(root: URL) { self.root = root }
    func waitUntilStarted() async {
        if count == 0 { await withCheckedContinuation { started = $0 } }
    }
    func release() { completion?.resume(); completion = nil }
    func download(_ url: URL) async throws -> (URL, URLResponse) {
        count += 1
        await withCheckedContinuation { continuation in
            completion = continuation
            started?.resume()
            started = nil
        }
        let file = root.appendingPathComponent("response.wav")
        try waveAudio().write(to: file)
        return (file, try response(for: url))
    }
}

private actor ImmediateDownloads {
    let root: URL
    private var shouldFail = false
    init(root: URL) { self.root = root }
    func failNextRequest() { shouldFail = true }
    func download(_ url: URL) throws -> (URL, URLResponse) {
        if shouldFail { throw URLError(.notConnectedToInternet) }
        let file = root.appendingPathComponent("\(UUID().uuidString).wav")
        try waveAudio().write(to: file)
        return (file, try response(for: url))
    }
}

private func response(for url: URL) throws -> HTTPURLResponse {
    try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
}

private func waveAudio() -> Data {
    // 100 ms of 8 kHz, mono, 16-bit PCM; AVFoundation validates real local audio.
    var result = Data("RIFF".utf8)
    func append<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
    }
    append(UInt32(36 + 1600))
    result.append(Data("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(UInt32(8000))
    append(UInt32(16000))
    append(UInt16(2))
    append(UInt16(16))
    result.append(Data("data".utf8))
    append(UInt32(1600))
    result.append(Data(repeating: 0, count: 1600))
    return result
}
