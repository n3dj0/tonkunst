import Foundation
import Synchronization
import Testing
@testable import TonkunstCore

struct MediaAndAPITests {
    @Test(arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1])
    func invalidTimesDoNotTrap(_ value: Double) {
        #expect(PlaybackTime.formatted(value) == "0:00")
    }

    @Test func durationFormatting() {
        #expect(PlaybackTime.formatted(125.9) == "2:05")
        #expect(PlaybackTime.formatted(3600) == "60:00")
    }

    @Test func credentialsAreRemovedFromEveryMediaURL() throws {
        let url = try #require(URL(string: "https://user:password@music.example/song?API_KEY=old&api_key=duplicate&tag=cover"))
        var track = testTrack()
        track.artworkURL = url
        track.streamURL = url
        track.fallbackStreamURL = url
        let clean = track.authorizing(with: nil)
        let data = try JSONEncoder().encode(clean)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("password"))
        #expect(!json.contains("old"))
        #expect(!json.contains("duplicate"))
        for url in [clean.artworkURL, clean.streamURL, clean.fallbackStreamURL] {
            let url = try #require(url)
            let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(parts.queryItems == [URLQueryItem(name: "tag", value: "cover")])
        }
        let renewed = clean.authorizing(with: "a token&with=reserved?#")
        let renewedURL = try #require(renewed.streamURL)
        let parts = try #require(URLComponents(url: renewedURL, resolvingAgainstBaseURL: false))
        #expect(parts.queryItems?.filter { $0.name == "api_key" }.map(\.value) == ["a token&with=reserved?#"])
    }

    @Test func mediaURLsEncodeTokensAndRetainServerBasePath() throws {
        let api = JellyfinAPI(deviceID: "test-device")
        var profile = testProfile()
        profile.accessToken = "token&another=value?#"
        let item = JellyfinItem(id: "song", name: "  ", runTimeTicks: -10,
                                album: "", albumArtist: " ", artists: ["Artist"],
                                container: "mov,mp4,m4a", userData: nil)
        let track = try api.track(from: item, profile: profile)
        #expect(track.title == String(localized: "Unknown Song", bundle: AppLocalization.bundle))
        #expect(track.artist == "Artist")
        #expect(track.album == String(localized: "Unknown Album", bundle: AppLocalization.bundle))
        #expect(track.duration == 0)
        #expect(track.fileExtension == "m4a")
        for url in [track.artworkURL, track.streamURL, track.fallbackStreamURL] {
            let url = try #require(url)
            let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(parts.path.hasPrefix("/jellyfin/"))
            #expect(parts.queryItems?.first { $0.name == "api_key" }?.value == profile.accessToken)
            #expect(parts.queryItems?.contains { $0.name == "another" } == false)
        }
    }

    @Test(arguments: ["ftp://music.example", "https://", "https://user:password@music.example"])
    func invalidProfileThrowsInsteadOfCrashing(_ address: String) async throws {
        let api = JellyfinAPI(deviceID: "test-device")
        var profile = testProfile()
        profile.baseURL = address
        let item = JellyfinItem(id: "song", name: "Song", runTimeTicks: nil, album: nil,
                                albumArtist: nil, artists: nil, container: nil, userData: nil)
        #expect(throws: JellyfinError.invalidServer) { try api.track(from: item, profile: profile) }
        await #expect(throws: JellyfinError.invalidServer) {
            try await api.requestData(profile: profile, path: "Items")
        }
    }

    @Test func networkCancellationRemainsCancellation() async throws {
        let fixture = try APIFixture(reply: .failure(.cancelled))
        defer { fixture.close() }
        await #expect(throws: CancellationError.self) {
            try await fixture.api.ping(profile: fixture.profile)
        }
    }

    @Test func timeoutHasSpecificError() async throws {
        let fixture = try APIFixture(reply: .failure(.timedOut))
        defer { fixture.close() }
        await #expect(throws: JellyfinError.timedOut) {
            try await fixture.api.ping(profile: fixture.profile)
        }
    }

    @Test func cancelledRequestDoesNotReachTransport() async throws {
        let fixture = try APIFixture(reply: .response(Data("ok".utf8)))
        defer { fixture.close() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await fixture.api.ping(profile: fixture.profile)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(APIStub.count(for: fixture.host) == 0)
    }

    @Test(arguments: [401, 403, 503])
    func httpFailuresKeepTheirMeaning(_ status: Int) async throws {
        let fixture = try APIFixture(reply: .http(status, Data()))
        defer { fixture.close() }
        let expected = status >= 500 ? JellyfinError.serverError(status) : .sessionExpired
        await #expect(throws: expected) {
            try await fixture.api.requestData(profile: fixture.profile, path: "Items")
        }
    }

    @Test func malformedLibraryResponseIsReportedAsBadResponse() async throws {
        let fixture = try APIFixture(reply: .response(Data("invalid JSON".utf8)))
        defer { fixture.close() }
        await #expect(throws: JellyfinError.badResponse) {
            try await fixture.api.fetchSongs(profile: fixture.profile)
        }
    }
}

func testTrack(_ id: String = "song") -> MediaTrack {
    MediaTrack(id: id, title: "Song", artist: "Artist", album: "Album", duration: 60,
               streamURL: URL(string: "https://music.example/Audio/\(id)/universal?api_key=secret"),
               fallbackStreamURL: URL(string: "https://music.example/Audio/\(id)/stream?api_key=secret"),
               fileExtension: "wav", accountID: testProfile().id)
}

func testProfile() -> ServerProfile {
    ServerProfile(baseURL: "https://music.example/jellyfin", userID: "user", accessToken: "secret", displayName: "Listener")
}

private struct APIFixture {
    let host: String
    let session: URLSession
    let api: JellyfinAPI
    let profile: ServerProfile

    init(reply: APIStub.Reply) throws {
        host = "test-\(UUID().uuidString.lowercased()).invalid"
        APIStub.install(reply, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIStub.self]
        session = URLSession(configuration: configuration)
        api = JellyfinAPI(deviceID: "test-device", session: session)
        profile = ServerProfile(baseURL: "https://\(host)", userID: "user", accessToken: "secret", displayName: "Test")
    }

    func close() {
        session.invalidateAndCancel()
        APIStub.remove(host: host)
    }
}

// URLProtocol is an Objective-C bridge; all shared fixture state is mutex-protected.
private final class APIStub: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case response(Data)
        case http(Int, Data)
        case failure(URLError.Code)
    }
    private struct State {
        let reply: Reply
        var count = 0
    }
    private static let states = Mutex<[String: State]>([:])

    static func install(_ reply: Reply, host: String) {
        states.withLock { $0[host] = State(reply: reply) }
    }
    static func remove(host: String) { states.withLock { _ = $0.removeValue(forKey: host) } }
    static func count(for host: String) -> Int { states.withLock { $0[host]?.count ?? 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let reply = Self.states.withLock { states -> Reply? in
            guard var state = states[host] else { return nil }
            state.count += 1
            states[host] = state
            return state.reply
        }
        switch reply {
        case .response(let data):
            send(data, status: 200, url: url)
        case .http(let status, let data):
            send(data, status: status, url: url)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
        }
    }
    private func send(_ data: Data, status: Int, url: URL) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
