import Foundation
import Testing
@testable import TonkunstCore

@MainActor
struct PlaybackControllerTests {
    @Test func pauseWhileActivationIsPendingCannotRestartPlayback() async throws {
        let session = TestAudioSession()
        let driver = TestDriver()
        let controller = PlaybackController(audioSession: session, factory: { _ in driver })
        controller.load(try #require(testTrack().streamURL), track: testTrack())
        await session.waitForActivation()
        controller.pause()
        session.completeActivation()
        await Task.yield()
        #expect(driver.playCount == 0)
        #expect(!controller.isPlaying)
    }

    @Test func playAndPauseCommandsAreIdempotent() async throws {
        let session = TestAudioSession()
        let driver = TestDriver()
        let controller = PlaybackController(audioSession: session, factory: { _ in driver })
        controller.load(try #require(testTrack().streamURL), track: testTrack())
        controller.resume()
        controller.resume()
        await session.waitForActivation()
        #expect(session.activationCount == 1)
        session.completeActivation()
        await driver.waitForPlay()
        controller.resume()
        #expect(driver.playCount == 1)
        controller.pause()
        controller.pause()
        #expect(!controller.isPlaying)
        #expect(driver.playCount == 1)
    }

    @Test func replacingTrackRejectsOldProgressAndFailureCallbacks() async throws {
        let session = TestAudioSession()
        var drivers: [TestDriver] = []
        let controller = PlaybackController(audioSession: session, factory: { _ in
            let driver = TestDriver()
            drivers.append(driver)
            return driver
        })
        var failures = 0
        controller.onEvent = { _ in failures += 1 }
        controller.load(try #require(testTrack().streamURL), track: testTrack())
        await session.waitForActivation()
        let oldProgress = drivers[0].onProgress
        let oldFailure = drivers[0].onFailure
        controller.load(try #require(testTrack("next").streamURL), track: testTrack("next"))
        oldProgress?(55)
        oldFailure?(URLError(.cannotDecodeContentData))
        #expect(controller.progress == 0)
        #expect(controller.hasDriver)
        #expect(failures == 0)
        session.completeActivation()
        // A stopped controller also rejects activation that ignores cancellation.
        controller.stop()
        await Task.yield()
        #expect(drivers.allSatisfy { $0.playCount == 0 })
    }

    @Test func seekingClampsValuesAndCompletionRestartsFromBeginning() async throws {
        let session = TestAudioSession(automatic: true)
        let driver = TestDriver()
        let controller = PlaybackController(audioSession: session, factory: { _ in driver })
        controller.load(try #require(testTrack().streamURL), track: testTrack())
        await driver.waitForPlay()
        controller.seek(to: .nan)
        #expect(driver.seeks.isEmpty)
        controller.seek(to: 1000)
        controller.seek(to: -20)
        #expect(driver.seeks == [60, 0])
        driver.onFinished?()
        #expect(!controller.isPlaying)
        controller.resume()
        #expect(driver.seeks.last == 0)
    }

    @Test func interruptionDoesNotOverrideUsersPause() async throws {
        let session = TestAudioSession(automatic: true)
        let driver = TestDriver()
        let controller = PlaybackController(audioSession: session, factory: { _ in driver })
        controller.load(try #require(testTrack().streamURL), track: testTrack())
        await driver.waitForPlay()
        controller.interruptionBegan()
        controller.pause()
        controller.interruptionEnded(shouldResume: true)
        await Task.yield()
        #expect(!controller.isPlaying)
        #expect(driver.playCount == 1)
    }

    @Test func systemInterruptionResumesOnlyWhenPermitted() async throws {
        let session = TestAudioSession(automatic: true)
        let driver = TestDriver()
        let controller = PlaybackController(audioSession: session, factory: { _ in driver })
        controller.load(try #require(testTrack().streamURL), track: testTrack())
        await driver.waitForPlay()
        controller.interruptionBegan()
        controller.interruptionEnded(shouldResume: false)
        #expect(!controller.isPlaying)
        controller.resume()
        await driver.waitForPlay(count: 2)
        controller.interruptionBegan()
        controller.interruptionEnded(shouldResume: true)
        await driver.waitForPlay(count: 3)
        #expect(controller.isPlaying)
    }
}

@MainActor
private final class TestDriver: PlaybackDriving {
    var onProgress: ((Double) -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?
    var onFinished: (() -> Void)?
    var onFailure: (((any Error)?) -> Void)?
    var playCount = 0
    var seeks: [Double] = []
    private var waiter: (Int, CheckedContinuation<Void, Never>)?
    func play() {
        playCount += 1
        if let (count, continuation) = waiter, playCount >= count { waiter = nil; continuation.resume() }
    }
    func pause() { }
    func seek(to seconds: Double) { seeks.append(seconds) }
    func waitForPlay(count: Int = 1) async {
        if playCount < count { await withCheckedContinuation { waiter = (count, $0) } }
    }
}

@MainActor
private final class TestAudioSession: AudioSessionActivating {
    let automatic: Bool
    var activationCount = 0
    private var activations: [CheckedContinuation<Void, Error>] = []
    private var started: CheckedContinuation<Void, Never>?
    init(automatic: Bool = false) { self.automatic = automatic }
    func activate() async throws {
        activationCount += 1
        if automatic { return }
        try await withCheckedThrowingContinuation { continuation in
            activations.append(continuation)
            started?.resume()
            started = nil
        }
    }
    func deactivate() { }
    func waitForActivation() async {
        if activationCount == 0 { await withCheckedContinuation { started = $0 } }
    }
    func completeActivation() {
        let pending = activations
        activations = []
        for continuation in pending { continuation.resume() }
    }
}
