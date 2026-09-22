import Foundation
import UIKit

enum JellyfinError: LocalizedError {
    case invalidServer, badCredentials, unavailable, timedOut, badResponse
    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter a valid Jellyfin server address."
        case .badCredentials: return "Jellyfin did not accept those credentials."
        case .unavailable: return "Tonkunst could not reach your Jellyfin server."
        case .timedOut: return "Jellyfin took too long to respond. Check the server address and network, then try again."
        case .badResponse: return "Jellyfin returned an unexpected response."
        }
    }
}

struct JellyfinAPI {
    private let clientName = "Tonkunst"
    private let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    private let requestTimeout: TimeInterval = 15

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func authenticate(server: String, username: String, password: String) async throws -> ServerProfile {
        guard let base = normalizedServerURL(from: server) else { throw JellyfinError.invalidServer }
        let url = base.appendingPathComponent("Users/AuthenticateByName")
        print("Jellyfin authentication endpoint: \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(token: nil), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.unavailable }
        print("Jellyfin authentication response: \(http.statusCode)")
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
        let auth = try JSONDecoder().decode(JellyfinAuthResponse.self, from: data)
        let cleanBase = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let avatar = auth.User.PrimaryImageTag.flatMap { URL(string: "\(cleanBase)/Users/\(auth.User.Id)/Images/Primary?tag=\($0)")?.absoluteString }
        return ServerProfile(baseURL: cleanBase, userID: auth.User.Id, accessToken: auth.AccessToken, displayName: auth.User.Name, avatarURL: avatar)
    }

    func fetchSongs(profile: ServerProfile) async throws -> [MediaTrack] {
        guard let base = profile.normalizedBaseURL else { throw JellyfinError.invalidServer }
        var parts = URLComponents(url: base.appendingPathComponent("Users/\(profile.userID)/Items"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"), URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"), URLQueryItem(name: "Fields", value: "UserData"),
            URLQueryItem(name: "EnableImages", value: "false"), URLQueryItem(name: "Limit", value: "500")
        ]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = requestTimeout
        request.setValue(authHeader(token: profile.accessToken), forHTTPHeaderField: "Authorization")
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw JellyfinError.unavailable }
        let responseBody = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        return responseBody.Items.map { item in
            let art = URL(string: "\(profile.baseURL)/Items/\(item.Id)/Images/Primary?maxWidth=480&quality=90&api_key=\(profile.accessToken)")
            // Universal audio lets Jellyfin direct-play compatible files and transcode
            // unsupported containers/codecs (notably Opus) to an iOS-friendly HLS/AAC
            // stream. DeviceId and the playback session are required by Jellyfin's
            // transcoding pipeline on many server versions.
            var universal = URLComponents(url: base.appendingPathComponent("Audio/\(item.Id)/universal"), resolvingAgainstBaseURL: false)!
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
            var direct = URLComponents(url: base.appendingPathComponent("Audio/\(item.Id)/stream"), resolvingAgainstBaseURL: false)!
            direct.queryItems = [
                URLQueryItem(name: "UserId", value: profile.userID),
                URLQueryItem(name: "DeviceId", value: deviceID),
                URLQueryItem(name: "Static", value: "true"),
                URLQueryItem(name: "api_key", value: profile.accessToken)
            ]
            return MediaTrack(
                id: item.Id,
                title: metadataValue([item.Name], placeholder: "Unknown Song"),
                artist: metadataValue([item.AlbumArtist] + (item.Artists ?? []).map { Optional($0) }, placeholder: "Unknown Artist"),
                album: metadataValue([item.Album], placeholder: "Unknown Album"),
                duration: Double(item.RunTimeTicks ?? 0) / 10_000_000,
                artworkURL: art,
                streamURL: universal.url,
                fallbackStreamURL: direct.url,
                fileExtension: audioFileExtension(for: item.Container),
                isFavorite: item.UserData?.IsFavorite ?? false
            )
        }
    }

    /// Checks the server itself, rather than only whether the device has a
    /// network route. This catches leaving a LAN while cellular remains active.
    func ping(profile: ServerProfile) async throws {
        guard let base = profile.normalizedBaseURL else { throw JellyfinError.invalidServer }
        var request = URLRequest(url: base.appendingPathComponent("System/Ping"))
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
              components.host != nil else { return nil }
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
            return try await Self.session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw JellyfinError.timedOut
        } catch {
            throw JellyfinError.unavailable
        }
    }
}
