import SwiftUI

struct PlayerSetupView: View {
    let song: Song
    @EnvironmentObject private var router: AppRouter
    @StateObject private var library = SongLibraryStore.shared

    @State private var playerCount = 1
    @State private var selectedInstruments: [Instrument] = []

    private let playerCountOptions = [1, 2, 4]

    /// Re-reads from the live store rather than trusting the `song` snapshot passed in at
    /// navigation time, so a best score just recorded this session is reflected immediately.
    private var currentSong: Song {
        library.songs.first(where: { $0.id == song.id }) ?? song
    }

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.10)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                VStack(spacing: 4) {
                    Text(song.title)
                        .font(.title.weight(.heavy))
                        .foregroundStyle(.white)
                    Text(song.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 24)

                HStack(spacing: 12) {
                    ForEach(playerCountOptions, id: \.self) { count in
                        playerCountButton(count)
                    }
                }

                bestScoresSection

                VStack(spacing: 12) {
                    ForEach(0..<playerCount, id: \.self) { slot in
                        instrumentSlot(index: slot)
                    }
                }
                .padding(.horizontal)

                Spacer()

                Button {
                    router.push(.game(song: song, instruments: selectedInstruments))
                } label: {
                    Text("Start")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: 240)
                        .padding()
                        .background(Color.cyan.opacity(0.2))
                        .foregroundStyle(.cyan)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.cyan, lineWidth: 1)
                        )
                }
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("인원/악기 선택")
        .onAppear { syncInstrumentSlots() }
        .onChange(of: playerCount) { _, _ in syncInstrumentSlots() }
    }

    /// Keeps `selectedInstruments` sized to `playerCount`, defaulting new slots to a
    /// different available instrument each (cycling if there are more players than
    /// instruments) so players don't all default onto the same one.
    private func syncInstrumentSlots() {
        guard !song.availableInstruments.isEmpty else { return }
        while selectedInstruments.count < playerCount {
            let next = song.availableInstruments[selectedInstruments.count % song.availableInstruments.count]
            selectedInstruments.append(next)
        }
        if selectedInstruments.count > playerCount {
            selectedInstruments.removeLast(selectedInstruments.count - playerCount)
        }
    }

    /// Shows this song's best-ever "종합 점수/등급" for each player count, entirely
    /// independent per count — "기록 없음" for a mode never played yet.
    private var bestScoresSection: some View {
        HStack(spacing: 10) {
            ForEach(playerCountOptions, id: \.self) { count in
                bestScoreCard(count)
            }
        }
        .padding(.horizontal)
    }

    private func bestScoreCard(_ count: Int) -> some View {
        let best = currentSong.bestResults?[count]
        return VStack(spacing: 4) {
            Text("\(count)인 최고")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.5))
            if let best {
                Text(best.grade.rawValue)
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.yellow)
                Text("\(best.score)점")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Text("기록 없음")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    private func playerCountButton(_ count: Int) -> some View {
        let isSelected = playerCount == count
        return Button {
            playerCount = count
        } label: {
            Text("\(count)인")
                .font(.headline.weight(.bold))
                .frame(width: 72, height: 44)
                .background(isSelected ? Color.cyan.opacity(0.25) : Color.white.opacity(0.06))
                .foregroundStyle(isSelected ? .cyan : Color.white.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color.cyan : Color.white.opacity(0.2), lineWidth: 1)
                )
        }
    }

    private func instrumentSlot(index: Int) -> some View {
        let selected = selectedInstruments.indices.contains(index) ? selectedInstruments[index] : nil
        return Menu {
            ForEach(song.availableInstruments, id: \.self) { instrument in
                Button(instrument.label) {
                    guard selectedInstruments.indices.contains(index) else { return }
                    selectedInstruments[index] = instrument
                }
            }
        } label: {
            HStack {
                Text("PLAYER \(index + 1)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text(selected?.label ?? "악기 선택")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selected?.neonColor ?? .white)
            }
            .padding()
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke((selected?.neonColor ?? .white).opacity(0.6), lineWidth: 1)
            )
        }
    }
}
