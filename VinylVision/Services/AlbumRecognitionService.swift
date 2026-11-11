//
//  AlbumRecognitionService.swift
//  VinylVision
//
//  Recognition pipeline:
//  Google Vision / Gemini / Google Lens (SerpApi)
//      → Discogs (best match) → Deezer (audio previews)
//      ↘ Deezer search fallback if Discogs fails
//

import Foundation
import UIKit

class AlbumRecognitionService {
    static let shared = AlbumRecognitionService()

    private let googleCloudAPIKey = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLOUD_API_KEY") as? String ?? ""
    private let discogsToken = Bundle.main.object(forInfoDictionaryKey: "DISCOGS_TOKEN") as? String ?? ""
    private let geminiAPIKey = Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String ?? ""
    private let serpApiKey = Bundle.main.object(forInfoDictionaryKey: "SERPAPI_KEY") as? String ?? ""

    private init() {}

    // MARK: - Main Entry Point

    func recognizeAlbum(from image: UIImage?, useGemini: Bool = false, useLens: Bool = false) async throws -> RecognitionResult {
        guard let image = image else { throw RecognitionError.invalidImage }

        if useLens {
            return try await recognizeWithLens(image: image)
        }
        if useGemini {
            return try await recognizeWithGemini(image: image)
        }

        let result = try await callVisionAPI(image: image)

        // Raw reverse-image-search results, logged before scoring so a low
        // score can be told apart from "Google found nothing".
        let web = result.webDetection
        print("🌐 Web best guess: \(web?.bestGuessLabels?.map { $0.label } ?? [])")
        print("🌐 Web entities: \(web?.webEntities?.prefix(8).map { "\($0.description ?? "?") (\(String(format: "%.2f", $0.score ?? 0)))" } ?? [])")
        print("🌐 Web pages: \(web?.pagesWithMatchingImages?.prefix(5).map { $0.pageTitle ?? $0.url ?? "?" } ?? [])")

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

        // Cleaned, de-duplicated OCR lines — useful as manual-search suggestions
        // when confidence is low.
        var seenOCR = Set<String>()
        let cleanedOCRLines = ocrLines
            .compactMap { cleanOCRLine($0) }
            .filter { seenOCR.insert($0.lowercased()).inserted }

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
                return RecognitionResult(album: album, confidence: musicScore, ocrLines: cleanedOCRLines)
            }
        }

        print("⚠️ Discogs exhausted, falling back to Deezer")

        // ── Stage 2: Fall back to Deezer directly ─────────────────────
        for query in queriesToTry {
            print("🎵 Trying Deezer: \(query)")
            if let album = try await searchDeezerAlbum(query: query) {
                print("✅ Deezer hit: \(album.name) by \(album.artist)")
                return RecognitionResult(album: album, confidence: musicScore, ocrLines: cleanedOCRLines)
            }
        }

        throw RecognitionError.albumNotFound
    }

    // MARK: - Gemini Recognition

    private func recognizeWithGemini(image: UIImage) async throws -> RecognitionResult {
        let (identification, usage) = try await callGeminiAPI(image: image)
        let tokenSummary = usage?.summary ?? "unreported"

        guard identification.isAlbumPackaging else {
            print("🚫 Gemini says this isn't album packaging - bailing")
            throw RecognitionError.notAnAlbum
        }

        let candidates = identification.rankedCandidates
        guard !candidates.isEmpty else { throw RecognitionError.albumNotFound }

        // Gemini reports near-certain confidence even when it's guessing a
        // textless cover from memory, and those guesses are often a famous album
        // that merely looks similar. Cap them below the UI's low-confidence
        // threshold so the user is offered manual search.
        let artworkOnlyCap = identification.hasReadableText ? 1.0 : 0.45

        // Suggestion chips for the manual-search sheet: every candidate Gemini
        // proposed, plus any text it actually read off the sleeve.
        var seenSuggestion = Set<String>()
        let suggestions = (candidates.map { $0.searchQuery } + identification.visibleText)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seenSuggestion.insert($0.lowercased()).inserted }

        func found(_ album: Album, confidence: Double) -> RecognitionResult {
            print("✅ Matched: \(album.name) by \(album.artist)")
            print("🤖 Gemini tokens for this result — \(tokenSummary)")
            return RecognitionResult(album: album, confidence: min(confidence, artworkOnlyCap), ocrLines: suggestions)
        }

        // ── Stage 0: catalogue number — pins the exact release ────────
        if let catno = identification.catalogNumber?.trimmingCharacters(in: .whitespaces), !catno.isEmpty {
            print("💿 Trying Discogs catalogue number: \(catno)")
            if let album = try await searchDiscogsByCatalogNumber(catno, candidates: candidates) {
                return found(album, confidence: candidates[0].confidence)
            }
        }

        // Words actually read off the sleeve. When the artist or title is printed,
        // a candidate must agree with it — this stops Gemini swapping in a
        // better-known artist with a similar name for one it doesn't know.
        let sleeveWords = identification.visibleText.reduce(into: Set<String>()) { $0.formUnion(wordTokens($1)) }
        let checkSleeve = identification.hasReadableText && !sleeveWords.isEmpty
        let printed = checkSleeve
            ? candidates.filter { isPrintedOnSleeve(artist: $0.artist, album: $0.album, sleeveWords: sleeveWords) }
            : candidates
        let unprinted = candidates.filter { candidate in
            !printed.contains { $0.searchQuery == candidate.searchQuery }
        }
        if !unprinted.isEmpty {
            print("🧐 Not printed on the sleeve, trying last: \(unprinted.map { $0.searchQuery })")
        }

        /// Discogs then Deezer for each candidate. A candidate only "hits" if a
        /// result's title actually matches, so a wrong top result moves on to the
        /// next candidate instead of being accepted.
        func lookUp(_ list: [GeminiAlbumCandidate], maxConfidence: Double = 1) async throws -> RecognitionResult? {
            for candidate in list {
                print("💿 Trying Discogs with Gemini candidate: \(candidate.searchQuery) (\(String(format: "%.2f", candidate.confidence)))")
                if let album = try await searchViaDiscogs(artist: candidate.artist, album: candidate.album) {
                    return found(album, confidence: min(candidate.confidence, maxConfidence))
                }
            }
            for candidate in list {
                print("🎵 Trying Deezer with Gemini candidate: \(candidate.searchQuery)")
                if let album = try await searchDeezerAlbum(artist: candidate.artist, album: candidate.album) {
                    return found(album, confidence: min(candidate.confidence, maxConfidence))
                }
            }
            return nil
        }

        // ── Stage 1: candidates consistent with the printed text ──────
        if let result = try await lookUp(printed) { return result }

        // ── Stage 2: search with the sleeve text itself ───────────────
        if checkSleeve, let album = try await searchBySleeveText(identification.visibleText, sleeveWords: sleeveWords) {
            return found(album, confidence: 0.7)
        }

        // ── Stage 3: candidates that contradict the printed text ──────
        // Low confidence so the UI offers manual search.
        if let result = try await lookUp(unprinted, maxConfidence: 0.4) { return result }

        // ── Stage 4: unverified best guess ────────────────────────────
        // Nothing matched exactly; take Discogs' top hit for the leading
        // candidate, but report low confidence so the UI offers manual search.
        print("⚠️ No verified match, using Discogs' best guess")
        if let album = try await searchViaDiscogs(query: candidates[0].searchQuery) {
            return found(album, confidence: min(candidates[0].confidence, 0.4))
        }

        throw RecognitionError.albumNotFound
    }

    private func callGeminiAPI(image: UIImage) async throws -> (identification: GeminiIdentification, usage: GeminiTokenUsage?) {
        guard !geminiAPIKey.isEmpty else {
            print("⚠️ No Gemini API key configured")
            throw RecognitionError.visionAPIFailed
        }

        // Textless covers are identified from fine artwork detail — grain, label
        // logos, spine print — so this path uses a larger, less-compressed image
        // than the Vision path.
        let resized = resizeImage(image, maxDimension: 1536)
        guard let imageData = resized.jpegData(compressionQuality: 0.9) else {
            throw RecognitionError.invalidImage
        }

        let prompt = """
        You are a record-store clerk with encyclopedic knowledge of album artwork. \
        The photo shows physical music packaging — a vinyl LP sleeve, a CD jewel case or digipak, \
        or a cassette J-card — usually held up in a room, at an angle, under imperfect light.

        Work through it in this order:

        1. Read every piece of text: artist, title, spine, catalogue number, record label, \
        hype sticker, small print. Text is the strongest signal when it exists. If a catalogue \
        number is legible (usually on the spine, back, or label — e.g. "SHVL 804", "BLP 4003", \
        "4AD CAD 3"), copy it exactly as printed. Text is often rotated — running sideways up \
        an edge or spine, or vertically down the cover — or set in a stylised typeface; turn \
        the image in your head and read it. List every line you read in visibleText.

        When an artist or title is printed, your candidates MUST use it exactly as printed, \
        even for an artist you have never heard of. An unfamiliar name printed on the sleeve \
        is far more likely than a famous album with similar-looking art. Never replace a \
        printed name with a better-known artist who shares part of it (a sleeve reading \
        "Smith" is not Patti Smith unless "Patti" is printed too). Printed text overrides \
        the artwork reasoning in step 2, and an identification read from printed text \
        deserves high confidence even if you don't know the release.

        2. MANY GREAT COVERS HAVE NO TITLE OR ARTIST ON THEM AT ALL. If text is absent, \
        obscured, or in a script you can't read, identify the release from the artwork alone. Use:
           - the exact photograph, painting or illustration, and how it is cropped
           - faces of recognizable musicians
           - emblems, sigils and symbols (a prism, four runes, a banana, a zipper, a burning man)
           - typeface, colour palette, borders, and era-specific design language
           - a label's house style (Blue Note, ECM, 4AD, Factory, Sub Pop, Impulse!)
           - format and pressing cues: gatefold, obi strip, "STEREO"/"MONO" banner, matrix text
        Reason about which specific release the art belongs to before answering.

        3. If you recognize the artist but not the release, choose the release whose known cover \
        art actually matches what you see. Do NOT fall back on that artist's most famous album \
        unless the artwork matches it.

        4. Give the title as it is catalogued (Discogs / MusicBrainz style), preferring the \
        original release over reissues and compilations. For an untitled or self-titled release, \
        make the catalogued form your first candidate and the colloquial name a second candidate \
        (e.g. "Led Zeppelin - Untitled" then "Led Zeppelin - Led Zeppelin IV"; \
        "The Beatles - The Beatles" then "The Beatles - White Album"). \
        The album field is the title only — no artist name, year, format, or edition words \
        like "Remastered" or "Deluxe". Spell artist and title exactly as officially released.

        5. Each candidate is checked against Discogs by exact title, so candidates 2 and 3 should \
        be genuinely different releases (e.g. the artist's adjacent albums with similar art), \
        not rewordings of candidate 1.

        Return 1-3 candidates, most likely first. When unsure between plausible releases, \
        return them all rather than guessing one — a later database lookup will settle it. \
        Set confidence honestly: 0.9+ only when you are certain of both artist and release, \
        0.5-0.8 when the artist is certain but the release is inferred, below 0.4 for a guess. \
        Return an empty candidate list rather than inventing a release you don't recognize — \
        but if an artist or title is printed, always return it as a candidate.
        """

        // Structured output: the shape is enforced by the API, so there's no
        // free-text format to parse (or for the model to editorialize around).
        let responseSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "isAlbumPackaging": [
                    "type": "boolean",
                    "description": "True only if the photo shows a vinyl sleeve, CD case, or cassette."
                ],
                "hasReadableText": [
                    "type": "boolean",
                    "description": "True if artist or title text is legible on the packaging."
                ],
                "visibleText": [
                    "type": "array",
                    "description": "Text lines actually read off the packaging, most prominent first. Empty for a textless cover.",
                    "items": ["type": "string"]
                ],
                "catalogNumber": [
                    "type": "string",
                    "description": "Catalogue number exactly as printed on the packaging. Empty string if none is legible."
                ],
                "candidates": [
                    "type": "array",
                    "description": "Up to 3 releases, most likely first. Empty if unrecognized.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "artist": ["type": "string"],
                            "album": ["type": "string"],
                            "confidence": [
                                "type": "number",
                                "description": "0.0 to 1.0."
                            ],
                            "identifiedFrom": [
                                "type": "string",
                                "description": "Which cue settled it.",
                                "enum": ["text", "artwork", "both"]
                            ]
                        ],
                        "required": ["artist", "album", "confidence", "identifiedFrom"],
                        "propertyOrdering": ["artist", "album", "confidence", "identifiedFrom"]
                    ]
                ]
            ],
            "required": ["isAlbumPackaging", "hasReadableText", "visibleText", "catalogNumber", "candidates"],
            "propertyOrdering": ["isAlbumPackaging", "hasReadableText", "visibleText", "catalogNumber", "candidates"]
        ]

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["inline_data": [
                        "mime_type": "image/jpeg",
                        "data": imageData.base64EncodedString()
                    ]],
                    ["text": prompt]
                ]
            ]],
            "generationConfig": [
                // Slightly above zero so the candidate list isn't three
                // near-identical restatements of the same guess.
                "temperature": 0.2,
                "responseMimeType": "application/json",
                "responseSchema": responseSchema,
                // Thinking tokens are billed against maxOutputTokens on Gemini 2.5,
                // so this budget covers reasoning *and* the JSON payload. Recalling
                // a textless cover genuinely benefits from a few hundred tokens of
                // deliberation, so unlike the old prompt we fund it — but cap it so
                // a stubborn image can't run away with the request.
                "thinkingConfig": ["thinkingBudget": 1024],
                "maxOutputTokens": 2048
            ]
        ]

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(geminiAPIKey)") else {
            throw RecognitionError.visionAPIFailed
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("❌ Gemini status: \(code)")
            if let body = String(data: data, encoding: .utf8) { print("   body: \(body.prefix(500))") }
            throw RecognitionError.visionAPIFailed
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)

        let usage = decoded.usageMetadata.map(GeminiTokenUsage.init)
        if let usage {
            print("🤖 Gemini tokens — \(usage.summary)")
        }

        let candidate = decoded.candidates.first

        // If thinking consumed the whole budget the JSON arrives truncated —
        // worth naming explicitly, since it looks like a decode failure otherwise.
        if candidate?.finishReason == "MAX_TOKENS" {
            print("⚠️ Gemini hit maxOutputTokens before finishing its answer")
        }

        guard let text = candidate?.content?.parts?.first?.text,
              let payload = text.data(using: .utf8) else {
            print("❌ Gemini returned no text (finishReason: \(candidate?.finishReason ?? "none"))")
            throw RecognitionError.albumNotFound
        }

        let identification = try JSONDecoder().decode(GeminiIdentification.self, from: payload)
        print("🤖 Gemini read: \(identification.visibleText), catno: \(identification.catalogNumber ?? "")")
        print("🤖 Gemini: album=\(identification.isAlbumPackaging), text=\(identification.hasReadableText), candidates=\(identification.rankedCandidates.map { "\($0.searchQuery) [\($0.identifiedFrom ?? "?")]" })")
        return (identification, usage)
    }

    // MARK: - Google Lens (SerpApi) Recognition

    /// Identifies the album with Google Lens via SerpApi: upload the photo, read
    /// what Lens matched it to, then confirm the match on Discogs / Deezer.
    private func recognizeWithLens(image: UIImage) async throws -> RecognitionResult {
        guard !serpApiKey.isEmpty else {
            print("⚠️ No SerpApi key configured")
            throw RecognitionError.visionAPIFailed
        }

        let imageID = try await uploadToSerpApi(image)
        let lens = try await callGoogleLens(imageID: imageID)
        print("🔍 Lens knowledge graph: \(lens.knowledge.map { "\($0.title) — \($0.subtitle)" })")
        print("🔍 Lens matches: \(lens.matchTitles.prefix(8).map { $0 })")

        guard !lens.knowledge.isEmpty || !lens.matchTitles.isEmpty else {
            throw RecognitionError.albumNotFound
        }
        let suggestions = Array(lens.matchTitles.prefix(5).map(cleanLensTitle))

        // How many Lens matches name this album — several pages agreeing is
        // much stronger evidence than one.
        func confidence(for album: Album) -> Double {
            let title = titleCore(album.name), artist = artistTokens(album.artist)
            let agreeing = lens.matchTitles.prefix(10).filter { matchTitle in
                let words = wordTokens(matchTitle)
                return title.isSubset(of: words) && (artist.isEmpty || artist.isSubset(of: words))
            }.count
            return min(0.5 + 0.1 * Double(agreeing), 0.9)
        }

        // ── Stage 1: Lens's own identification ("New — Album by Paul McCartney")
        for entry in lens.knowledge {
            guard let artist = albumArtist(fromLensSubtitle: entry.subtitle) else { continue }
            print("💿 Trying Lens identification: \(entry.title) by \(artist)")
            var found = try await searchViaDiscogs(artist: artist, album: entry.title)
            if found == nil { found = try await searchDeezerAlbum(artist: artist, album: entry.title) }
            if let album = found {
                print("✅ Matched: \(album.name) by \(album.artist)")
                return RecognitionResult(album: album, confidence: 0.9, ocrLines: suggestions)
            }
        }

        // ── Stage 2: artist/album pairs read from matching page titles ──
        // ("New - song and lyrics by Paul McCartney | Spotify"). Pages vote, so
        // the album most pages name is tried first, then it goes through the
        // same strict artist + title search as Gemini's candidates.
        for pair in lensVotedPairs(lens.matchTitles.prefix(10)).prefix(4) {
            print("💿 Trying Lens pages' pick: \(pair.album) by \(pair.artist) (\(pair.votes) page(s))")
            var found = try await searchViaDiscogs(artist: pair.artist, album: pair.album)
            if found == nil { found = try await searchDeezerAlbum(artist: pair.artist, album: pair.album) }
            if let album = found {
                let score = confidence(for: album)
                print("✅ Matched: \(album.name) by \(album.artist) (\(String(format: "%.2f", score)))")
                return RecognitionResult(album: album, confidence: score, ocrLines: suggestions)
            }
        }

        // ── Stage 3: page titles as free text ─────────────────────────
        // A result only counts if its artist and title both appear in that page title.
        for title in lens.matchTitles.prefix(6) {
            let query = cleanLensTitle(title)
            guard !query.isEmpty else { continue }
            if let album = try await searchBySleeveText([query], sleeveWords: wordTokens(title)) {
                let score = confidence(for: album)
                print("✅ Matched: \(album.name) by \(album.artist) (\(String(format: "%.2f", score)))")
                return RecognitionResult(album: album, confidence: score, ocrLines: suggestions)
            }
        }

        throw RecognitionError.albumNotFound
    }

    /// Uploads the photo to SerpApi's Image API, returning an ID Google Lens can
    /// search by. SerpApi deletes uploads after 10 minutes, and caps them at 500 KB.
    private func uploadToSerpApi(_ image: UIImage) async throws -> String {
        let resized = resizeImage(image, maxDimension: 1024)
        var quality: CGFloat = 0.85
        var jpeg = resized.jpegData(compressionQuality: quality)
        while let data = jpeg, data.count > 480_000, quality > 0.3 {
            quality -= 0.15
            jpeg = resized.jpegData(compressionQuality: quality)
        }
        guard let imageData = jpeg else { throw RecognitionError.invalidImage }

        let boundary = "VinylVision-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"api_key\"\r\n\r\n\(serpApiKey)\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"scan.jpg\"\r\n")
        append("Content-Type: image/jpeg\r\n\r\n")
        body.append(imageData)
        append("\r\n--\(boundary)--\r\n")

        guard let url = URL(string: "https://serpapi.com/image") else { throw RecognitionError.visionAPIFailed }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let imageID = json?["image_id"] as? String else {
            print("❌ SerpApi upload failed: \((response as? HTTPURLResponse)?.statusCode ?? 0) \(json?["error"] ?? "")")
            throw RecognitionError.visionAPIFailed
        }
        print("🔍 Uploaded to SerpApi (\(imageData.count / 1024) KB)")
        return imageID
    }

    private struct LensResult {
        /// Lens's own identification, e.g. ("New", "Album by Paul McCartney").
        var knowledge: [(title: String, subtitle: String)] = []
        /// Titles of pages whose images matched, most similar first.
        var matchTitles: [String] = []
    }

    private func callGoogleLens(imageID: String) async throws -> LensResult {
        var components = URLComponents(string: "https://serpapi.com/search.json")
        components?.queryItems = [
            URLQueryItem(name: "engine", value: "google_lens"),
            URLQueryItem(name: "image_id", value: imageID),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "api_key", value: serpApiKey)
        ]
        guard let url = components?.url else { throw RecognitionError.visionAPIFailed }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        // Parsed loosely: SerpApi's Lens response varies by result type, and
        // knowledge_graph can arrive as an object or an array.
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let message = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            print("❌ Google Lens failed: \((response as? HTTPURLResponse)?.statusCode ?? 0) \(message)")
            throw RecognitionError.visionAPIFailed
        }

        var result = LensResult()
        let graph = (json["knowledge_graph"] as? [[String: Any]])
            ?? (json["knowledge_graph"] as? [String: Any]).map { [$0] } ?? []
        result.knowledge = graph.compactMap { entry in
            guard let title = entry["title"] as? String else { return nil }
            return (title, (entry["subtitle"] as? String) ?? "")
        }
        result.matchTitles = ((json["visual_matches"] as? [[String: Any]]) ?? [])
            .compactMap { $0["title"] as? String }
        return result
    }

    /// "Album by Paul McCartney" → "Paul McCartney". Nil unless the subtitle
    /// says it's an album or record, so a Lens ID of "neon sign" is ignored.
    private func albumArtist(fromLensSubtitle subtitle: String) -> String? {
        let lower = subtitle.lowercased()
        guard ["album", "ep", "soundtrack", "record"].contains(where: { lower.contains($0) }),
              let range = subtitle.range(of: " by ", options: .caseInsensitive) else { return nil }
        let artist = subtitle[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return artist.isEmpty ? nil : artist
    }

    /// Reads (artist, album) guesses out of matching page titles and ranks them
    /// by how many pages name each.
    ///
    /// Titles that state the order ("Actor - Album by St. Vincent", "New by Paul
    /// McCartney") count fully. A plain dash ("St. Vincent – Actor") is ambiguous,
    /// so it votes for both readings but weaker — and slightly favours
    /// "Artist – Album", the usual convention on music sites. That way the
    /// unambiguous pages settle the order instead of a coin flip.
    private func lensVotedPairs<S: Sequence>(_ titles: S) -> [(artist: String, album: String, votes: Int)] where S.Element == String {
        let explicitWeight = 10, artistFirstWeight = 6, albumFirstWeight = 5
        var votes: [String: (artist: String, album: String, score: Int, pages: Int, first: Int)] = [:]

        for (index, raw) in titles.enumerated() {
            var title = raw.components(separatedBy: " | ").first ?? raw
            title = title.replacingOccurrences(of: #"(?i)^(stream|play|listen to|buy)\s+"#, with: "", options: .regularExpression)
            title = title.replacingOccurrences(of: #"(?i)\s+on\s+(amazon music|apple music|spotify|soundcloud|deezer|youtube).*$"#,
                                               with: "", options: .regularExpression)

            var pairs: [(artist: String, album: String, weight: Int)] = []
            if let m = title.firstMatch(of: /(?i)^(.+?)\s+[-–]\s+(?:song and lyrics|album|single|song|ep)\s+by\s+(.+)$/) {
                pairs = [(String(m.2), String(m.1), explicitWeight)]
            } else if let m = title.firstMatch(of: /(?i)^(.+?)\s+by\s+(.+)$/) {
                pairs = [(String(m.2), String(m.1), explicitWeight)]
            } else if let m = title.firstMatch(of: /^(.+?)\s+[-–]\s+(.+)$/) {
                pairs = [(String(m.1), String(m.2), artistFirstWeight),
                         (String(m.2), String(m.1), albumFirstWeight)]
            }

            // Each page votes once per distinct pair.
            var seenOnThisPage = Set<String>()
            for (rawArtist, rawAlbum, weight) in pairs {
                // Site noise first ("… for sale online"), so shop brackets end up trailing.
                let artist = lensArtistName(stripTrailingBrackets(cleanLensTitle(rawArtist)))
                let album = stripTrailingBrackets(cleanLensTitle(rawAlbum))
                guard !artist.isEmpty, !album.isEmpty, artist.count < 60, album.count < 80 else { continue }
                let key = artistTokens(artist).sorted().joined(separator: " ") + "|" + titleCore(album).sorted().joined(separator: " ")
                guard seenOnThisPage.insert(key).inserted else { continue }
                if let existing = votes[key] {
                    votes[key]?.score = existing.score + weight
                    votes[key]?.pages = existing.pages + 1
                } else {
                    votes[key] = (artist, album, weight, 1, index)
                }
            }
        }

        return votes.values
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.first < $1.first }
            .map { ($0.artist, $0.album, $0.pages) }
    }

    /// Drops trailing shop details: "Mccartney, Paul (Record, 2018)" → "Mccartney, Paul".
    private func stripTrailingBrackets(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, with: "", options: .regularExpression)
    }

    /// Catalogue-style "Last, First" → "First Last" ("Mccartney, Paul" → "Paul Mccartney").
    /// Only for short two-part names, so band names with commas are left alone.
    private func lensArtistName(_ s: String) -> String {
        let parts = s.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              parts.allSatisfy({ $0.split(separator: " ").count <= 2 }) else { return s }
        return "\(parts[1]) \(parts[0])"
    }

    /// Strips shop and site noise from a matching page's title so it works as a
    /// search query: "Paul McCartney - New - Amazon.com Music" → "Paul McCartney - New".
    private func cleanLensTitle(_ title: String) -> String {
        var out = title.components(separatedBy: " | ").first ?? title
        // Streaming-page phrasing: "New - song and lyrics by Paul McCartney",
        // "Play New by Paul McCartney on Amazon Music", "Stream New by …".
        out = out.replacingOccurrences(of: #"(?i)^(stream|play|listen to|buy)\s+"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\s+on\s+(amazon music|apple music|spotify|soundcloud|deezer|youtube).*$"#,
                                       with: "", options: .regularExpression)
        let noise = ["song and lyrics by", "album by", "song by", "single by", "lyrics", "by",
                     "amazon.com:", "amazon.com", "amazon.co.uk", "ebay", "discogs", "spotify",
                     "apple music", "bandcamp", "rate your music", "allmusic", "wikipedia",
                     "youtube", "reddit", "pinterest", "instagram", "facebook", "tiktok", "etsy",
                     "vinyl", "lp", "cd", "cassette", "releases", "for sale online"]
        for phrase in noise {
            out = out.replacingOccurrences(of: #"(?i)\b\#(NSRegularExpression.escapedPattern(for: phrase))\b"#,
                                           with: " ", options: .regularExpression)
        }
        return out
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–:,"))
    }

    // MARK: - Discogs Search → then Deezer for audio

    /// Free-text Discogs search that trusts the top result. Used for OCR/web
    /// queries, where we don't know which part is the artist and which the title.
    private func searchViaDiscogs(query: String) async throws -> Album? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let results = try await discogsSearch([
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "release")
        ])
        guard let topResult = results.first else {
            print("🔍 Discogs: no results for \(query)")
            return nil
        }

        print("💿 Discogs found: \(topResult.title) [\(topResult.format?.joined(separator: ", ") ?? "unknown format")]")
        return try await resolveAudio(for: topResult)
    }

    /// Whether a candidate agrees with the text read off the sleeve: all of its
    /// artist words, or all of its title words, must be printed there.
    private func isPrintedOnSleeve(artist: String, album: String, sleeveWords: Set<String>) -> Bool {
        let artistWords = artistTokens(artist), titleWords = titleCore(album)
        return (!artistWords.isEmpty && artistWords.isSubset(of: sleeveWords))
            || (!titleWords.isEmpty && titleWords.isSubset(of: sleeveWords))
    }

    /// Searches Discogs, then Deezer, with the raw lines read off the sleeve.
    /// Only a result whose artist and title both appear in that text is kept.
    private func searchBySleeveText(_ lines: [String], sleeveWords: Set<String>) async throws -> Album? {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var queries = [cleaned.prefix(2).joined(separator: " ")]
        if cleaned.count > 2 { queries.append(cleaned.prefix(3).joined(separator: " ")) }

        func printed(artist: String, title: String) -> Bool {
            let titleWords = titleCore(title), artistWords = artistTokens(artist)
            guard !titleWords.isEmpty, titleWords.isSubset(of: sleeveWords) else { return false }
            guard isPlaceholderArtist(artist) || artistWords.isSubset(of: sleeveWords) else { return false }
            // The title's words must show up somewhere other than inside the
            // artist's name — otherwise "New - Paul McCartney" would accept his
            // self-titled "McCartney". Self-titled albums are exempt.
            let distinctive = titleWords.subtracting(artistWords)
            return distinctive.isEmpty ? titleWords == artistWords : distinctive.isSubset(of: sleeveWords)
        }

        for query in queries where !query.isEmpty {
            print("📜 Searching with text: \(query)")
            let discogs = try await discogsSearch([
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: "release")
            ])
            if let match = discogs.first(where: {
                let (artist, title) = parseDiscogsTitle($0.title)
                return printed(artist: artist, title: title)
            }) {
                print("💿 Discogs matched sleeve text: \(match.title)")
                return try await resolveAudio(for: match)
            }

            let deezer = try await deezerAlbumSearch(query)
            if let match = bestMatch(deezer, score: { result -> Int? in
                printed(artist: result.artist.name, title: result.title) ? (result.nb_tracks ?? 0) : nil
            }) {
                print("🎵 Deezer matched sleeve text: \(match.title) by \(match.artist.name)")
                return try await fetchDeezerAlbumDetails(albumID: match.id)
            }
        }

        print("🔍 Nothing matching the sleeve text")
        return nil
    }

    /// Fielded Discogs search for a known artist + album. Only returns a result
    /// whose title actually matches `album`, so a popular-but-wrong release by
    /// the same artist is rejected instead of accepted.
    private func searchViaDiscogs(artist: String, album: String) async throws -> Album? {
        guard !album.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let artistItem = artist.isEmpty ? [] : [URLQueryItem(name: "artist", value: artist)]
        let attempts: [[URLQueryItem]] = [
            // Masters group every pressing under one canonical entry, so the real
            // album outranks singles, compilations and bootlegs sharing its words.
            artistItem + [URLQueryItem(name: "release_title", value: album),
                          URLQueryItem(name: "type", value: "master")],
            // Some releases (often indie / private press) have no master.
            artistItem + [URLQueryItem(name: "release_title", value: album),
                          URLQueryItem(name: "type", value: "release")],
            // Free text tolerates wording differences the fielded search rejects;
            // the title check below still guards against a wrong album.
            [URLQueryItem(name: "q", value: "\(artist) \(album)"),
             URLQueryItem(name: "type", value: "master")]
        ]

        for items in attempts {
            let results = try await discogsSearch(items)
            if let match = bestMatch(results, score: { discogsMatchScore($0, artist: artist, album: album) }) {
                print("💿 Discogs matched: \(match.title)")
                return try await resolveAudio(for: match)
            }
        }

        print("🔍 Discogs: nothing titled '\(album)' by \(artist)")
        return nil
    }

    /// Looks up a printed catalogue number. Catalogue numbers aren't unique
    /// across labels, so the result must also match one of Gemini's artists.
    private func searchDiscogsByCatalogNumber(_ catno: String, candidates: [GeminiAlbumCandidate]) async throws -> Album? {
        let results = try await discogsSearch([
            URLQueryItem(name: "catno", value: catno),
            URLQueryItem(name: "type", value: "release")
        ])
        let match = results.first { result in
            let (artist, _) = parseDiscogsTitle(result.title)
            return candidates.contains { artistsMatch(artist, $0.artist) }
        }
        guard let match else {
            print("🔍 Discogs: no release for catalogue number \(catno) by a candidate artist")
            return nil
        }
        print("💿 Discogs catalogue match: \(match.title)")
        return try await resolveAudio(for: match)
    }

    /// Runs a Discogs database search and returns up to 10 results in relevance order.
    private func discogsSearch(_ items: [URLQueryItem]) async throws -> [DiscogsSearchResult] {
        guard !discogsToken.isEmpty else {
            print("⚠️ No Discogs token - skipping")
            return []
        }

        var components = URLComponents(string: "https://api.discogs.com/database/search")
        components?.queryItems = items + [
            URLQueryItem(name: "per_page", value: "10"),
            URLQueryItem(name: "token", value: discogsToken)
        ]
        // URLComponents leaves "+" unescaped, which servers read as a space.
        let encodedQuery = components?.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        guard let url = components?.url else { return [] }

        var req = URLRequest(url: url)
        // Discogs requires a User-Agent header
        req.setValue("VinylVision/1.0 +https://github.com/vinylvision", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            print("❌ Discogs error: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            return []
        }
        return try JSONDecoder().decode(DiscogsSearchResponse.self, from: data).results
    }

    /// Title-match score for a Discogs result, or nil if it's a different album
    /// or by an incompatible artist.
    private func discogsMatchScore(_ result: DiscogsSearchResult, artist: String, album: String) -> Int? {
        let (resultArtist, resultAlbum) = parseDiscogsTitle(result.title)
        guard let score = titleMatchScore(resultAlbum, album),
              artistCompatible(resultArtist, title: resultAlbum, expected: artist) else { return nil }
        return score
    }

    /// Finds Deezer audio for a Discogs release, or falls back to a Discogs-only
    /// Album so the user still sees the correct cover and title.
    private func resolveAudio(for result: DiscogsSearchResult) async throws -> Album {
        // Discogs title is usually "Artist - Album Title"
        let (artist, albumTitle) = parseDiscogsTitle(result.title)

        // "No Artist" / "Various" would only mislead Deezer's artist filter.
        let deezerArtist = isPlaceholderArtist(artist) ? "" : artist
        if let album = try await searchDeezerAlbum(artist: deezerArtist, album: albumTitle) {
            return album
        }

        print("ℹ️ Building album from Discogs data (no matching Deezer audio)")
        return buildDiscogsOnlyAlbum(from: result, artist: artist, albumTitle: albumTitle, year: result.year ?? "")
    }

    /// Parses a Discogs title like "Weird Al Yankovic - Poodle Hat"
    /// into ("Weird Al Yankovic", "Poodle Hat"). Strips Discogs' disambiguation
    /// markers from the artist (e.g. "McCartney*" or "Genesis (2)") so the
    /// follow-up Deezer query isn't garbled.
    private func parseDiscogsTitle(_ title: String) -> (artist: String, album: String) {
        if title.contains(" - ") {
            let parts = title.components(separatedBy: " - ")
            if parts.count >= 2 {
                let rawArtist = parts[0].trimmingCharacters(in: .whitespaces)
                let artist = cleanDiscogsArtist(rawArtist)
                let album  = parts[1...].joined(separator: " - ").trimmingCharacters(in: .whitespaces)
                return (artist, album)
            }
        }
        return ("", title.trimmingCharacters(in: .whitespaces))
    }

    /// Strips Discogs disambiguation suffixes: trailing `*` and trailing
    /// `(<digits>)` like "(2)", "(3)".
    private func cleanDiscogsArtist(_ raw: String) -> String {
        var out = raw
        // Remove trailing " (N)" disambiguation
        if let range = out.range(of: #"\s*\(\d+\)\s*$"#, options: .regularExpression) {
            out.removeSubrange(range)
        }
        // Remove trailing asterisks
        while out.hasSuffix("*") { out.removeLast() }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Title / Artist Matching

    /// Words that describe a release's edition or packaging rather than which
    /// album it is: "(Original Television Soundtrack)", "[Deluxe Edition]".
    private static let descriptorWords: Set<String> = [
        "the", "a", "an", "and",
        "deluxe", "edition", "remaster", "remastered", "expanded", "anniversary",
        "version", "mono", "stereo", "bonus", "track", "tracks", "reissue", "special",
        "original", "soundtrack", "ost", "television", "tv", "motion", "picture",
        "series", "score", "music", "from", "inspired", "by", "cast", "recording"
    ]

    /// Extra words that make a title a *different* album, not just a longer
    /// name for the same one ("Rumours" vs "Rumours Live").
    private static let distinguishingWords: Set<String> = [
        "live", "vol", "volume", "part", "pt", "demo", "demos", "sessions",
        "remix", "remixes", "remixed", "instrumental", "instrumentals", "acoustic",
        "unplugged", "greatest", "hits", "best", "essential", "collection",
        "anthology", "ep", "single", "christmas",
        // Re-recordings and leftovers are separate releases from the original.
        "revisited", "redux", "reimagined", "rerecorded", "unreleased", "outtakes",
        "rarities", "sides", "covers", "tribute"
    ]

    /// Regex fragment for edition info that's safe to drop when bracketed.
    private static let editionWords = #"remaster\w*|deluxe|edition|expanded|anniversary|version|mono|stereo|bonus|reissue"#

    /// How well two album titles name the same album, ignoring case, punctuation
    /// and descriptors like "(Original Soundtrack)":
    /// - 2: same words
    /// - 1: same main title with a different subtitle, or one title containing
    ///   the other ("Suspiria" ≈ "Suspiria (Music for the Luca Guadagnino Film)")
    /// - nil: different albums — including a differing number or variant word,
    ///   so "Led Zeppelin II" ≠ "Led Zeppelin IV" and "Rumours" ≠ "Rumours (Live)"
    private func titleMatchScore(_ a: String, _ b: String) -> Int? {
        let ta = titleCore(a), tb = titleCore(b)
        guard !ta.isEmpty, !tb.isEmpty else { return nil }
        if ta == tb { return 2 }

        // Any extra words must be a harmless subtitle, not "Live" or "Vol. 2".
        let extras = ta.symmetricDifference(tb)
        guard !extras.contains(where: { Self.distinguishingWords.contains($0) || isNumberLike($0) }) else {
            return nil
        }

        // Same main title, differing only in a bracketed or colon/dash subtitle.
        let mainA = titleCore(mainTitle(a)), mainB = titleCore(mainTitle(b))
        if !mainA.isEmpty, mainA == mainB { return 1 }

        // Otherwise one title must contain the other. A one-word title is too easy
        // to find inside unrelated ones ("Blue" ⊂ "Kind of Blue"), so it doesn't count.
        let (shorter, longer) = ta.count < tb.count ? (ta, tb) : (tb, ta)
        return shorter.count >= 2 && shorter.isSubset(of: longer) ? 1 : nil
    }

    /// The title before any subtitle: "Suspiria (Music for…)" → "Suspiria",
    /// "Mezzanine: Deluxe" → "Mezzanine". Empty when the title starts with a
    /// bracket, like "(What's the Story) Morning Glory?".
    private func mainTitle(_ s: String) -> String {
        let separators = ["(", "[", ":", " - ", " – "]
        let cut = separators.compactMap { s.range(of: $0)?.lowerBound }.min() ?? s.endIndex
        return String(s[..<cut])
    }

    private func titlesMatch(_ a: String, _ b: String) -> Bool {
        titleMatchScore(a, b) != nil
    }

    /// Artists match if they share a word, so "Beatles" ≈ "The Beatles" and
    /// "Simon & Garfunkel" ≈ "Simon and Garfunkel".
    private func artistsMatch(_ a: String, _ b: String) -> Bool {
        !artistTokens(a).isDisjoint(with: artistTokens(b))
    }

    /// Whether a result's artist credit is consistent with the artist we expected.
    /// Soundtracks and compilations are often credited to the show itself or to
    /// "Various Artists" rather than the band, so those credits don't veto a title match.
    private func artistCompatible(_ resultArtist: String, title resultTitle: String, expected: String) -> Bool {
        if expected.isEmpty || isPlaceholderArtist(resultArtist) || artistsMatch(resultArtist, expected) {
            return true
        }
        let creditWords = artistTokens(resultArtist)
        return !creditWords.isEmpty && creditWords.isSubset(of: wordTokens(resultTitle))
    }

    /// Credits Discogs/Deezer use when there's no single real artist.
    private func isPlaceholderArtist(_ artist: String) -> Bool {
        let placeholders: Set<String> = ["various", "various artists", "no artist", "unknown artist",
                                         "soundtrack", "original soundtrack", "original cast"]
        return placeholders.contains(artist.lowercased().trimmingCharacters(in: .whitespaces))
    }

    /// Returns the item with the highest score, keeping the earliest (most
    /// relevant) on ties; items scoring nil are rejected.
    private func bestMatch<T>(_ items: [T], score: (T) -> Int?) -> T? {
        var best: (item: T, score: Int)?
        for item in items {
            if let s = score(item), s > (best?.score ?? Int.min) { best = (item, s) }
        }
        return best?.item
    }

    /// Roman numerals, plain numbers and ordinals — the words that tell
    /// "Vol. 2" from "Vol. 3" or "II" from "IV".
    private func isNumberLike(_ word: String) -> Bool {
        word.range(of: #"^(\d+(st|nd|rd|th)?|x{0,3}(ix|iv|v?i{0,3}))$"#, options: .regularExpression) != nil
    }

    /// Title words that identify the album, with descriptors removed. A title
    /// made only of descriptors ("Original Soundtrack") keeps all its words.
    private func titleCore(_ s: String) -> Set<String> {
        var t = s.lowercased()
        // Drop bracketed or dashed edition info — "(Remastered 2011)", " - 2011 Remaster"
        // — whose years would otherwise look like a different album.
        t = t.replacingOccurrences(of: #"[\(\[][^\)\]]*\b(\#(Self.editionWords))\b[^\)\]]*[\)\]]"#,
                                   with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s[-–]\s.*\b(\#(Self.editionWords))\b.*$"#,
                                   with: " ", options: .regularExpression)
        let words = wordTokens(t)
        let core = words.subtracting(Self.descriptorWords)
        return core.isEmpty ? words : core
    }

    private func artistTokens(_ s: String) -> Set<String> {
        wordTokens(s).subtracting(["the", "a", "an", "and"])
    }

    /// Lowercased words with punctuation removed ("Sgt. Pepper's" → sgt, peppers).
    private func wordTokens(_ s: String) -> Set<String> {
        let t = s.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "&", with: " and ")
        let scrubbed = String(t.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        })
        return Set(scrubbed.split(separator: " ").map(String.init))
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

    /// Free-text Deezer search that trusts the top result.
    private func searchDeezerAlbum(query: String) async throws -> Album? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let first = try await deezerAlbumSearch(query).first else { return nil }
        print("🎵 Deezer found: \(first.title)")
        return try await fetchDeezerAlbumDetails(albumID: first.id)
    }

    /// Deezer search for a known artist + album. Deezer happily returns its most
    /// popular album for any query, so only a result whose title matches counts.
    private func searchDeezerAlbum(artist: String, album: String) async throws -> Album? {
        guard !album.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let quote: (String) -> String = { $0.replacingOccurrences(of: "\"", with: "") }
        let queries = artist.isEmpty
            ? [album]
            // Deezer's fielded syntax first, then plain text for looser spellings.
            : ["artist:\"\(quote(artist))\" album:\"\(quote(album))\"", "\(artist) \(album)"]

        for query in queries {
            let results = try await deezerAlbumSearch(query)
            // Exact titles beat contained ones; among equals, prefer the edition
            // with the most tracks (and so the most previews).
            if let match = bestMatch(results, score: { result -> Int? in
                guard let titleScore = titleMatchScore(result.title, album),
                      artistCompatible(result.artist.name, title: result.title, expected: artist) else { return nil }
                return titleScore * 1000 + min(result.nb_tracks ?? 0, 999)
            }) {
                print("🎵 Deezer matched: \(match.title) by \(match.artist.name)")
                return try await fetchDeezerAlbumDetails(albumID: match.id)
            }
        }

        // Search results are ranked by popularity, so a lesser-known album can be
        // missing from them. Fall back to the artist's own catalogue.
        if !artist.isEmpty, let match = try await deezerCatalogueMatch(artist: artist, album: album) {
            return try await fetchDeezerAlbumDetails(albumID: match)
        }

        print("⚠️ Deezer: nothing titled '\(album)' by \(artist)")
        return nil
    }

    /// Finds `album` in the artist's full Deezer catalogue, returning its album ID.
    /// Only the same album counts — never a different album by the same artist.
    private func deezerCatalogueMatch(artist: String, album: String) async throws -> Int? {
        let artists: [DeezerArtistResult] = try await deezerGet("search/artist", query: ["q": artist, "limit": "5"])
        // Prefer artists whose name matches exactly ("Thom Yorke", not "Tom York").
        // Deezer can have several artists with the same name — two "St. Vincent"s,
        // one of them a stub with a handful of releases — so try each, most fans first.
        let target = artistTokens(artist)
        var namesakes = artists.filter { artistTokens($0.name) == target }
            .sorted { ($0.nb_fan ?? 0) > ($1.nb_fan ?? 0) }
        if namesakes.isEmpty, let close = artists.first(where: { artistsMatch($0.name, artist) }) {
            namesakes = [close]
        }

        for found in namesakes.prefix(3) {
            var catalogue: [DeezerArtistAlbum] = []
            var page = 0
            // Three pages of 100 covers all but the most prolific catalogues.
            while page < 3 {
                let batch: [DeezerArtistAlbum] = try await deezerGet("artist/\(found.id)/albums",
                                                                      query: ["limit": "100", "index": "\(page * 100)"])
                catalogue += batch
                if batch.count < 100 { break }
                page += 1
            }

            // Exact titles beat subtitled ones; full albums beat singles and EPs.
            if let match = bestMatch(catalogue, score: { item -> Int? in
                guard let titleScore = titleMatchScore(item.title, album) else { return nil }
                return titleScore * 10 + (item.record_type == "album" ? 1 : 0)
            }) {
                print("🎵 Deezer catalogue matched: \(match.title) by \(found.name)")
                return match.id
            }
        }
        return nil
    }

    /// GETs a Deezer list endpoint and returns its `data` array.
    private func deezerGet<T: Decodable>(_ path: String, query: [String: String]) async throws -> [T] {
        var components = URLComponents(string: "https://api.deezer.com/\(path)")
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw RecognitionError.searchFailed }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RecognitionError.searchFailed
        }
        return try JSONDecoder().decode(DeezerList<T>.self, from: data).data
    }

    private func deezerAlbumSearch(_ query: String) async throws -> [DeezerAlbumSimplified] {
        var components = URLComponents(string: "https://api.deezer.com/search/album")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "10")
        ]
        let encodedQuery = components?.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        guard let url = components?.url else { throw RecognitionError.searchFailed }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RecognitionError.searchFailed
        }
        return try JSONDecoder().decode(DeezerSearchResponse.self, from: data).data
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

// MARK: - Recognition Result

struct RecognitionResult {
    let album: Album
    /// Music confidence score from Vision API analysis (0.0 – ~1.0).
    /// Below ~0.5 means we matched something but aren't confident the source image
    /// was clearly an album cover — UI should suggest manual search.
    let confidence: Double
    /// Cleaned OCR lines extracted from the scanned image, surfaced as
    /// quick-fill chips on the manual search page for low-confidence matches.
    let ocrLines: [String]
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
    let nb_tracks: Int?
}
struct DeezerAlbum: Codable {
    let id: Int; let title: String; let artist: DeezerArtist
    let cover_xl: String; let release_date: String
    let genres: DeezerGenres?; let tracks: DeezerTracks; let link: String
}
struct DeezerArtist: Codable { let name: String }
struct DeezerList<T: Decodable>: Decodable { let data: [T] }
struct DeezerArtistResult: Codable { let id: Int; let name: String; let nb_fan: Int? }
struct DeezerArtistAlbum: Codable {
    let id: Int
    let title: String
    let record_type: String?   // "album", "single", "ep", "compile"
}
struct DeezerGenres: Codable { let data: [DeezerGenre] }
struct DeezerGenre: Codable { let name: String }
struct DeezerTracks: Codable { let data: [DeezerTrack] }
struct DeezerTrack: Codable {
    let id: Int; let title: String; let duration: Int
    let preview: String; let rank: Int?
}

// MARK: - Gemini Models

private struct GeminiResponse: Codable {
    let candidates: [Candidate]
    let usageMetadata: UsageMetadata?

    struct Candidate: Codable {
        // A truncated or blocked response can omit content entirely.
        let content: Content?
        let finishReason: String?
        struct Content: Codable {
            let parts: [Part]?
            struct Part: Codable { let text: String? }
        }
    }

    struct UsageMetadata: Codable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        /// Reasoning tokens — billed as output, and counted against maxOutputTokens.
        let thoughtsTokenCount: Int?
        let totalTokenCount: Int?
    }
}

/// Token counts for a single Gemini call, kept alongside the identification so
/// the cost of a scan can be logged next to the result it produced.
private struct GeminiTokenUsage {
    let prompt: Int
    let thinking: Int
    let output: Int
    let total: Int

    init(_ metadata: GeminiResponse.UsageMetadata) {
        prompt = metadata.promptTokenCount ?? 0
        thinking = metadata.thoughtsTokenCount ?? 0
        output = metadata.candidatesTokenCount ?? 0
        total = metadata.totalTokenCount ?? 0
    }

    var summary: String {
        "prompt: \(prompt), thinking: \(thinking), output: \(output), total: \(total)"
    }
}

/// The structured payload Gemini returns for a scanned cover, matching the
/// responseSchema sent with the request.
private struct GeminiIdentification: Codable {
    let isAlbumPackaging: Bool
    let hasReadableText: Bool
    let visibleText: [String]
    let catalogNumber: String?
    let candidates: [GeminiAlbumCandidate]

    /// Candidates sorted by the model's own confidence, with empty entries dropped.
    var rankedCandidates: [GeminiAlbumCandidate] {
        candidates
            .filter { !$0.searchQuery.isEmpty }
            .sorted { $0.confidence > $1.confidence }
    }
}

private struct GeminiAlbumCandidate: Codable {
    let artist: String
    let album: String
    let confidence: Double
    let identifiedFrom: String?

    /// "Artist Album" — what we hand to Discogs/Deezer.
    var searchQuery: String {
        [artist, album]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
