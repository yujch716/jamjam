import SwiftUI

struct PlayerSetupView: View {
    let song: Song
    @EnvironmentObject private var router: AppRouter

    @State private var playerCount = 1
    @State private var selectedInstrument: Instrument?
    @State private var showMultiplayerNotice = false

    private let playerCountOptions = [1, 2, 4]

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

                VStack(spacing: 12) {
                    ForEach(0..<playerCount, id: \.self) { slot in
                        instrumentSlot(index: slot)
                    }
                }
                .padding(.horizontal)

                Spacer()

                Button {
                    router.push(.game)
                } label: {
                    Text("재생")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: 240)
                        .padding()
                        .background(selectedInstrument == nil ? Color.white.opacity(0.05) : Color.cyan.opacity(0.2))
                        .foregroundStyle(selectedInstrument == nil ? Color.white.opacity(0.3) : .cyan)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(selectedInstrument == nil ? Color.white.opacity(0.15) : Color.cyan, lineWidth: 1)
                        )
                }
                .disabled(selectedInstrument == nil)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("인원/악기 선택")
        .onAppear {
            if selectedInstrument == nil {
                selectedInstrument = song.availableInstruments.first
            }
        }
        .alert("안내", isPresented: $showMultiplayerNotice) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("멀티플레이는 다음 업데이트에서 지원돼요. 지금은 1인 모드로 진행됩니다.")
        }
    }

    private func playerCountButton(_ count: Int) -> some View {
        let isSelected = playerCount == count
        return Button {
            playerCount = count
            if count != 1 { showMultiplayerNotice = true }
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

    @ViewBuilder
    private func instrumentSlot(index: Int) -> some View {
        if index == 0 {
            Menu {
                ForEach(song.availableInstruments, id: \.self) { instrument in
                    Button(instrument.displayName) { selectedInstrument = instrument }
                }
            } label: {
                slotLabel(
                    text: selectedInstrument?.displayName ?? "악기 선택",
                    color: selectedInstrument?.neonColor ?? .white,
                    enabled: true
                )
            }
        } else {
            // Only the first slot is functional for now — multiplayer windows aren't
            // implemented, so a real 2P/4P game never actually launches yet (see the
            // multiplayer notice above).
            slotLabel(text: "1인 모드에서는 사용되지 않음", color: .white, enabled: false)
        }
    }

    private func slotLabel(text: String, color: Color, enabled: Bool) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.white.opacity(enabled ? 0.06 : 0.03))
            .foregroundStyle(enabled ? color : Color.white.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(color.opacity(enabled ? 0.6 : 0.15), lineWidth: 1)
            )
    }
}
