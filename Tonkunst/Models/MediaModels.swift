import Foundation

enum AppLocalization {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }
}

struct ServerProfile: Codable, Equatable, Identifiable, Sendable {
    var baseURL: String
    var userID: String
    var accessToken: String
    var displayName: String
    var avatarURL: String?

    var id: String { "\(baseURL)|\(userID)" }

    var normalizedBaseURL: URL? {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = text.contains("://") ? text : "http://\(text)"
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil else { return nil }
        components.query = nil
        components.fragment = nil
        var segments = components.path.split(separator: "/").map(String.init)
        if let webIndex = segments.firstIndex(where: { $0.caseInsensitiveCompare("web") == .orderedSame }) {
            segments.removeSubrange(webIndex...)
        }
        components.path = segments.isEmpty ? "" : "/\(segments.joined(separator: "/"))"
        return components.url
    }
}

struct MediaTrack: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var artworkURL: URL?
    var streamURL: URL?
    var fallbackStreamURL: URL?
    var fileExtension: String
    var isFavorite: Bool = false
    var accountID: String? = nil

    /// Older manifests did not store ownership explicitly. Only infer it when
    /// Jellyfin's audio URL contains both its base path and user identifier.
    var sourceAccountID: String? {
        if let accountID { return accountID }
        for url in [fallbackStreamURL, streamURL].compactMap({ $0 }) {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let userID = parts.queryItems?.first(where: { $0.name.lowercased() == "userid" })?.value,
                  !userID.isEmpty else { continue }
            let segments = parts.path.split(separator: "/")
            guard let audio = segments.lastIndex(where: { $0.lowercased() == "audio" }) else { continue }
            parts.path = audio == 0 ? "" : "/" + segments[..<audio].joined(separator: "/")
            parts.query = nil
            parts.fragment = nil
            parts.user = nil
            parts.password = nil
            if let base = parts.url?.absoluteString { return "\(base)|\(userID)" }
        }
        return nil
    }

    func belongs(to profile: ServerProfile?) -> Bool {
        guard let profile else { return false }
        return sourceAccountID == profile.id
    }

    func authorizing(for profile: ServerProfile?) -> Self {
        var result = authorizing(with: nil)
        guard belongs(to: profile), let profile, let base = profile.normalizedBaseURL else { return result }
        result.accountID = profile.id
        func authorize(_ url: URL?) -> URL? {
            guard let url, url.scheme == base.scheme, url.host == base.host, url.port == base.port,
                  url.path.hasPrefix(base.path + "/"),
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "api_key", value: profile.accessToken)]
            return parts.url
        }
        result.artworkURL = authorize(result.artworkURL)
        result.streamURL = authorize(result.streamURL)
        result.fallbackStreamURL = authorize(result.fallbackStreamURL)
        return result
    }

    var formattedDuration: String {
        PlaybackTime.formatted(duration)
    }

    /// Persist metadata without credentials; tokens are restored only in memory.
    func authorizing(with token: String?) -> Self {
        func authorizedURL(_ original: URL?) -> URL? {
            guard let original,
                  var parts = URLComponents(url: original, resolvingAgainstBaseURL: false) else { return nil }
            parts.user = nil
            parts.password = nil
            var query = (parts.queryItems ?? []).filter { $0.name.lowercased() != "api_key" }
            if let token { query.append(URLQueryItem(name: "api_key", value: token)) }
            parts.queryItems = query.isEmpty ? nil : query
            return parts.url
        }
        var result = self
        result.artworkURL = authorizedURL(artworkURL)
        result.streamURL = authorizedURL(streamURL)
        result.fallbackStreamURL = authorizedURL(fallbackStreamURL)
        return result
    }
}

enum PlaybackTime {
    static func formatted(_ value: TimeInterval) -> String {
        guard value.isFinite, let seconds = Int(exactly: max(0, value).rounded(.towardZero)) else { return "0:00" }
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

struct JellyfinItemsResponse: Decodable {
    let items: [JellyfinItem]
    let totalRecordCount: Int?
    enum CodingKeys: String, CodingKey { case items = "Items", totalRecordCount = "TotalRecordCount" }
}

struct JellyfinItem: Decodable {
    let id: String
    let name: String
    let runTimeTicks: Int64?
    let album: String?
    let albumArtist: String?
    let artists: [String]?
    let container: String?
    let userData: JellyfinUserData?
    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", runTimeTicks = "RunTimeTicks", album = "Album"
        case albumArtist = "AlbumArtist", artists = "Artists", container = "Container", userData = "UserData"
    }
}

struct JellyfinUserData: Decodable {
    let isFavorite: Bool?
    enum CodingKeys: String, CodingKey { case isFavorite = "IsFavorite" }
}

struct JellyfinAuthResponse: Decodable {
    let accessToken: String
    let user: JellyfinUser
    enum CodingKeys: String, CodingKey { case accessToken = "AccessToken", user = "User" }
}

struct JellyfinUser: Decodable {
    let id: String
    let name: String
    let primaryImageTag: String?
    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name", primaryImageTag = "PrimaryImageTag" }
}
