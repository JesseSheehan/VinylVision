//
//  AlbumScannerApp.swift
//  AlbumScanner
//
//  Created for visionOS 2.6+ / iOS 18+
//

import SwiftUI

@main
struct VinylVisionApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        #if os(visionOS)
        // visionOS: Window + Immersive Space for camera
        WindowGroup {
            ContentView()
                .environment(appState)
        }

        ImmersiveSpace(id: "camera") {
            CameraView()
                .environment(appState)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        #else
        // iOS/iPadOS: Standard window
        WindowGroup {
            ContentView()
                .environment(appState)
                .ignoresSafeArea()
        }
        .windowResizability(.contentSize)
        
        #endif
    }
    
}
