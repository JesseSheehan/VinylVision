//
//  AlbumSearchView.swift
//  VinylVision
//

import SwiftUI

struct AlbumSearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var initialQuery: String = ""

    @State private var searchText = ""
    @State private var results: [AlbumSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Artist, album, or both...", text: $searchText)
                        .submitLabel(.search)
                        .onSubmit { performSearch() }
                        .autocorrectionDisabled()

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            results = []
                            hasSearched = false
                            errorMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()

                // Results area
                if isSearching {
                    Spacer()
                    VStack(spacing: 16) {
                        ProgressView().scaleEffect(1.2)
                        Text("Searching...")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()

                } else if let error = errorMessage {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 40)).foregroundStyle(.orange)
                        Text(error)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(40)
                    Spacer()

                } else if hasSearched && results.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No albums found")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("Try different keywords")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(40)
                    Spacer()

                } else if !results.isEmpty {
                    List(results) { result in
                        Button { selectAlbum(result) } label: {
                            AlbumSearchResultRow(result: result)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    .listStyle(.plain)

                } else {
                    // Empty state
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 50)).foregroundStyle(.secondary)
                        Text("Search for an album")
                            .font(.headline)
                        Text("Try artist name, album title, or both.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    Spacer()
                }
            }
            .navigationTitle("Find Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Search") { performSearch() }
                        .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                // Pre-fill and auto-search if we have an initial query
                if !initialQuery.isEmpty {
                    searchText = initialQuery
                    performSearch()
                }
            }
        }
    }

    // MARK: - Search

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        isSearching = true
        errorMessage = nil
        hasSearched = false
        results = []

        Task {
            do {
                let found = try await searchAlbums(query: query)
                await MainActor.run {
                    results = found
                    isSearching = false
                    hasSearched = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Search failed. Check your connection."
                    isSearching = false
                    hasSearched = true
                }
            }
        }
    }

    private func searchAlbums(query: String) async throws -> [AlbumSearchResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        async let deezerResults  = searchDeezer(encoded: encoded)
        async let discogsResults = searchDiscogs(encoded: encoded)
        let (deezer, discogs) = try await (deezerResults, discogsResults)

        // Deezer first (has audio), then Discogs extras
        var merged = deezer
        for d in discogs where !merged.contains(where: {
            $0.title.lowercased() == d.title.lowercased() &&
            $0.artist.lowercased() == d.artist.lowercased()
        }) {
            merged.append(d)
        }
        return merged
    }

    private func searchDeezer(encoded: String) async throws -> [AlbumSearchResult] {
        guard let url = URL(string: "https://api.deezer.com/search/album?q=\(encoded)&limit=8") else {
            return []
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        struct Response: Codable { let data: [Item] }
        struct Item: Codable {
            let id: Int; let title: String
            let artist: Artist; let cover_medium: String?
            struct Artist: Codable { let name: String }
        }

        let sr = try JSONDecoder().decode(Response.self, from: data)
        return sr.data.map { AlbumSearchResult(
            id: "deezer-\($0.id)", title: $0.title, artist: $0.artist.name,
            imageURL: $0.cover_medium ?? "", year: "", source: .deezer, deezerID: $0.id
        )}
    }

    private func searchDiscogs(encoded: String) async throws -> [AlbumSearchResult] {
        let token = Bundle.main.object(forInfoDictionaryKey: "DISCOGS_TOKEN") as? String ?? ""
        guard !token.isEmpty,
              let url = URL(string: "https://api.discogs.com/database/search?q=\(encoded)&type=release&per_page=5&token=\(token)") else {
            return []
        }
        var req = URLRequest(url: url)
        req.setValue("VinylVision/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        struct Response: Codable { let results: [Item] }
        struct Item: Codable {
            let id: Int; let title: String; let year: String?; let thumb: String?
        }

        let sr = try JSONDecoder().decode(Response.self, from: data)
        return sr.results.map { r in
            let parts = r.title.components(separatedBy: " - ")
            let artist = parts.count >= 2 ? parts[0] : ""
            let title  = parts.count >= 2 ? parts[1...].joined(separator: " - ") : r.title
            return AlbumSearchResult(
                id: "discogs-\(r.id)", title: title, artist: artist,
                imageURL: r.thumb ?? "", year: r.year ?? "", source: .discogs, deezerID: nil
            )
        }
    }

    // MARK: - Select

    private func selectAlbum(_ result: AlbumSearchResult) {
        Task {
            await MainActor.run { isSearching = true }
            do {
                let album: Album
                switch result.source {
                case .deezer:
                    guard let id = result.deezerID else { throw SearchError.failed }
                    album = try await fetchDeezerAlbum(id: id)
                case .discogs:
                    let q = "\(result.artist) \(result.title)"
                    if let found = try await searchAndFetchDeezer(query: q) {
                        album = found
                    } else {
                        album = Album(
                            id: result.id, name: result.title, artist: result.artist,
                            imageURL: result.imageURL, releaseYear: result.year,
                            genres: [], tracks: [],
                            spotifyURL: nil, appleMusicURL: nil,
                            deezerURL: nil, discogsURL: nil
                        )
                    }
                }
                await MainActor.run {
                    AudioPlayerManager.shared.stop()
                    appState.isPlaying = false
                    appState.currentTrack = nil
                    appState.currentAlbum = album
                    appState.addToHistory(album)
                    isSearching = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Couldn't load album. Try another."
                    isSearching = false
                }
            }
        }
    }

    private func fetchDeezerAlbum(id: Int) async throws -> Album {
        struct A: Codable {
            let id: Int; let title: String; let artist: Ar
            let cover_xl: String; let release_date: String
            let genres: Gs?; let tracks: Ts; let link: String
            struct Ar: Codable { let name: String }
            struct Gs: Codable { let data: [G] }
            struct G: Codable { let name: String }
            struct Ts: Codable { let data: [T] }
            struct T: Codable {
                let id: Int; let title: String; let duration: Int
                let preview: String; let rank: Int?
            }
        }
        guard let url = URL(string: "https://api.deezer.com/album/\(id)") else {
            throw SearchError.failed
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        let a = try JSONDecoder().decode(A.self, from: data)
        return Album(
            id: String(a.id), name: a.title, artist: a.artist.name,
            imageURL: a.cover_xl, releaseYear: a.release_date.prefix(4).description,
            genres: a.genres?.data.map { $0.name } ?? [],
            tracks: a.tracks.data.enumerated().map { i, t in
                Track(id: String(t.id), name: t.title, duration: t.duration,
                      trackNumber: i + 1, previewURL: t.preview, popularity: t.rank ?? 0)
            },
            spotifyURL: nil, appleMusicURL: nil, deezerURL: a.link, discogsURL: nil
        )
    }

    private func searchAndFetchDeezer(query: String) async throws -> Album? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://api.deezer.com/search/album?q=\(encoded)&limit=1") else {
            return nil
        }
        struct R: Codable { let data: [I] }
        struct I: Codable { let id: Int }
        let (data, _) = try await URLSession.shared.data(from: url)
        let sr = try JSONDecoder().decode(R.self, from: data)
        guard let first = sr.data.first else { return nil }
        return try await fetchDeezerAlbum(id: first.id)
    }
}

// MARK: - Result Row

struct AlbumSearchResultRow: View {
    let result: AlbumSearchResult

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: URL(string: result.imageURL)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .overlay(Image(systemName: "opticaldisc").foregroundStyle(.secondary))
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(radius: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(.primary).lineLimit(1)
                Text(result.artist)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if !result.year.isEmpty {
                        Text(result.year).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(result.source == .deezer ? "🎵 Deezer" : "💿 Discogs")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Models

struct AlbumSearchResult: Identifiable {
    let id: String
    let title: String
    let artist: String
    let imageURL: String
    let year: String
    let source: SearchSource
    let deezerID: Int?
    enum SearchSource { case deezer, discogs }
}

enum SearchError: Error { case failed }
