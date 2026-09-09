import SwiftUI

/// What the 3-2-1 countdown leads into once it finishes.
enum PendingResumeAction {
    case resume
    case retry
}

/// Small control that opens the pause menu. Embedded inside a specific play window's own HUD
/// (only Player 1's, in multiplayer) rather than floating at a fixed screen position, so it
/// never sits on top of another player's note-touch area — a fixed corner would land inside
/// some window's actual hit-test zone in 2P/4P and risk being tapped by accident mid-play.
struct PauseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.black.opacity(0.45))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
        }
    }
}

/// Centered pause menu shown while the game session is paused. A full-screen scrim behind it
/// blocks all touches from reaching the paused game underneath.
struct PauseMenuOverlay: View {
    let onResume: () -> Void
    let onRetry: () -> Void
    let onGoToSongList: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {} // swallow taps so the game underneath never sees them

            VStack(spacing: 20) {
                Text("일시정지")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)
                    .shadow(color: .cyan, radius: 10)

                VStack(spacing: 12) {
                    menuButton(title: "이어하기", tint: .cyan, action: onResume)
                    menuButton(title: "다시하기", tint: .white, action: onRetry)
                    menuButton(title: "곡 선택 화면으로 돌아가기", tint: .orange, action: onGoToSongList)
                }
            }
            .padding(28)
            .frame(maxWidth: 380)
            .background(Color(red: 0.06, green: 0.07, blue: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.cyan.opacity(0.4), lineWidth: 1)
            )
        }
    }

    private func menuButton(title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding()
                .background(tint.opacity(0.15))
                .foregroundStyle(tint)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(tint.opacity(0.7), lineWidth: 1)
                )
        }
    }
}

/// Shown after "이어하기"/"다시하기" instead of resuming immediately — the underlying game
/// stays paused/frozen (and, for a retry, isn't reset yet) until this counts 3-2-1 and calls
/// `onFinished`, which is what actually unpauses or restarts. A full-screen scrim keeps
/// blocking touches the whole time, same as the pause menu itself.
struct CountdownOverlayView: View {
    let onFinished: () -> Void

    @State private var remaining = 3

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            Text("\(remaining)")
                .font(.system(size: 120, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .cyan, radius: 24)
                .shadow(color: .cyan, radius: 10)
                .id(remaining)
                .transition(.scale.combined(with: .opacity))
        }
        .onAppear { scheduleTick() }
    }

    private func scheduleTick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if remaining > 1 {
                withAnimation(.easeOut(duration: 0.25)) { remaining -= 1 }
                scheduleTick()
            } else {
                onFinished()
            }
        }
    }
}
