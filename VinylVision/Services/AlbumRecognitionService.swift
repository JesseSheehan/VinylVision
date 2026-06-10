//
//  AlbumRecognitionService.swift
//  VinylVision
//
//  Recognition pipeline:
//  Google Vision → Discogs (best match) → Deezer (audio previews)
//                                       ↘ Deezer search fallback if Discogs fails
//

import Foundation
import UIKit

class AlbumRecognitionService {
    static let shared = AlbumRecognitionService()

    private let googleCloudAPIKey = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLOUD_API_KEY") as? String ?? ""
    private let discogsToken = Bundle.main.object(forInfoDictionaryKey: "DISCOGS_TOKEN") as? String ?? ""

    private init() {}

    // MARK: - Main Entry Point

    func recognizeAlbum(from image: UIImage?) async throws -> Album {
        guard let image = image else { throw RecognitionError.invalidImage }

        let result = try await callVisionAPI(image: image)

        let musicScore = scoreMusicConfidence(from: result)
        print("🎼 Music confidence: \(String(format: "%.2f", musicScore))")

        guard musicScore >= 0.2 else {
            print("🚫 Doesn't look like an album - bailing")
            throw RecognitionError.notAnAlbum
        }

        // Build all queries we'll try (OCR first, then web detection)
        var queriesToTry: [String] = []

        let ocrLines = extractOCRLines(from: result.textAnnotations)
        if !ocrLines.isEmpty {
            print("📝 OCR lines: \(ocrLines)")
            queriesToTry.append(contentsOf: buildOCRQueries(from: ocrLines))
        }

        if let webQuery = extractWebQuery(from: result) {
            queriesToTry.append(webQuery)
            let simple = simplifyQuery(webQuery)
            if simple != webQuery { queriesToTry.append(simple) }
        }

        // Deduplicate
        var seen = Set<String>()
        queriesToTry = queriesToTry.filter { seen.insert($0.lowercased()).inserted }

        // ── Stage 1: Try Discogs for each query ───────────────────────
        // Discogs is much better for physical media - vinyl, CD, cassette
        for query in queriesToTry {
            print("💿 Trying Discogs: \(query)")
            if let album = try await searchViaDiscogs(query: query) {
                print("✅ Discogs hit: \(album.name) by \(album.artist)")
                return album
            }
        }

        print("⚠️ Discogs exhausted, falling back to Deezer")

        // ── Stage 2: Fall back to Deezer directly ─────────────────────
        for query in queriesToTry {
            print("🎵 Trying Deezer: \(query)")
            if let album = try await searchDeezerAlbum(query: query) {
                print("✅ Deezer hit: \(album.name) by \(album.artist)")
                return album
            }
        }

        throw RecognitionError.albumNotFound
    }

    // MARK: - Discogs Search → then Deezer for audio

    /// Searches Discogs for the best physical media match,
    /// then uses that artist+title to find Deezer audio previews.
    private func searchViaDiscogs(query: String) async throws -> Album? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard !discogsToken.isEmpty else {
            print("⚠️ No Discogs token - skipping")
            return nil
        }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        // Search Discogs - type=release covers vinyl, CD, cassette
        guard let url = URL(string: "https://api.discogs.com/database/search?q=\(encoded)&type=release&per_page=3&token=\(discogsToken)") else {
            return nil
        }

        var req = URLRequest(url: url)
        // Discogs requires a User-Agent header
        req.setValue("VinylVision/1.0 +https://github.com/vinylvision", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            print("❌ Discogs error: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            return nil
        }

        let searchResponse = try JSONDecoder().decode(DiscogsSearchResponse.self, from: data)

        guard let topResult = searchResponse.results.first else {
            print("🔍 Discogs: no results for \(query)")
            return nil
        }

        print("💿 Discogs found: \(topResult.title) [\(topResult.format?.joined(separator: ", ") ?? "unknown format")]")

        // Discogs title is usually "Artist - Album Title"
        let (artist, albumTitle) = parseDiscogsTitle(topResult.title)
        let year = topResult.year ?? ""

        // Now search Deezer with the clean artist + title from Discogs
        // This is much more accurate than our raw OCR query
        let deezerQuery = artist.isEmpty ? albumTitle : "\(artist) \(albumTitle)"
        print("🎵 Searching Deezer with Discogs result: \(deezerQuery)")

        if let album = try await searchDeezerAlbum(query: deezerQuery) {
            return album
        }

        // If Deezer can't find it by artist+title, try title alone
        if !albumTitle.isEmpty, albumTitle != deezerQuery {
            if let album = try await searchDeezerAlbum(query: albumTitle) {
                return album
            }
        }

        // Discogs found it but Deezer has no audio -
        // Build a minimal Album from Discogs data so user at least sees correct info
        print("ℹ️ Building album from Discogs data (no Deezer audio)")
        return buildDiscogsOnlyAlbum(from: topResult, artist: artist, albumTitle: albumTitle, year: year)
    }

    /// Parses a Discogs title like "Weird Al Yankovic - Poodle Hat"
    /// into ("Weird Al Yankovic", "Poodle Hat")
    private func parseDiscogsTitle(_ title: String) -> (artist: String, album: String) {
        if title.contains(" - ") {
            let parts = title.components(separatedBy: " - ")
            if parts.count >= 2 {
                let artist = parts[0].trimmingCharacters(in: .whitespaces)
                let album  = parts[1...].joined(separator: " - ").trimmingCharacters(in: .whitespaces)
                return (artist, album)
            }
        }
        return ("", title.trimmingCharacters(in: .whitespaces))
    }

    /// Builds a minimal Album from Discogs data when Deezer has no audio.
    /// Shows correct album info even without playback.
    private func buildDiscogsOnlyAlbum(from result: DiscogsSearchResult,
                                        artist: String,
                                        albumTitle: String,
                                        year: String) -> Album {
        return Album(
            id: "discogs-\(result.id)",
            name: albumTitle.isEmpty ? result.title : albumTitle,
            artist: artist.isEmpty ? "Unknown Artist" : artist,
            imageURL: result.cover_image ?? result.thumb ?? "",
            releaseYear: year,
            genres: result.genre ?? [],
            tracks: [], // No tracklist without fetching full /releases/<id>
            spotifyURL: nil,
            appleMusicURL: nil,
            deezerURL: nil,
            discogsURL: "https://www.discogs.com\(result.uri ?? "")"
        )
    }

    // MARK: - OCR Query Builder

    private func buildOCRQueries(from lines: [String]) -> [String] {
        let cleaned = lines.compactMap { cleanOCRLine($0) }
        guard !cleaned.isEmpty else { return [] }

        print("🧹 Cleaned OCR lines: \(cleaned)")

        let noiseWords: Set<String> = [
            "parental advisory", "parental", "advisory", "explicit content", "explicit",
            "featuring", "feat", "produced by", "music by", "lyrics by",
            "book by", "words by", "arranged by",
            "digital", "bonus", "deluxe", "edition", "remastered",
            "side a", "side b", "disc 1", "disc 2"
        ]

        let titleCandidates = cleaned.filter { line in
            let lower = line.lowercased()
            if noiseWords.contains(where: { lower.contains($0) }) { return false }
            if line.count > 40 { return false }
            return true
        }

        let allCandidates = titleCandidates.isEmpty ? cleaned : titleCandidates
        var queries: [String] = []

        if allCandidates.count == 2 {
            queries.append(allCandidates.joined(separator: " "))
            queries.append(allCandidates[0])
            queries.append(allCandidates[1])
            let titleWords = allCandidates[1].components(separatedBy: .whitespaces)
            if titleWords.count > 3 {
                let shortTitle = titleWords.prefix(3).joined(separator: " ")
                queries.append("\(allCandidates[0]) \(shortTitle)")  // "The Moody Blues On The Threshold"
            }
        } else if allCandidates.count >= 3 {
            queries.append(allCandidates.prefix(2).joined(separator: " "))
            queries.append(allCandidates[0])
            queries.append(allCandidates[1])
            queries.append("\(allCandidates[0]) \(allCandidates[2])")
            
            // Artist + first 3 words of second line
            let titleWords = allCandidates[1].components(separatedBy: .whitespaces)
            if titleWords.count > 3 {
                let shortTitle = titleWords.prefix(3).joined(separator: " ")
                queries.append("\(allCandidates[0]) \(shortTitle)")
            }
        } else if let only = allCandidates.first {
            queries.append(only)
        }

        if let firstCleaned = cleaned.first, !queries.contains(firstCleaned) {
            queries.append(firstCleaned)
        }

        var seen = Set<String>()
        return queries
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private func cleanOCRLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return nil }
        guard !trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) else { return nil }

        let timeRegex = try? NSRegularExpression(pattern: #"\d{1,2}:\d{2}\s*(am|pm)?"#, options: .caseInsensitive)
        if timeRegex?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil { return nil }

        let dateWords: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday",
                                       "saturday", "sunday", "january", "february", "march",
                                       "april", "may", "june", "july", "august", "september",
                                       "october", "november", "december",
                                       "mon", "tue", "wed", "thu", "fri", "sat", "sun",
                                       "jan", "feb", "mar", "apr", "jun", "jul", "aug",
                                       "sep", "oct", "nov", "dec"]
        if dateWords.contains(trimmed.lowercased()) { return nil }

        let uiWords: Set<String> = ["option", "command", "return", "shift", "control",
                                     "delete", "escape", "enter", "caps lock", "fn", "alt", "ctrl", "cmd"]
        if uiWords.contains(trimmed.lowercased()) { return nil }

        let knownShort: Set<String> = ["LP", "EP", "CD", "UK", "US", "NY", "LA", "OK"]
        if trimmed.count <= 3 && trimmed == trimmed.uppercased() && !knownShort.contains(trimmed) {
            return nil
        }

        let digitCount = trimmed.filter { $0.isNumber }.count
        if trimmed.count > 3 && Double(digitCount) / Double(trimmed.count) > 0.3 { return nil }

        return trimmed
    }

    // MARK: - Music Confidence Score

    private func scoreMusicConfidence(from result: GoogleVisionResult) -> Double {
        var score: Double = 0
        var penalty: Double = 0

        let musicPlatforms = ["spotify", "deezer", "apple music", "itunes", "amazon music",
                               "tidal", "bandcamp", "soundcloud", "allmusic", "pitchfork",
                               "discogs", "genius", "last.fm", "rateyourmusic", "musicbrainz",
                               "wikipedia"]

        if let pages = result.webDetection?.pagesWithMatchingImages {
            let count = pages.filter { page in
                guard let t = page.pageTitle?.lowercased() else { return false }
                return musicPlatforms.contains(where: { t.contains($0) })
            }.count
            if count >= 2 { score += 0.6 }
            else if count == 1 { score += 0.4 }
        }

        if let bg = result.webDetection?.bestGuessLabels?.first?.label.lowercased() {
            let musicWords = ["album", "song", "music", "soundtrack", "lp", "ep", "single", "record"]
            if musicWords.contains(where: { bg.contains($0) }) { score += 0.3 }
        }

        if let entities = result.webDetection?.webEntities {
            let musicEntityWords = ["album", "song", "music", "artist", "band",
                                     "singer", "rapper", "musician", "soundtrack"]
            if entities.contains(where: { e in
                guard let d = e.description?.lowercased() else { return false }
                return musicEntityWords.contains(where: { d.contains($0) })
            }) { score += 0.2 }
        }

        let ocrLines = extractOCRLines(from: result.textAnnotations)
        let cleanedOCR = ocrLines.compactMap { cleanOCRLine($0) }
        if cleanedOCR.count >= 2 { score += 0.25 }
        else if cleanedOCR.count == 1 { score += 0.1 }

        let nonMusicObjects: Set<String> = [
            "computer keyboard", "keyboard", "computer", "laptop", "notebook computer",
            "mobile phone", "smartphone", "mobile device", "tablet",
            "screen", "monitor", "display", "television",
            "space bar", "netbook", "desktop computer", "touchpad",
            "wall", "ceiling", "floor", "table", "desk", "chair",
            "hand", "finger", "person", "face",
            "food", "drink", "bottle", "cup", "plant",
            "car", "vehicle", "sky", "grass"
        ]

        if let entities = result.webDetection?.webEntities {
            let hits = entities.prefix(5).filter { e in
                guard let d = e.description?.lowercased() else { return false }
                return nonMusicObjects.contains(d)
            }.count
            if hits >= 2 { penalty += 0.5 }
            else if hits == 1 { penalty += 0.25 }
        }

        if let bg = result.webDetection?.bestGuessLabels?.first?.label.lowercased() {
            let objectWords = ["keyboard", "computer", "phone", "laptop", "screen", "device"]
            if objectWords.contains(where: { bg.contains($0) }) { penalty += 0.3 }
        }

        let hasWebResults = !(result.webDetection?.pagesWithMatchingImages?.isEmpty ?? true)
        let hasGuess = !(result.webDetection?.bestGuessLabels?.isEmpty ?? true)
        if !hasWebResults && !hasGuess && cleanedOCR.isEmpty { penalty += 0.2 }

        return max(0, score - penalty)
    }

    // MARK: - Web Query Fallback

    private func extractWebQuery(from result: GoogleVisionResult) -> String? {
        var candidates: [(query: String, score: Double)] = []

        if let pages = result.webDetection?.pagesWithMatchingImages {
            for page in pages.prefix(10) {
                if let urlString = page.url, let extracted = extractFromURL(urlString) {
                    candidates.append((extracted, 0.95))
                    print("🔗 URL extracted: \(extracted)")
                }
            }
            for page in pages.prefix(5) {
                if let title = page.pageTitle, let parsed = parseMusicPageTitle(title) {
                    candidates.append((parsed, 0.85))
                    print("📄 Music page: \(parsed)")
                }
            }
        }

        if let entities = result.webDetection?.webEntities {
            let music = entities.filter { isLikelyMusicEntity($0) }
            if music.count >= 2 {
                let pair = music.prefix(2).compactMap { $0.description }.joined(separator: " ")
                candidates.append((pair, 0.75))
            }
            if let top = music.first?.description { candidates.append((top, 0.6)) }
        }

        if let bestGuess = result.webDetection?.bestGuessLabels?.first?.label {
            candidates.append((cleanQuery(bestGuess), 0.65))
        }

        return candidates.max(by: { $0.score < $1.score })?.query
    }

    private func extractFromURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let lower = urlString.lowercased()
        let musicDomains = ["spotify.com", "deezer.com", "discogs.com", "allmusic.com",
                             "rateyourmusic.com", "musicbrainz.org", "last.fm",
                             "bandcamp.com", "pitchfork.com", "genius.com"]
        guard musicDomains.contains(where: { lower.contains($0) }) else { return nil }

        let path = url.path

        if lower.contains("discogs.com") {
            let components = path.components(separatedBy: "/").filter { !$0.isEmpty }
            if let slug = components.first, slug.count > 3 {
                let cleaned = slug
                    .components(separatedBy: "-")
                    .filter { !$0.allSatisfy({ $0.isNumber }) }
                    .joined(separator: " ")
                if cleaned.count > 3 { return cleaned }
            }
        }

        if lower.contains("rateyourmusic.com") {
            let components = path.components(separatedBy: "/").filter { !$0.isEmpty }
            if components.count >= 4 && components[0] == "release" {
                let artist = components[2].replacingOccurrences(of: "_", with: " ")
                let album  = components[3].replacingOccurrences(of: "_", with: " ")
                return "\(artist) \(album)"
            }
        }

        if lower.contains("bandcamp.com") {
            let components = path.components(separatedBy: "/").filter { !$0.isEmpty }
            if components.count >= 2 && components[0] == "album" {
                let albumSlug = components[1].replacingOccurrences(of: "-", with: " ")
                if let host = url.host {
                    let artistSlug = host
                        .replacingOccurrences(of: ".bandcamp.com", with: "")
                        .replacingOccurrences(of: "-", with: " ")
                    return "\(artistSlug) \(albumSlug)"
                }
                return albumSlug
            }
        }

        let components = path.components(separatedBy: "/").filter { segment in
            segment.contains(where: { $0.isLetter }) &&
            !segment.allSatisfy({ $0.isHexDigit || $0 == "-" }) &&
            segment.count > 3
        }

        if let slug = components.filter({ $0.contains("-") || $0.contains("_") })
                                 .max(by: { $0.count < $1.count }) {
            let cleaned = slug
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if cleaned.count > 5 { return cleaned }
        }

        return nil
    }

    // MARK: - Google Cloud Vision

    private func callVisionAPI(image: UIImage) async throws -> GoogleVisionResult {
        let resized = resizeImage(image, maxDimension: 1024)
        guard let imageData = resized.jpegData(compressionQuality: 0.85) else {
            throw RecognitionError.invalidImage
        }

        let body: [String: Any] = [
            "requests": [[
                "image": ["content": imageData.base64EncodedString()],
                "features": [
                    ["type": "WEB_DETECTION", "maxResults": 10],
                    ["type": "TEXT_DETECTION", "maxResults": 20]
                ],
                "imageContext": ["webDetectionParams": ["includeGeoResults": false]]
            ]]
        ]

        let url = URL(string: "https://vision.googleapis.com/v1/images:annotate?key=\(googleCloudAPIKey)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            print("❌ Vision API status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            throw RecognitionError.visionAPIFailed
        }

        guard let result = try JSONDecoder().decode(GoogleVisionResponse.self, from: data).responses.first else {
            throw RecognitionError.albumNotFound
        }
        return result
    }

    // MARK: - Deezer (audio previews)

    private func searchDeezerAlbum(query: String) async throws -> Album? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://api.deezer.com/search/album?q=\(encoded)&limit=3") else {
            throw RecognitionError.searchFailed
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RecognitionError.searchFailed
        }

        let sr = try JSONDecoder().decode(DeezerSearchResponse.self, from: data)
        guard let first = sr.data.first else { return nil }
        print("🎵 Deezer found: \(first.title)")
        return try await fetchDeezerAlbumDetails(albumID: first.id)
    }

    private func fetchDeezerAlbumDetails(albumID: Int) async throws -> Album {
        guard let url = URL(string: "https://api.deezer.com/album/\(albumID)") else {
            throw RecognitionError.searchFailed
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RecognitionError.searchFailed
        }
        let a = try JSONDecoder().decode(DeezerAlbum.self, from: data)
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

    // MARK: - Helpers

    private func isLikelyMusicEntity(_ entity: WebEntity) -> Bool {
        guard let desc = entity.description, let score = entity.score, score > 0.35 else { return false }
        let lower = desc.lowercased()
        let skip: Set<String> = ["art", "modern", "music", "album", "song", "audio", "sound",
                                  "record", "vinyl", "cd", "lp", "ep", "cover", "artwork",
                                  "photo", "image", "picture", "photograph", "illustration",
                                  "band", "singer", "artist", "musician", "genre",
                                  "pop", "rock", "jazz", "blues", "country",
                                  "the", "a", "an", "of", "in", "and", "or"]
        let words = lower.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return !(words.count == 1 && skip.contains(lower))
    }

    private func extractOCRLines(from annotations: [TextAnnotation]?) -> [String] {
        guard let full = annotations?.first?.description else { return [] }
        return full
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 && $0.count <= 60 && Double($0) == nil }
    }

    private func parseMusicPageTitle(_ title: String) -> String? {
        let lower = title.lowercased()
        let platforms = ["spotify", "deezer", "apple music", "itunes", "amazon music",
                          "tidal", "bandcamp", "soundcloud", "allmusic", "pitchfork",
                          "discogs", "genius", "last.fm", "rateyourmusic"]
        guard platforms.contains(where: { lower.contains($0) }) else { return nil }

        if title.contains(" - ") {
            let parts = title.components(separatedBy: " - ")
            if parts.count >= 2 {
                let artist = parts[0].trimmingCharacters(in: .whitespaces)
                let album = parts[1]
                    .components(separatedBy: " | ").first?
                    .components(separatedBy: " – ").first?
                    .components(separatedBy: " on ").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !artist.isEmpty && !album.isEmpty && artist.count < 60 {
                    return "\(removeEditorial(artist)) \(removeEditorial(album))"
                }
            }
        }

        if let range = lower.range(of: " by ") {
            let before = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let after = String(title[range.upperBound...])
                .components(separatedBy: " | ").first?
                .components(separatedBy: " on ").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !before.isEmpty && !after.isEmpty { return "\(after) \(before)" }
        }

        return nil
    }

    private func removeEditorial(_ text: String) -> String {
        let words = [" review", " album review", " exclusive", " interview",
                     " feature", " analysis", " ranked", " ranking",
                     " explained", " breakdown", " history"]
        var out = text
        for w in words { out = out.replacingOccurrences(of: w, with: "", options: .caseInsensitive) }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private func cleanQuery(_ raw: String) -> String {
        let remove = [" album", " cover", " art", " artwork", " deezer", " spotify",
                      " apple music", " vinyl", " cd", " cassette", " lp", " ep",
                      " record", " music video", " official"]
        var out = raw
        for term in remove { out = out.replacingOccurrences(of: term, with: "", options: .caseInsensitive) }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private func simplifyQuery(_ query: String) -> String {
        let noise: Set<String> = ["the", "a", "an", "deluxe", "edition", "remastered",
                                   "explicit", "version", "volume", "vol", "ep", "lp",
                                   "original", "soundtrack", "ost"]
        return query.lowercased()
            .components(separatedBy: .whitespaces)
            .filter { !noise.contains($0) && !$0.isEmpty }
            .prefix(4)
            .joined(separator: " ")
    }

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let scale = min(maxDimension / image.size.width, maxDimension / image.size.height)
        if scale >= 1.0 { return image }
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return resized ?? image
    }
}

// MARK: - Errors

enum RecognitionError: LocalizedError {
    case albumNotFound, searchFailed, invalidImage, visionAPIFailed, notAnAlbum
    var errorDescription: String? {
        switch self {
        case .notAnAlbum:      return "That doesn't look like an album. Point at a vinyl, CD, or cassette."
        case .albumNotFound:   return "Couldn't find this album. Try again with better lighting."
        case .searchFailed:    return "Search failed. Check your internet connection."
        case .invalidImage:    return "Invalid image."
        case .visionAPIFailed: return "Vision API failed. Check your API key."
        }
    }
}

// MARK: - Google Vision Models

struct GoogleVisionResponse: Codable { let responses: [GoogleVisionResult] }
struct GoogleVisionResult: Codable {
    let webDetection: WebDetection?
    let textAnnotations: [TextAnnotation]?
}
struct WebDetection: Codable {
    let webEntities: [WebEntity]?
    let bestGuessLabels: [BestGuessLabel]?
    let pagesWithMatchingImages: [WebPage]?
}
struct WebEntity: Codable { let description: String?; let score: Double? }
struct BestGuessLabel: Codable { let label: String }
struct WebPage: Codable { let pageTitle: String?; let url: String? }
struct TextAnnotation: Codable { let description: String }

// MARK: - Discogs Models

struct DiscogsSearchResponse: Codable {
    let results: [DiscogsSearchResult]
}

struct DiscogsSearchResult: Codable {
    let id: Int
    let title: String        // "Artist - Album Title"
    let year: String?
    let genre: [String]?
    let format: [String]?    // ["Vinyl", "LP"] or ["CD"] or ["Cassette"]
    let cover_image: String?
    let thumb: String?
    let uri: String?         // "/Weird-Al-Yankovic-Poodle-Hat/release/12345"
}

// MARK: - Deezer Models

struct DeezerSearchResponse: Codable { let data: [DeezerAlbumSimplified] }
struct DeezerAlbumSimplified: Codable {
    let id: Int
    let title: String
    let artist: DeezerArtist
    let cover_medium: String?
}
struct DeezerAlbum: Codable {
    let id: Int; let title: String; let artist: DeezerArtist
    let cover_xl: String; let release_date: String
    let genres: DeezerGenres?; let tracks: DeezerTracks; let link: String
}
struct DeezerArtist: Codable { let name: String }
struct DeezerGenres: Codable { let data: [DeezerGenre] }
struct DeezerGenre: Codable { let name: String }
struct DeezerTracks: Codable { let data: [DeezerTrack] }
struct DeezerTrack: Codable {
    let id: Int; let title: String; let duration: Int
    let preview: String; let rank: Int?
}
