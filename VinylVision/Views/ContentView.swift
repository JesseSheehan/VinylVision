//
//  ContentView.swift
//  VinylVision
//

import SwiftUI

struct ContentView: View {
    #if os(visionOS)
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    #endif
    @Environment(AppState.self) private var appState

    @State private var showCamera = false
    @State private var showHistory = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // ── Main content fills entire screen ──────────────────
            Group {
                if let album = appState.currentAlbum {
                    AlbumDetailView(album: album)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .id(album.id)
                } else {
                    WelcomeView(showHistory: $showHistory)
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: appState.currentAlbum?.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Floating bottom: now playing + tab bar ─────────────
            VStack(spacing: 0) {
                NowPlayingBar()
                    .animation(
                        .spring(response: 0.3, dampingFraction: 0.7),
                        value: appState.currentTrack?.id
                    )

                BottomBar(showCamera: $showCamera, showHistory: $showHistory)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .bottom)
        .fullScreenCover(isPresented: $showCamera) {
            CameraView()
                .environment(appState)
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
                .environment(appState)
        }
        .onChange(of: showCamera) { _, isShowing in
            if isShowing {
                // Stop music when opening camera
                AudioPlayerManager.shared.stop()
                appState.isPlaying = false
                appState.currentTrack = nil
            }
        }
    }
}

// MARK: - Bottom Bar

struct BottomBar: View {
    @Environment(AppState.self) private var appState
    @Binding var showCamera: Bool
    @Binding var showHistory: Bool
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 0) {
            // History tab
            Button {
                showHistory = true
            } label: {
                VStack(spacing: 3) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 22))

                        // Badge if history exists
                        if !appState.recentAlbums.isEmpty {
                            Text("\(min(appState.recentAlbums.count, 99))")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(.orange)
                                .clipShape(Capsule())
                                .offset(x: 10, y: -6)
                        }
                    }
                    Text("History")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            // Scan - center, prominent
            Button {
                showCamera = true
            } label: {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [.purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 58, height: 58)
                        .shadow(color: .purple.opacity(0.45), radius: 10, x: 0, y: 4)

                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            // Settings tab
            Button {
                showSettings = true
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "gear")
                        .font(.system(size: 22))
                    Text("Settings")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
        .padding(.bottom, safeAreaBottom)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .environment(appState)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
    }

    private var safeAreaBottom: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.bottom) ?? 0
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @Binding var showHistory: Bool

    @State private var isSpinning = false
    @State private var appeared = false
    @State private var glowPulse = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Spinning vinyl record
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [.purple.opacity(glowPulse ? 0.4 : 0.1), .clear],
                        center: .center, startRadius: 20, endRadius: 110
                    ))
                    .frame(width: 220, height: 220)
                    .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: glowPulse)

                ZStack {
                    Circle().fill(.black).frame(width: 150, height: 150)
                    ForEach([0.85, 0.7, 0.55, 0.4], id: \.self) { s in
                        Circle()
                            .stroke(Color.white.opacity(0.07), lineWidth: 1.5)
                            .frame(width: 150 * s, height: 150 * s)
                    }
                    Circle()
                        .fill(LinearGradient(
                            colors: [.purple, .pink],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 44, height: 44)
                    Circle().fill(.black).frame(width: 8, height: 8)
                }
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .animation(.linear(duration: 6).repeatForever(autoreverses: false), value: isSpinning)
            }
            .scaleEffect(appeared ? 1.0 : 0.6)
            .opacity(appeared ? 1 : 0)

            Spacer().frame(height: 28)

            // Title
            VStack(spacing: 8) {
                Text("VinylVision")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(
                        colors: [.purple, .pink, .orange],
                        startPoint: .leading, endPoint: .trailing
                    ))

                Text("Point your camera at any vinyl,\nCD, or cassette tape.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)

            Spacer().frame(height: 28)

            // Feature pills
            VStack(spacing: 10) {
                FeaturePill(icon: "camera.viewfinder", text: "Instant album recognition", color: .purple)
                FeaturePill(icon: "music.note.list",   text: "Full track listings",        color: .pink)
                FeaturePill(icon: "play.circle.fill",  text: "30-second previews",         color: .orange)
            }
            .padding(.horizontal, 24)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 30)

            AlbumSearchButton(style: .plain)
                .environment(appState)
                .padding(.top, 8)
            
            Spacer()

            // History teaser
            if !appState.recentAlbums.isEmpty {
                Button {
                    showHistory = true
                } label: {
                    HStack(spacing: 12) {
                        // Stacked thumbnails
                        HStack(spacing: -10) {
                            ForEach(appState.recentAlbums.prefix(3)) { album in
                                AsyncImage(url: URL(string: album.imageURL)) { img in
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Color.secondary.opacity(0.3)
                                }
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(uiColor: .systemBackground), lineWidth: 2)
                                )
                            }
                        }

                        Text("\(appState.recentAlbums.count) recent album\(appState.recentAlbums.count == 1 ? "" : "s")")
                            .font(.subheadline).foregroundStyle(.secondary)

                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .opacity(appeared ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.1)) {
                appeared = true
            }
            isSpinning = true
            glowPulse = true
        }
    }
}

struct FeaturePill: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
