import Foundation

@MainActor
final class OfflineLibrary: ObservableObject {
    @Published private(set) var downloaded: [String: URL] = [:]
    private let manifestKey = "offlineTrackManifest"

    init() { loadManifest() }

    func localURL(for track: MediaTrack) -> URL? { downloaded[track.id] }
    func contains(_ track: MediaTrack) -> Bool { downloaded[track.id] != nil }

    func download(_ track: MediaTrack) async throws {
        guard let url = track.streamURL else { return }
        let (temporaryURL, _) = try await URLSession.shared.download(from: url)
        let destination = try directory().appendingPathComponent("\(track.id).\(track.fileExtension)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        downloaded[track.id] = destination
        saveManifest()
    }

    func remove(_ track: MediaTrack) {
        if let url = downloaded[track.id] { try? FileManager.default.removeItem(at: url) }
        downloaded.removeValue(forKey: track.id)
        saveManifest()
    }

    private func directory() throws -> URL {
        let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("TonkunstDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func loadManifest() {
        guard let raw = UserDefaults.standard.dictionary(forKey: manifestKey) as? [String: String] else { return }
        downloaded = raw.reduce(into: [:]) { result, pair in let url = URL(fileURLWithPath: pair.value); if FileManager.default.fileExists(atPath: url.path) { result[pair.key] = url } }
    }
    private func saveManifest() { UserDefaults.standard.set(downloaded.mapValues(\.path), forKey: manifestKey) }
}
