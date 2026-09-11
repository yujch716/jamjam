import Foundation

enum ChartLoaderError: Error {
    case resourceNotFound
}

enum ChartLoader {
    /// Decodes a chart JSON matching the `{time, type, duration?, lane?}` schema, sorts by
    /// time, and resolves each note's `Lane` from its `lane` field (assigned once at
    /// generation time by `LaneAssigner`). Falls back to index % lane count only for charts
    /// predating lane assignment (the legacy `dummy_chart.json`).
    static func loadRuntimeNotes(from data: Data, laneCount: Int = Lane.allCases.count) throws -> [RuntimeNote] {
        let notes = try JSONDecoder().decode([ChartNote].self, from: data)
        let sorted = notes.sorted { $0.time < $1.time }
        return sorted.enumerated().map { index, note in
            let laneIndex = note.lane ?? (index % laneCount)
            let lane = Lane(rawValue: laneIndex) ?? .lane0
            return RuntimeNote(id: UUID(), chartNote: note, lane: lane)
        }
    }

    static func loadDummyChart() throws -> [RuntimeNote] {
        guard let url = Bundle.main.url(forResource: "dummy_chart", withExtension: "json") else {
            throw ChartLoaderError.resourceNotFound
        }
        let data = try Data(contentsOf: url)
        return try loadRuntimeNotes(from: data)
    }

    /// Loads an AI-generated chart previously written by `ChartGenerationPipeline` +
    /// `SongLibraryStore` for a specific song/instrument.
    static func loadRuntimeNotes(fromFileURL url: URL, laneCount: Int = Lane.allCases.count) throws -> [RuntimeNote] {
        let data = try Data(contentsOf: url)
        return try loadRuntimeNotes(from: data, laneCount: laneCount)
    }
}
