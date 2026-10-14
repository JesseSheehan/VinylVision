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
    @AppStorage("useGeminiRecognition") private var useGeminiRecognition = false
    @AppStorage("autoPhotoEnabled") private var autoPhotoEnabled = true
    @AppStorage("showAutoPhotoToggle") private var showAutoPhotoToggle = true
    
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
                Toggle("Use Gemini AI", isOn: $useGeminiRecognition)
                    .onChange(of: useGeminiRecognition) { _, newValue in
                        appState.useGeminiRecognition = newValue
                    }
            } header: {
                Text("Recognition")
            } footer: {
                Text("When on, identify scanned albums with Gemini 2.5 Flash instead of OCR. Token usage is printed to the Xcode console.")
            }

            Section {
                Toggle("Auto-photograph", isOn: $autoPhotoEnabled)
                    .onChange(of: autoPhotoEnabled) { _, newValue in
                        appState.autoPhotoEnabled = newValue
                    }
                Toggle("Show on-camera toggle", isOn: $showAutoPhotoToggle)
                    .onChange(of: showAutoPhotoToggle) { _, newValue in
                        appState.showAutoPhotoToggle = newValue
                    }
            } header: {
                Text("Capture")
            } footer: {
                Text("When auto-photograph is on, the camera shutter fires automatically once an album is held steady. Turn off to capture manually with the shutter button.")
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
            appState.useGeminiRecognition = useGeminiRecognition
            appState.autoPhotoEnabled = autoPhotoEnabled
            appState.showAutoPhotoToggle = showAutoPhotoToggle
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
