//
//  SettingsView.swift
//  AlbumScanner
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("playMostPopular") private var playMostPopular = false
    @AppStorage("preferredStreamingService") private var preferredServiceRaw = StreamingService.appleMusic.rawValue
    
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
                Picker("Streaming Service", selection: $preferredServiceRaw) {
                    ForEach(StreamingService.allCases) { service in
                        Text(service.displayName).tag(service.rawValue)
                    }
                }
                .onChange(of: preferredServiceRaw) { _, newValue in
                    if let service = StreamingService(rawValue: newValue) {
                        appState.preferredStreamingService = service
                    }
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
                Text("Choose where the album page opens for full playback. 30-second previews are powered by Deezer.")
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
            if let service = StreamingService(rawValue: preferredServiceRaw) {
                appState.preferredStreamingService = service
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(AppState())
    }
}
