//
//  AlbumSearchButton.swift
//  VinylVision
//  Created by Jesse Sheehan on 5/20/26.
//  Reusable button that opens AlbumSearchView as a sheet.
//  Drop it anywhere: welcome screen, retry overlay, album detail, etc.

import SwiftUI

struct AlbumSearchButton: View {
    @Environment(AppState.self) private var appState

    /// Optional pre-fill text. If nil, uses current album's artist+name.
    var prefill: String? = nil

    /// Visual style
    var style: SearchButtonStyle = .capsule

    @State private var showSearch = false

    enum SearchButtonStyle {
        case capsule        // Small subtle pill - good for album detail
        case prominent      // Larger filled button - good for retry overlay
        case plain          // Text only - good for welcome screen
    }

    var body: some View {
        Button { showSearch = true } label: {
            switch style {
            case .capsule:
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.caption)
                    Text("Search manually").font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))

            case .prominent:
                Label("Search Manually", systemImage: "magnifyingglass")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())

            case .plain:
                Label("Manually search for an album", systemImage: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showSearch) {
            AlbumSearchView(initialQuery: resolvedPrefill)
                .environment(appState)
        }
    }

    private var resolvedPrefill: String {
        if let prefill { return prefill }
        guard let album = appState.currentAlbum else { return "" }
        return "\(album.artist) \(album.name)"
    }
}
