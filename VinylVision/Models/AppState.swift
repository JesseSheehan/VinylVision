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
    var recentAlbums: [Album] = []

    init() { loadHistory() }

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
