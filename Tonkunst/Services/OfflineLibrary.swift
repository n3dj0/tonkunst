import AVFoundation
import Foundation

@MainActor
final class OfflineLibrary: ObservableObject {
    @Published private(set) var downloaded: [String: URL] = [:]
    private let manifestKey = "offlineTrackManifest"
    private let trackManifestKey = "offlineTrackMetadata"
    private let documentsRoot: URL?
    private let defaults: UserDefaults
    private(set) var savedTracks: [String: MediaTrack] = [:]

    init(documentsRoot: URL? = nil, defaults: UserDefaults = .standard) {
        self.documentsRoot = documentsRoot
        self.defaults = defaults
        _ = try? documentsDirectory()
        loadManifest()
    }

    func localURL(for track: MediaTrack) -> URL? {
        guard let url = downloaded[track.id], FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    func contains(_ track: MediaTrack) -> Bool { localURL(for: track) != nil }
    var tracks: [MediaTrack] {
        savedTracks.values.filter(contains).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func download(_ track: MediaTrack) async throws {
        // `streamURL` is an HLS playlist used for online playback. Saving that
        // playlist as an audio file makes a download look complete but leaves it
        // unplayable as soon as the server is unavailable. Download the direct
        // audio resource instead.
        guard let url = track.fallbackStreamURL ?? track.streamURL else { throw JellyfinError.badResponse }
        let staged: (url: URL, fileExtension: String)
        do {
            staged = try await playableDownload(from: url, suggestedExtension: track.fileExtension)
        } catch OfflineAudioError.unsupportedFormat {
            guard let transcodedURL = transcodedMP3URL(from: track.fallbackStreamURL ?? url) else {
                throw OfflineAudioError.unsupportedFormat
            }
            staged = try await playableDownload(from: transcodedURL, suggestedExtension: "mp3")
        }
        let destination = try destination(for: track, fileExtension: staged.fileExtension)
        defer { try? FileManager.default.removeItem(at: staged.url) }
        if FileManager.default.fileExists(atPath: destination.path) {
            // Keep a file the user may have placed in Files unless this track
            // already owns it.
            guard downloaded[track.id] == destination else {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: staged.url, to: destination)
        if let previous = downloaded[track.id], previous != destination {
            try? FileManager.default.removeItem(at: previous)
            removeEmptyFolders(startingAt: previous.deletingLastPathComponent())
        }
        downloaded[track.id] = destination
        var savedTrack = track
        savedTrack.fileExtension = staged.fileExtension
        savedTracks[track.id] = savedTrack
        saveManifest()
    }

    private func playableDownload(from url: URL, suggestedExtension: String) async throws -> (url: URL, fileExtension: String) {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw JellyfinError.unavailable
        }
        guard !isHLSPlaylist(at: temporaryURL) else { throw OfflineAudioError.unsupportedFormat }
        let knownExtensions: Set<String> = ["m4a", "mp3", "flac", "aac", "ogg", "opus", "wav", "aiff", "caf"]
        let suggested = suggestedExtension.lowercased()
        let ext = detectedAudioExtension(at: temporaryURL)
            ?? (knownExtensions.contains(suggested) ? suggested : "m4a")
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tonkunst-\(UUID().uuidString).\(ext)")
        try FileManager.default.moveItem(at: temporaryURL, to: stagedURL)
        do {
            let asset = AVURLAsset(url: stagedURL)
            guard try await asset.load(.isPlayable),
                  try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
                throw OfflineAudioError.unsupportedFormat
            }
            return (stagedURL, ext)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw OfflineAudioError.unsupportedFormat
        }
    }

    private func transcodedMP3URL(from directURL: URL) -> URL? {
        guard var components = URLComponents(url: directURL, resolvingAgainstBaseURL: false),
              components.path.hasSuffix("/stream") else { return nil }
        components.path += ".mp3"
        components.queryItems = (components.queryItems ?? []).filter {
            !["static", "container", "audiocodec", "audiobitrate", "maxaudiochannels"].contains($0.name.lowercased())
        } + [
            URLQueryItem(name: "Static", value: "false"),
            URLQueryItem(name: "Container", value: "mp3"),
            URLQueryItem(name: "AudioCodec", value: "mp3"),
            URLQueryItem(name: "AudioBitRate", value: "320000"),
            URLQueryItem(name: "MaxAudioChannels", value: "2")
        ]
        return components.url
    }

    func remove(_ track: MediaTrack) {
        if let url = downloaded[track.id] {
            try? FileManager.default.removeItem(at: url)
            removeEmptyFolders(startingAt: url.deletingLastPathComponent())
        }
        downloaded.removeValue(forKey: track.id)
        savedTracks.removeValue(forKey: track.id)
        saveManifest()
    }

    /// The Documents root is shown as "On My iPhone → Tonkunst" in Files.
    private func documentsDirectory() throws -> URL {
        let root = try documentsRoot ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func destination(for track: MediaTrack?, id: String? = nil, fileExtension: String) throws -> URL {
        let artist = safeName(track?.artist ?? "Unknown Artist", fallback: "Unknown Artist", maxBytes: 100)
        let album = safeName(track?.album ?? "Unknown Album", fallback: "Unknown Album", maxBytes: 100)
        let title = safeName(track?.title ?? "Unknown Song", fallback: "Unknown Song", maxBytes: 100)
        let trackID = safeName(id ?? track?.id ?? "Track", fallback: "Track", maxBytes: 64)
        let ext = String(fileExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(10))
        let folder = try documentsDirectory()
            .appendingPathComponent(artist, isDirectory: true)
            .appendingPathComponent(album, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(title) [\(trackID)].\(ext.isEmpty ? "m4a" : ext)")
    }

    private func safeName(_ name: String, fallback: String, maxBytes: Int) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let cleaned = name.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var result = ""
        for character in cleaned {
            guard result.utf8.count + String(character).utf8.count <= maxBytes else { break }
            result.append(character)
        }
        return result.isEmpty ? fallback : result
    }

    private func removeEmptyFolders(startingAt folder: URL) {
        guard let root = try? documentsDirectory() else { return }
        var current = folder
        while current != root, current.path.hasPrefix(root.path + "/") {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: current.path), items.isEmpty else { return }
            try? FileManager.default.removeItem(at: current)
            current.deleteLastPathComponent()
        }
    }

    /// Existing downloads were stored in private Application Support. Move
    /// them into Files without losing a playable copy if a move fails.
    private func relocate(_ url: URL, track: MediaTrack?, id: String) -> URL {
        guard let destination = try? destination(for: track, id: id, fileExtension: url.pathExtension),
              url != destination else { return url }
        guard !FileManager.default.fileExists(atPath: destination.path) else { return url }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            removeEmptyFolders(startingAt: url.deletingLastPathComponent())
            return destination
        } catch {
            return url
        }
    }

    private func repairedExtension(at url: URL) -> URL {
        guard let detected = detectedAudioExtension(at: url), detected != url.pathExtension.lowercased() else { return url }
        let destination = url.deletingPathExtension().appendingPathExtension(detected)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return url }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            return url
        }
    }

    private func detectedAudioExtension(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16) else { return nil }
        let bytes = [UInt8](data)
        if bytes.count >= 8, Array(bytes[4..<8]) == Array("ftyp".utf8) { return "m4a" }
        if data.starts(with: Data("fLaC".utf8)) { return "flac" }
        if data.starts(with: Data("OggS".utf8)) { return "ogg" }
        if bytes.count >= 2, bytes[0] == 0xff, (bytes[1] & 0xf6) == 0xf0 { return "aac" }
        if data.starts(with: Data("ID3".utf8)) || bytes.count >= 2 && bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0 { return "mp3" }
        if bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WAVE".utf8) { return "wav" }
        if data.starts(with: Data("caff".utf8)) { return "caf" }
        if bytes.count >= 12, Array(bytes[0..<4]) == Array("FORM".utf8), Array(bytes[8..<12]) == Array("AIFF".utf8) { return "aiff" }
        return nil
    }

    func reconcile(with tracks: [MediaTrack]) {
        var changed = false
        for track in tracks where downloaded[track.id] != nil {
            guard let previous = downloaded[track.id] else { continue }
            let current = relocate(previous, track: track, id: track.id)
            if current != previous { downloaded[track.id] = current; changed = true }
            var savedTrack = track
            savedTrack.fileExtension = current.pathExtension
            if savedTracks[track.id] != savedTrack { savedTracks[track.id] = savedTrack; changed = true }
        }
        if changed { saveManifest() }
    }

    private func resolvedURL(for storedPath: String) -> URL? {
        if storedPath.hasPrefix("Documents/"), let root = try? documentsDirectory() {
            let relative = String(storedPath.dropFirst("Documents/".count))
            let url = root.appendingPathComponent(relative)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        let oldURL = URL(fileURLWithPath: storedPath)
        if FileManager.default.fileExists(atPath: oldURL.path) { return oldURL }

        // Older manifests stored the complete sandbox path, whose container
        // identifier can change when iOS updates the app.
        guard oldURL.deletingLastPathComponent().lastPathComponent == "TonkunstDownloads",
              let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
        let currentURL = support.appendingPathComponent("TonkunstDownloads", isDirectory: true)
            .appendingPathComponent(oldURL.lastPathComponent)
        return FileManager.default.fileExists(atPath: currentURL.path) ? currentURL : nil
    }

    private func loadManifest() {
        guard let raw = defaults.dictionary(forKey: manifestKey) as? [String: String] else { return }
        let metadata = defaults.data(forKey: trackManifestKey)
            .flatMap { try? JSONDecoder().decode([String: MediaTrack].self, from: $0) } ?? [:]
        downloaded = raw.reduce(into: [:]) { result, pair in
            guard let url = resolvedURL(for: pair.value) else { return }
            // Versions before offline downloads used the HLS playlist URL. Do
            // not keep reporting those playlists as usable audio files.
            guard !isHLSPlaylist(at: url) else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            result[pair.key] = relocate(repairedExtension(at: url), track: metadata[pair.key], id: pair.key)
        }
        savedTracks = metadata.reduce(into: [:]) { result, pair in
            guard let url = downloaded[pair.key] else { return }
            var track = pair.value
            track.fileExtension = url.pathExtension
            result[pair.key] = track
        }
        saveManifest()
    }
    private func saveManifest() {
        let rootPath = (try? documentsDirectory().path) ?? ""
        defaults.set(downloaded.mapValues { url in
            let prefix = rootPath + "/"
            return url.path.hasPrefix(prefix) ? "Documents/" + url.path.dropFirst(prefix.count) : url.path
        }, forKey: manifestKey)
        if let data = try? JSONEncoder().encode(savedTracks) {
            defaults.set(data, forKey: trackManifestKey)
        }
    }

    private func isHLSPlaylist(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32),
              let header = String(data: data, encoding: .utf8) else { return false }
        return header.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
    }
}

private enum OfflineAudioError: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        "Jellyfin returned audio that this device cannot play offline."
    }
}
