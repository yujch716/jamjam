import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import UIKit

struct SongListView: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var library = SongLibraryStore.shared

    @State private var showFilePicker = false
    @State private var isImporting = false
    @State private var importStatusText = ""
    @State private var importProgress: Double = 0
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.10)
                .ignoresSafeArea()

            List {
                ForEach(library.songs) { song in
                    songRow(song)
                        .listRowBackground(Color.white.opacity(0.05))
                        .swipeActions {
                            Button(role: .destructive) {
                                library.delete(song)
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                }
            }
            .scrollContentBackground(.hidden)

            if isImporting {
                importOverlay
            }
        }
        .navigationTitle("노래 리스트")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showFilePicker = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(isImporting)
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.mp3], allowsMultipleSelection: false) { result in
            handlePickerResult(result)
        }
        .alert("음원 등록 실패", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var importOverlay: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView(value: importProgress)
                    .frame(width: 240)
                    .tint(.cyan)
                Text(importStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                Text("보통 곡 하나당 20초~1분 정도 걸려요")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Text("처리 중에는 화면을 끄거나 앱을 나가지 마세요")
                    .font(.caption)
                    .foregroundStyle(.orange.opacity(0.8))
            }
            .padding(28)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }

    private func songRow(_ song: Song) -> some View {
        HStack(spacing: 12) {
            Button {
                library.toggleFavorite(song)
            } label: {
                Image(systemName: song.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(song.isFavorite ? .yellow : .white.opacity(0.35))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                statusLabel(for: song)
            }

            Spacer()

            if song.status == .ready {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard song.status == .ready else { return }
            router.push(.playerSetup(song))
        }
    }

    @ViewBuilder
    private func statusLabel(for song: Song) -> some View {
        switch song.status {
        case .ready:
            Text(song.formattedDuration)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        case .importing, .processing:
            Text("채보 생성 중...")
                .font(.caption)
                .foregroundStyle(.cyan.opacity(0.8))
        case .failed:
            Text(song.errorMessage.map { "생성 실패: \($0)" } ?? "생성 실패")
                .font(.caption)
                .foregroundStyle(.red.opacity(0.8))
                .lineLimit(2)
        }
    }

    private func handlePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.pathExtension.lowercased() == "mp3" else {
                errorMessage = "mp3 파일만 등록할 수 있어요."
                return
            }
            importSong(from: url)
        }
    }

    private func importSong(from sourceURL: URL) {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let title = sourceURL.deletingPathExtension().lastPathComponent
        let song: Song
        do {
            song = try library.beginImport(sourceURL: sourceURL, title: title)
        } catch {
            errorMessage = "파일을 불러오지 못했어요: \(error.localizedDescription)"
            return
        }

        isImporting = true
        importProgress = 0
        importStatusText = "시작하는 중..."
        library.updateStatus(song.id, to: .processing)

        // A long song's pipeline can take a minute or more. Two independent protections
        // against it getting silently interrupted mid-way (which is what left a song
        // stuck in "처리 중" forever, or produced an unexplained failure, before this
        // was added): keep the screen from auto-locking while the app is in the
        // foreground, and hold a background-task assertion for the (much less reliable,
        // only ~30s of grace) case the user backgrounds the app anyway.
        UIApplication.shared.isIdleTimerDisabled = true
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ChartGeneration") {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        func endProtections() {
            UIApplication.shared.isIdleTimerDisabled = false
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }

        let localFileURL = library.originalFileURL(for: song)
        let stemsDir = library.stemsDirectory(for: song)
        let chartsDir = library.chartsDirectory(for: song)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try ChartGenerationPipeline.generateChart(mp3URL: localFileURL) { status, fraction in
                    DispatchQueue.main.async {
                        importStatusText = status
                        importProgress = fraction
                    }
                }

                try FileManager.default.createDirectory(at: stemsDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: chartsDir, withIntermediateDirectories: true)

                var available: [Instrument] = []
                for (instrument, audio) in output.stemAudio {
                    let stemURL = stemsDir.appendingPathComponent("\(instrument.rawValue).wav")
                    try AudioFileLoader.writeWav(audio, sampleRate: 44100, to: stemURL)
                }
                for (instrument, notes) in output.charts {
                    let chartURL = chartsDir.appendingPathComponent("\(instrument.rawValue).json")
                    let data = try JSONEncoder().encode(notes)
                    try data.write(to: chartURL, options: .atomic)
                    if !notes.isEmpty { available.append(instrument) }
                }

                DispatchQueue.main.async {
                    library.finalizeImport(song.id, duration: output.duration, availableInstruments: available)
                    isImporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    library.markFailed(song.id)
                    isImporting = false
                    errorMessage = "채보 생성에 실패했어요: \(error.localizedDescription)"
                }
            }
        }
    }
}
