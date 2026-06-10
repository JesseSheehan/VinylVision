//
//  HistoryView.swift
//  VinylVision
//
//  Created by Jesse Sheehan on 5/18/26.
//


//
//  HistoryView.swift
//  VinylVision
//

import SwiftUI

struct HistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAlbum: Album?

    var body: some View {
        NavigationStack {
            Group {
                if appState.recentAlbums.isEmpty {
                    emptyState
                } else {
                    albumList
                }
            }
            .navigationTitle("Recent Albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !appState.recentAlbums.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear", role: .destructive) {
                            appState.recentAlbums.removeAll()
                        }
                    }
                }
            }
            .navigationDestination(item: $selectedAlbum) { album in
                AlbumDetailView(album: album, isFromHistory: true)
                    .environment(appState)
            }
        }
    }

    private var albumList: some View {
        List {
            ForEach(appState.recentAlbums) { album in
                Button {
                    selectedAlbum = album
                } label: {
                    AlbumHistoryRow(album: album)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            .onDelete { indexSet in
                appState.recentAlbums.remove(atOffsets: indexSet)
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("No Albums Yet")
                .font(.title2).fontWeight(.bold)

            Text("Albums you scan will appear here.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

struct AlbumHistoryRow: View {
    let album: Album

    var body: some View {
        HStack(spacing: 14) {
            // Artwork
            AsyncImage(url: URL(string: album.imageURL)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay(Image(systemName: "opticaldisc").foregroundStyle(.secondary))
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 3)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(album.name)
                    .font(.subheadline).fontWeight(.semibold)
                    .lineLimit(1).foregroundStyle(.primary)

                Text(album.artist)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(album.releaseYear)
                        .font(.caption2).foregroundStyle(.secondary)

                    if let genre = album.genres.first {
                        Text("·")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(genre)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}