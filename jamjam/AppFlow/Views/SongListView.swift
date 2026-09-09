import SwiftUI

struct SongListView: View {
    @EnvironmentObject private var router: AppRouter
    @State private var songs: [Song] = DummySongLibrary.makeSongs()

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.10)
                .ignoresSafeArea()

            List {
                ForEach(songs) { song in
                    songRow(song)
                        .listRowBackground(Color.white.opacity(0.05))
                        .swipeActions {
                            Button(role: .destructive) {
                                delete(song)
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("노래 리스트")
    }

    private func songRow(_ song: Song) -> some View {
        HStack(spacing: 12) {
            Button {
                toggleFavorite(song)
            } label: {
                Image(systemName: song.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(song.isFavorite ? .yellow : .white.opacity(0.35))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(song.formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.white.opacity(0.3))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            router.push(.playerSetup(song))
        }
    }

    private func toggleFavorite(_ song: Song) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        songs[index].isFavorite.toggle()
    }

    private func delete(_ song: Song) {
        songs.removeAll { $0.id == song.id }
    }
}
