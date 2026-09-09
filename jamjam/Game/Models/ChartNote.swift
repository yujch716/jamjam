import Foundation

struct ChartNote: Codable {
    let time: Double
    let type: NoteType
    let duration: Double?
}
