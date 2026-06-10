//
//  AlbumDetailView.swift
//  VinylVision
//

import SwiftUI

struct AlbumDetailView: View {
    let album: Album
    let isFromHistory: Bool

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var isSpinning = false
    @State private var artworkAppeared = false
    @State private var infoAppeared = false
    @State private var tracksAppeared = false
    //@State private var showSearch = false   // ← "Wrong album?" sheet

    init(album: Album, isFromHistory: Bool = false) {
        self.album = album
        self.isFromHistory = isFromHistory
    }

    private var sortedTracks: [Track] {
        album.tracks.sorted { $0.trackNumber < $1.trackNumber }
    }

    private var currentIndex: Int? {
        guard let current = appState.currentTrack else { return nil }
        return sortedTracks.firstIndex { $0.id == current.id }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // ── Back button (history only) ─────────────────────
                if isFromHistory {
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }

                // ── Artwork + info ─────────────────────────────────
                VStack(spacing: 14) {
                    // Small spinning artwork
                    ZStack {
                        ZStack {
                            Circle().fill(.black).frame(width: artworkSize, height: artworkSize)
                            ForEach([0.85, 0.7, 0.55, 0.4], id: \.self) { s in
                                Circle()
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    .frame(width: artworkSize * s, height: artworkSize * s)
                            }
                            Circle()
                                .fill(LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: artworkSize * 0.28)
                            Circle().fill(.black).frame(width: 7, height: 7)
                        }
                        .rotationEffect(.degrees(isSpinning ? 360 : 0))
                        .animation(
                            isSpinning ? .linear(duration: 4).repeatForever(autoreverses: false) : .default,
                            value: isSpinning
                        )
                        .offset(x: appState.isPlaying ? artworkSize * 0.28 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: appState.isPlaying)

                        AsyncImage(url: URL(string: album.imageURL)) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(.quaternary).overlay(ProgressView())
                        }
                        .frame(width: artworkSize, height: artworkSize)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
                        .rotationEffect(.degrees(isSpinning ? 360 : 0))
                        .animation(
                            isSpinning ? .linear(duration: 8).repeatForever(autoreverses: false) : .default,
                            value: isSpinning
                        )
                        #if os(visionOS)
                        .offset(z: 20)
                        #endif
                    }
                    .scaleEffect(artworkAppeared ? 1 : 0.7)
                    .opacity(artworkAppeared ? 1 : 0)
                    .padding(.top, 20)

                    // Album info
                    VStack(spacing: 6) {
                        Text(album.name)
                            .font(.title2).fontWeight(.bold)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        Text(album.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            if !album.releaseYear.isEmpty {
                                Label(album.releaseYear, systemImage: "calendar")
                            }
                            if let genre = album.genres.first {
                                Label(genre, systemImage: "music.note")
                            }
                            Label("\(album.tracks.count) tracks", systemImage: "list.bullet")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .opacity(infoAppeared ? 1 : 0)
                    .offset(y: infoAppeared ? 0 : 16)

                    // Action buttons
                    HStack(spacing: 10) {
                        if let deezerURL = album.deezerURL, let url = URL(string: deezerURL) {
                            Link(destination: url) {
                                Label("Deezer", systemImage: "music.note.list")
                                    .font(.caption).fontWeight(.medium)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(.orange)
                                    .clipShape(Capsule())
                            }
                        }
                        if let wikiURL = album.wikipediaSearchURL {
                            Link(destination: wikiURL) {
                                Label("Wikipedia", systemImage: "book")
                                    .font(.caption).fontWeight(.medium)
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .opacity(infoAppeared ? 1 : 0)

                    // ── "Wrong album?" button ──────────────────────
//                    if !isFromHistory {
//                        Button {
//                            showSearch = true
//                        } label: {
//                            HStack(spacing: 6) {
//                                Image(systemName: "magnifyingglass")
//                                    .font(.caption)
//                                Text("Wrong album?")
//                                    .font(.caption)
//                            }
//                            .foregroundStyle(.secondary)
//                            .padding(.horizontal, 14)
//                            .padding(.vertical, 7)
//                            .background(.ultraThinMaterial)
//                            .clipShape(Capsule())
//                            .overlay(
//                                Capsule()
//                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
//                            )
//                        }
//                        .opacity(infoAppeared ? 1 : 0)
//                    }
                }
                .padding(.horizontal, 24)

                // ── Track list ─────────────────────────────────────
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Tracks")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if album.tracks.isEmpty {
                            Text("No preview available")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 8)

                    if album.tracks.isEmpty {
                        // No tracks - show a helpful message
                        VStack(spacing: 12) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("Track listing not available")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("This album was identified but audio\npreviews aren't available on Deezer.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
//                            Button {
//                                showSearch = true
//                            } label: {
//                                Label("Search for another version", systemImage: "arrow.triangle.2.circlepath")
//                                    .font(.caption)
//                                    .foregroundStyle(.orange)
//                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        ForEach(Array(sortedTracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(
                                track: track,
                                isPlaying: appState.currentTrack?.id == track.id
                            )
                            .onTapGesture { playTrack(track) }

                            if index < sortedTracks.count - 1 {
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.ultraThinMaterial)
                )
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 120)
                .opacity(tracksAppeared ? 1 : 0)
                .offset(y: tracksAppeared ? 0 : 30)
            }
        }
        .background(
            LinearGradient(
                colors: [.purple.opacity(0.15), .pink.opacity(0.08), Color(uiColor: .systemBackground)],
                startPoint: .top, endPoint: .center
            )
            .ignoresSafeArea()
        )
        .onAppear {
            animateIn()
            if appState.autoPlay && !isFromHistory {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    autoPlayTrack()
                }
            }
        }
        .onChange(of: appState.isPlaying) { _, playing in
            withAnimation { isSpinning = playing }
        }
        .onDisappear {
            isSpinning = false
        }
//        .sheet(isPresented: $showSearch) {
//            AlbumSearchView()
//                .environment(appState)
//        }
        
        AlbumSearchButton(style: .capsule)
            .environment(appState)
            .opacity(infoAppeared ? 1 : 0)
    }

    // MARK: - Sizing

    private var artworkSize: CGFloat {
        #if os(visionOS)
        return 200
        #else
        return 160
        #endif
    }

    // MARK: - Animations

    private func animateIn() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1)) {
            artworkAppeared = true
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.25)) {
            infoAppeared = true
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.4)) {
            tracksAppeared = true
        }
    }

    // MARK: - Playback

    private func autoPlayTrack() {
        guard let track = trackToPlay else { return }
        playTrack(track)
    }

    private var trackToPlay: Track? {
        appState.playMostPopular
            ? album.tracks.max(by: { $0.popularity < $1.popularity })
            : sortedTracks.first
    }

    func playTrack(_ track: Track) {
        appState.currentTrack = track
        guard let previewURL = track.previewURL, !previewURL.isEmpty else {
            appState.errorMessage = "No preview available"
            return
        }
        AudioPlayerManager.shared.play(url: previewURL)
        appState.isPlaying = true
    }

    func playNext() {
        guard let idx = currentIndex, idx + 1 < sortedTracks.count else { return }
        playTrack(sortedTracks[idx + 1])
    }

    func playPrevious() {
        guard let idx = currentIndex, idx - 1 >= 0 else { return }
        playTrack(sortedTracks[idx - 1])
    }

    var canPlayNext: Bool {
        guard let idx = currentIndex else { return false }
        return idx + 1 < sortedTracks.count
    }

    var canPlayPrevious: Bool {
        guard let idx = currentIndex else { return false }
        return idx - 1 >= 0
    }
}

// MARK: - Track Row

struct TrackRow: View {
    let track: Track
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if isPlaying {
                    MiniWaveform()
                } else {
                    Text("\(track.trackNumber)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                }
            }
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.subheadline)
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .foregroundStyle(isPlaying ? .orange : .primary)
                    .lineLimit(1)
            }

            Spacer()

            Text(track.durationFormatted)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(isPlaying ? Color.orange.opacity(0.08) : Color.clear)
        .animation(.easeInOut(duration: 0.2), value: isPlaying)
    }
}

// MARK: - Mini Waveform

struct MiniWaveform: View {
    @State private var heights: [CGFloat] = [0.4, 0.8, 0.5, 1.0, 0.6]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.orange)
                    .frame(width: 3, height: 16 * heights[i])
            }
        }
        .onAppear {
            for i in 0..<5 {
                withAnimation(
                    .easeInOut(duration: Double.random(in: 0.3...0.6))
                    .repeatForever(autoreverses: true)
                    .delay(Double(i) * 0.1)
                ) {
                    heights[i] = CGFloat.random(in: 0.3...1.0)
                }
            }
        }
    }
}
