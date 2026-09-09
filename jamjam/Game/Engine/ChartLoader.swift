import Foundation

enum ChartLoaderError: Error {
    case resourceNotFound
}

enum ChartLoader {
    /// Decodes a chart JSON matching the exact `{time, type, duration?}` schema, sorts by
    /// time, and assigns each note a lane deterministically (index % lane count). Lane
    /// assignment is never written back into the JSON — the schema stays compliant for
    /// future AI-generated charts, which will need their own lane-assignment design.
    static func loadRuntimeNotes(from data: Data, laneCount: Int = Lane.allCases.count) throws -> [RuntimeNote] {
        let notes = try JSONDecoder().decode([ChartNote].self, from: data)
        let sorted = notes.sorted { $0.time < $1.time }
        return sorted.enumerated().map { index, note in
            let lane = Lane(rawValue: index % laneCount) ?? .guitar
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
}
