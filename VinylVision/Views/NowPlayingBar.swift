//
//  NowPlayingBar.swift
//  VinylVision
//

import SwiftUI

struct NowPlayingBar: View {
    @Environment(AppState.self) private var appState
    @ObservedObject private var player = AudioPlayerManager.shared

    private var sortedTracks: [Track] {
        appState.currentAlbum?.tracks.sorted { $0.trackNumber < $1.trackNumber } ?? []
    }

    private var currentIndex: Int? {
        guard let current = appState.currentTrack else { return nil }
        return sortedTracks.firstIndex { $0.id == current.id }
    }

    private var canPrev: Bool { (currentIndex ?? 0) > 0 }
    private var canNext: Bool {
        guard let idx = currentIndex else { return false }
        return idx < sortedTracks.count - 1
    }

    var body: some View {
        if let track = appState.currentTrack {
            VStack(spacing: 0) {
                // Progress bar along top edge
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.clear)
                        Rectangle()
                            .fill(LinearGradient(
                                colors: [.orange, .pink],
                                startPoint: .leading, endPoint: .trailing
                            ))
                            .frame(width: player.duration > 0
                                ? geo.size.width * CGFloat(player.currentTime / player.duration)
                                : 0
                            )
                            .animation(.linear(duration: 0.1), value: player.currentTime)
                    }
                }
                .frame(height: 3)

                HStack(spacing: 12) {
                    // Animated icon
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [.orange, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 38, height: 38)
                        if player.isPlaying {
                            MiniWaveform().frame(width: 18, height: 14)
                        } else {
                            Image(systemName: "pause.fill")
                                .font(.caption2).foregroundStyle(.white)
                        }
                    }

                    // Track info
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.name)
                            .font(.subheadline).fontWeight(.semibold).lineLimit(1)
                        if let album = appState.currentAlbum {
                            Text(album.artist)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }

                    Spacer()

                    // Time remaining
                    if player.duration > 0 {
                        Text("-\(timeString(max(0, player.duration - player.currentTime)))")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }

                    // ◀ Previous
                    Button { playPrevious() } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(canPrev ? .primary : .quaternary)
                    }
                    .disabled(!canPrev)

                    // ⏸ Play/Pause
                    Button {
                        if player.isPlaying {
                            player.pause(); appState.isPlaying = false
                        } else {
                            player.resume(); appState.isPlaying = true
                        }
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(LinearGradient(
                                colors: [.orange, .pink],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                            .contentTransition(.symbolEffect(.replace))
                    }

                    // ▶ Next
                    Button { playNext() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(canNext ? .primary : .quaternary)
                    }
                    .disabled(!canNext)

                    // ✕ Stop
                    Button {
                        player.stop()
                        appState.isPlaying = false
                        appState.currentTrack = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: -4)
        }
    }

    private func playNext() {
        guard let idx = currentIndex, idx + 1 < sortedTracks.count else { return }
        play(sortedTracks[idx + 1])
    }

    private func playPrevious() {
        guard let idx = currentIndex, idx - 1 >= 0 else { return }
        play(sortedTracks[idx - 1])
    }

    private func play(_ track: Track) {
        appState.currentTrack = track
        guard let url = track.previewURL, !url.isEmpty else { return }
        AudioPlayerManager.shared.play(url: url)
        appState.isPlaying = true
    }

    private func timeString(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite else { return "0:00" }
        return String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
    }
}
