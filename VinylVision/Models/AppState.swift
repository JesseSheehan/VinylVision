//
//  AppState.swift
//  VinylVision
//

import SwiftUI
import Observation

@Observable
class AppState {
    var isScanning: Bool = false
    var capturedImage: UIImage?
    var currentAlbum: Album?
    var isLoadingAlbum: Bool = false
    var errorMessage: String?
    var currentTrack: Track?
    var isPlaying: Bool = false
    var playbackProgress: Double = 0.0
    var autoPlay: Bool = true
    var playMostPopular: Bool = false
    var preferredStreamingService: StreamingService = .appleMusic
    var useGeminiRecognition: Bool = false
    var autoPhotoEnabled: Bool = true
    var showAutoPhotoToggle: Bool = true
    var recentAlbums: [Album] = []

    init() {
        loadHistory()
        // Hydrate user prefs from UserDefaults so they're correct at launch,
        // before SettingsView (which mirrors @AppStorage → AppState) is opened.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "autoPlay") != nil {
            autoPlay = defaults.bool(forKey: "autoPlay")
        }
        playMostPopular = defaults.bool(forKey: "playMostPopular")
        useGeminiRecognition = defaults.bool(forKey: "useGeminiRecognition")
        if defaults.object(forKey: "autoPhotoEnabled") != nil {
            autoPhotoEnabled = defaults.bool(forKey: "autoPhotoEnabled")
        }
        if defaults.object(forKey: "showAutoPhotoToggle") != nil {
            showAutoPhotoToggle = defaults.bool(forKey: "showAutoPhotoToggle")
        }
        if let raw = defaults.string(forKey: "preferredStreamingService"),
           let service = StreamingService(rawValue: raw) {
            preferredStreamingService = service
        }
    }

    func reset() {
        currentAlbum = nil; currentTrack = nil
        isPlaying = false; playbackProgress = 0.0; errorMessage = nil
    }

    func addToHistory(_ album: Album) {
        recentAlbums.removeAll { $0.id == album.id }
        recentAlbums.insert(album, at: 0)
        if recentAlbums.count > 50 { recentAlbums = Array(recentAlbums.prefix(50)) }
        saveHistory()
    }

    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(recentAlbums) {
            UserDefaults.standard.set(encoded, forKey: "recentAlbums")
        }
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: "recentAlbums"),
           let decoded = try? JSONDecoder().decode([Album].self, from: data) {
            recentAlbums = decoded
        }
    }
}

struct Album: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let artist: String
    let imageURL: String
    let releaseYear: String
    let genres: [String]
    let tracks: [Track]
    let spotifyURL: String?
    let appleMusicURL: String?
    let deezerURL: String?
    let discogsURL: String?

    var wikipediaSearchURL: URL? {
        let query = "\(artist) \(name) album"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://en.wikipedia.org/wiki/Special:Search?search=\(query)")
    }

    /// URL to open this album in the user's preferred streaming service.
    /// Uses the direct URL when we have one, otherwise falls back to a search query
    /// that universal-links into the service's app (or web).
    func streamingURL(for service: StreamingService) -> URL? {
        let encodedQuery = "\(artist) \(name)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch service {
        case .appleMusic:
            if let appleMusicURL, let url = URL(string: appleMusicURL) { return url }
            return URL(string: "https://music.apple.com/search?term=\(encodedQuery)")
        case .spotify:
            if let spotifyURL, let url = URL(string: spotifyURL) { return url }
            return URL(string: "https://open.spotify.com/search/\(encodedQuery)")
        case .deezer:
            if let deezerURL, let url = URL(string: deezerURL) { return url }
            return URL(string: "https://www.deezer.com/search/\(encodedQuery)")
        }
    }
}

enum StreamingService: String, CaseIterable, Identifiable, Codable {
    case appleMusic
    case spotify
    case deezer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify:    "Spotify"
        case .deezer:     "Deezer"
        }
    }

    var systemImage: String {
        switch self {
        case .appleMusic: "music.note"
        case .spotify:    "music.note.list"
        case .deezer:     "headphones"
        }
    }

    var tintColor: Color {
        switch self {
        case .appleMusic: .pink
        case .spotify:    .green
        case .deezer:     .orange
        }
    }
}

struct Track: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let duration: Int
    let trackNumber: Int
    let previewURL: String?
    let popularity: Int

    var durationFormatted: String {
        String(format: "%d:%02d", duration / 60, duration % 60)
    }
}
