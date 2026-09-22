import Foundation

struct ServerProfile: Codable, Equatable, Sendable {
    var baseURL: String
    var userID: String
    var accessToken: String
    var displayName: String
    var avatarURL: String?

    var normalizedBaseURL: URL? {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = text.contains("://") ? text : "http://\(text)"
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
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

struct MediaTrack: Identifiable, Codable, Hashable {
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
    var isDownloaded: Bool = false

    var formattedDuration: String {
        String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
    }
}

struct JellyfinItemsResponse: Decodable {
    let Items: [JellyfinItem]
}

struct JellyfinItem: Decodable {
    let Id: String
    let Name: String
    let RunTimeTicks: Int64?
    let Album: String?
    let AlbumArtist: String?
    let Artists: [String]?
    let Container: String?
    let UserData: JellyfinUserData?
}

struct JellyfinUserData: Decodable { let IsFavorite: Bool? }

struct JellyfinAuthResponse: Decodable {
    let AccessToken: String
    let User: JellyfinUser
}

struct JellyfinUser: Decodable {
    let Id: String
    let Name: String
    let PrimaryImageTag: String?
}
