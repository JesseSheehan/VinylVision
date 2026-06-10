//
//  SettingsView.swift
//  AlbumScanner
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("playMostPopular") private var playMostPopular = false
    
    var body: some View {
        Form {
            Section {
                Toggle("Auto-play on recognition", isOn: $autoPlay)
                    .onChange(of: autoPlay) { _, newValue in
                        appState.autoPlay = newValue
                    }
                
                Picker("Default track", selection: $playMostPopular) {
                    Text("First track").tag(false)
                    Text("Most popular track").tag(true)
                }
                .onChange(of: playMostPopular) { _, newValue in
                    appState.playMostPopular = newValue
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Choose which track plays automatically when an album is recognized.")
            }
            
            Section {
                HStack {
                    Text("Music Service")
                    Spacer()
                    Text("Spotify (Free Previews)")
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text("Preview Length")
                    Spacer()
                    Text("30 seconds")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Audio")
            } footer: {
                Text("Free 30-second previews provided by Spotify. For full playback, connect your Spotify or Apple Music account.")
            }
            
            Section {
                Button("Reset Current Album") {
                    appState.reset()
                }
                .foregroundStyle(.red)
            }
            
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        #if os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            appState.autoPlay = autoPlay
            appState.playMostPopular = playMostPopular
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(AppState())
    }
}
