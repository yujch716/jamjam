import CoreGraphics

/// Pure geometry helpers for placing lanes/notes within the scene — no SpriteKit types,
/// just CGFloat math, so it's trivial to reason about and adjust independently of the scene.
enum LaneLayout {
    static let judgmentLineYRatio: CGFloat = 0.18
    static let spawnYRatio: CGFloat = 0.98
    static let noteRadius: CGFloat = 26

    static func laneCount() -> Int { Lane.allCases.count }

    static func laneCenterX(lane: Lane, sceneWidth: CGFloat) -> CGFloat {
        let laneWidth = sceneWidth / CGFloat(laneCount())
        return laneWidth * (CGFloat(lane.rawValue) + 0.5)
    }

    static func laneIndex(forX x: CGFloat, sceneWidth: CGFloat) -> Int {
        let laneWidth = sceneWidth / CGFloat(laneCount())
        guard laneWidth > 0 else { return 0 }
        let raw = Int(x / laneWidth)
        return min(max(raw, 0), laneCount() - 1)
    }

    static func judgmentLineY(sceneHeight: CGFloat) -> CGFloat {
        sceneHeight * judgmentLineYRatio
    }

    static func spawnY(sceneHeight: CGFloat) -> CGFloat {
        sceneHeight * spawnYRatio
    }

    /// Linear interpolation of a note's y position given progress in [0, 1] from spawn to judgment line.
    static func noteY(progress: CGFloat, sceneHeight: CGFloat) -> CGFloat {
        let start = spawnY(sceneHeight: sceneHeight)
        let end = judgmentLineY(sceneHeight: sceneHeight)
        return start + (end - start) * progress
    }
}
