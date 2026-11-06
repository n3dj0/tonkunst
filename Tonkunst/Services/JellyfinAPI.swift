import Foundation

enum JellyfinError: LocalizedError, Equatable {
    case invalidServer, badCredentials, unavailable, timedOut, badResponse, sessionExpired
    case serverError(Int)
    var errorDescription: String? {
        switch self {
        case .invalidServer: return String(localized: "Enter a valid Jellyfin server address.", bundle: AppLocalization.bundle)
        case .badCredentials: return String(localized: "Jellyfin did not accept those credentials.", bundle: AppLocalization.bundle)
        case .unavailable: return String(localized: "Tonkunst could not reach your Jellyfin server.", bundle: AppLocalization.bundle)
        case .timedOut: return String(localized: "Jellyfin took too long to respond. Check the server address and network, then try again.", bundle: AppLocalization.bundle)
        case .badResponse: return String(localized: "Jellyfin returned an unexpected response.", bundle: AppLocalization.bundle)
        case .sessionExpired: return String(localized: "Your Jellyfin session expired. Sign out and connect again.", bundle: AppLocalization.bundle)
        case .serverError(let status): return String(localized: "Jellyfin returned a server error (\(status)). Try again later.", bundle: AppLocalization.bundle)
        }
    }
}

struct JellyfinAPI: Sendable {
    private let clientName = "Tonkunst"
    private let deviceID: String
    private let session: URLSession
    private let requestTimeout: TimeInterval = 15

    init(deviceID: String = UUID().uuidString, session: URLSession = Self.defaultSession) {
        self.deviceID = deviceID
        self.session = session
    }

    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func authenticate(server: String, username: String, password: String) async throws -> ServerProfile {
        guard let base = normalizedServerURL(from: server) else { throw JellyfinError.invalidServer }
        let url = base.appendingPathComponent("Users/AuthenticateByName")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(token: nil), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.unavailable }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw JellyfinError.badCredentials
        case 404:
            throw JellyfinError.invalidServer
        default:
            throw JellyfinError.badResponse
        }
        let auth: JellyfinAuthResponse
        do { auth = try JSONDecoder().decode(JellyfinAuthResponse.self, from: data) }
        catch { throw JellyfinError.badResponse }
        guard !auth.accessToken.isEmpty, !auth.user.id.isEmpty else { throw JellyfinError.badResponse }
        let cleanBase = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let avatar = auth.user.primaryImageTag.flatMap { tag -> String? in
            guard var parts = URLComponents(url: base.appendingPathComponent("Users/\(auth.user.id)/Images/Primary"), resolvingAgainstBaseURL: false) else { return nil }
            parts.queryItems = [URLQueryItem(name: "tag", value: tag)]
            return parts.url?.absoluteString
        }
        return ServerProfile(baseURL: cleanBase, userID: auth.user.id, accessToken: auth.accessToken, displayName: auth.user.name, avatarURL: avatar)
    }

    func fetchSongs(profile: ServerProfile) async throws -> [MediaTrack] {
        let items = try await fetchItems(profile: profile, path: "Users/\(profile.userID)/Items", query: [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"), URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"), URLQueryItem(name: "Fields", value: "UserData"),
            URLQueryItem(name: "EnableImages", value: "false")
        ])
        return try items.map { try track(from: $0, profile: profile) }
    }

    func track(from item: JellyfinItem, profile: ServerProfile) throws -> MediaTrack {
        guard let base = profile.normalizedBaseURL,
              var art = URLComponents(url: base.appendingPathComponent("Items/\(item.id)/Images/Primary"), resolvingAgainstBaseURL: false),
              var universal = URLComponents(url: base.appendingPathComponent("Audio/\(item.id)/universal"), resolvingAgainstBaseURL: false),
              var direct = URLComponents(url: base.appendingPathComponent("Audio/\(item.id)/stream"), resolvingAgainstBaseURL: false) else {
            throw JellyfinError.invalidServer
        }
        art.queryItems = [URLQueryItem(name: "maxWidth", value: "480"),
                          URLQueryItem(name: "quality", value: "90"),
                          URLQueryItem(name: "api_key", value: profile.accessToken)]
        // Universal audio lets Jellyfin direct-play compatible files and transcode
        // unsupported containers/codecs (notably Opus) to an iOS-friendly HLS/AAC
        // stream. DeviceId and the playback session are required by Jellyfin's
        // transcoding pipeline on many server versions.
        universal.queryItems = [
            URLQueryItem(name: "UserId", value: profile.userID),
            URLQueryItem(name: "DeviceId", value: deviceID),
            URLQueryItem(name: "PlaySessionId", value: UUID().uuidString),
            URLQueryItem(name: "Container", value: "mp4,m4a,mp3,aac,flac"),
            URLQueryItem(name: "TranscodingContainer", value: "ts"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "MaxAudioChannels", value: "2"),
            URLQueryItem(name: "MaxStreamingBitrate", value: "3200000"),
            URLQueryItem(name: "api_key", value: profile.accessToken)
        ]
        direct.queryItems = [
            URLQueryItem(name: "UserId", value: profile.userID),
            URLQueryItem(name: "DeviceId", value: deviceID),
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "api_key", value: profile.accessToken)
        ]
        return MediaTrack(
            id: item.id,
            title: metadataValue([item.name], placeholder: String(localized: "Unknown Song", bundle: AppLocalization.bundle)),
            artist: metadataValue([item.albumArtist] + (item.artists ?? []).map { Optional($0) }, placeholder: String(localized: "Unknown Artist", bundle: AppLocalization.bundle)),
            album: metadataValue([item.album], placeholder: String(localized: "Unknown Album", bundle: AppLocalization.bundle)),
            duration: max(0, Double(item.runTimeTicks ?? 0) / 10_000_000),
            artworkURL: art.url,
            streamURL: universal.url,
            fallbackStreamURL: direct.url,
            fileExtension: audioFileExtension(for: item.container),
            isFavorite: item.userData?.isFavorite ?? false,
            accountID: profile.id
        )
    }

    func requestData(profile: ServerProfile, path: String, method: String = "GET",
                         query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard let base = profile.normalizedBaseURL,
              var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw JellyfinError.invalidServer
        }
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw JellyfinError.invalidServer }
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.httpMethod = method
        request.httpBody = body
        request.setValue(authHeader(token: profile.accessToken), forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.badResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw JellyfinError.sessionExpired
        case 500..<600: throw JellyfinError.serverError(http.statusCode)
        default: throw JellyfinError.badResponse
        }
        return data
    }

    func fetchItems(profile: ServerProfile, path: String, query: [URLQueryItem] = []) async throws -> [JellyfinItem] {
        var items: [JellyfinItem] = []
        while true {
            try Task.checkCancellation()
            let data = try await requestData(profile: profile, path: path, query: query + [
                URLQueryItem(name: "UserId", value: profile.userID),
                URLQueryItem(name: "StartIndex", value: String(items.count)),
                URLQueryItem(name: "Limit", value: "200")
            ])
            let page: JellyfinItemsResponse
            do { page = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data) }
            catch { throw JellyfinError.badResponse }
            items += page.items
            if page.items.isEmpty || items.count >= (page.totalRecordCount ?? Int.max) || (page.totalRecordCount == nil && page.items.count < 200) { return items }
        }
    }

    /// Checks the server itself, rather than only whether the device has a
    /// network route. This catches leaving a LAN while cellular remains active.
    func ping(profile: ServerProfile) async throws {
        guard let base = profile.normalizedBaseURL else { throw JellyfinError.invalidServer }
        var request = URLRequest(url: base.appendingPathComponent("System/Ping"), cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = min(requestTimeout, 5)
        request.setValue(authHeader(token: profile.accessToken), forHTTPHeaderField: "Authorization")
        let (_, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw JellyfinError.unavailable
        }
    }

    /// Jellyfin can provide an empty tag rather than omit it. Treat either form
    /// as missing so no user-facing metadata label is blank.
    private func metadataValue(_ values: [String?], placeholder: String) -> String {
        values.lazy.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first ?? placeholder
    }

    private func audioFileExtension(for container: String?) -> String {
        let formats = Set((container ?? "").lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        // FFmpeg reports MP4 audio as "mov,mp4,m4a,3gp,3g2,mj2". That is a
        // list of compatible format names, not a filename extension.
        if !formats.isDisjoint(with: ["m4a", "mp4", "mov"]) { return "m4a" }
        for format in ["mp3", "flac", "aac", "ogg", "opus", "wav", "aiff", "caf"] {
            if formats.contains(format) { return format }
        }
        return "m4a"
    }

    private func authHeader(token: String?) -> String {
        var header = "MediaBrowser Client=\"\(clientName)\", Device=\"iPhone\", DeviceId=\"\(deviceID)\", Version=\"1.0\""
        if let token { header += ", Token=\"\(token)\"" }
        return header
    }

    private func normalizedServerURL(from server: String) -> URL? {
        let address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBareAddress = !address.contains("://")
        let withScheme = isBareAddress ? "http://\(address)" : address
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil else { return nil }
        if isBareAddress, components.port == nil, let host = components.host, isIPv4Address(host) {
            components.port = 8096
        }
        components.query = nil
        components.fragment = nil
        components.path = normalizedPath(components.path)
        return components.url
    }

    private func isIPv4Address(_ host: String) -> Bool {
        let octets = host.split(separator: ".")
        return octets.count == 4 && octets.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    private func normalizedPath(_ path: String) -> String {
        var segments = path.split(separator: "/").map(String.init)
        if let webIndex = segments.firstIndex(where: { $0.caseInsensitiveCompare("web") == .orderedSame }) {
            segments.removeSubrange(webIndex...)
        }
        return segments.isEmpty ? "" : "/\(segments.joined(separator: "/"))"
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            try Task.checkCancellation()
            let result = try await session.data(for: request)
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw JellyfinError.timedOut
        } catch {
            throw JellyfinError.unavailable
        }
    }
}
