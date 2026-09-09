import Foundation
import CoreGraphics

/// Pure geometry helpers for placing lanes/notes within the scene — no SpriteKit types,
/// just CGFloat math, so it's trivial to reason about and adjust independently of the scene.
enum LaneLayout {
    static let judgmentLineYRatio: CGFloat = 0.10
    static let spawnYRatio: CGFloat = 0.98

    /// Note visuals are a thick pill (rounded rect), not a circle — width is a fraction of
    /// the lane's width (leaving a gap to the lane dividers), height and the judgment zone
    /// band are fractions of scene height, and corner radius is half the height so the ends
    /// are fully round (stadium shape). Everything is ratio-based (never a fixed point value)
    /// so a quarter-screen 4-player window scales down proportionally instead of the same
    /// absolute sizes looking oversized/overlapping in a much smaller window.
    static let noteWidthRatio: CGFloat = 0.72
    static let noteHeightRatio: CGFloat = 0.029

    /// Judgment zone: a band straddling the judgment line, taller than a single note, that
    /// acts as the visible "hit zone" guide (the touch hit-test region itself is separately
    /// derived from timing, see `hitTestYRange`, and is intentionally larger than this).
    static let judgmentZoneHeightRatio: CGFloat = 0.054

    static func noteHeight(sceneHeight: CGFloat) -> CGFloat {
        sceneHeight * noteHeightRatio
    }

    static func judgmentZoneHeight(sceneHeight: CGFloat) -> CGFloat {
        sceneHeight * judgmentZoneHeightRatio
    }

    static func laneCount() -> Int { Lane.allCases.count }

    static func laneWidth(sceneWidth: CGFloat) -> CGFloat {
        sceneWidth / CGFloat(laneCount())
    }

    static func noteWidth(sceneWidth: CGFloat) -> CGFloat {
        laneWidth(sceneWidth: sceneWidth) * noteWidthRatio
    }

    static func laneCenterX(lane: Lane, sceneWidth: CGFloat) -> CGFloat {
        laneWidth(sceneWidth: sceneWidth) * (CGFloat(lane.rawValue) + 0.5)
    }

    static func laneXRange(lane: Lane, sceneWidth: CGFloat) -> ClosedRange<CGFloat> {
        let width = laneWidth(sceneWidth: sceneWidth)
        let start = width * CGFloat(lane.rawValue)
        return start...(start + width)
    }

    static func laneIndex(forX x: CGFloat, sceneWidth: CGFloat) -> Int {
        let width = laneWidth(sceneWidth: sceneWidth)
        guard width > 0 else { return 0 }
        let raw = Int(x / width)
        return min(max(raw, 0), laneCount() - 1)
    }

    static func judgmentLineY(sceneHeight: CGFloat) -> CGFloat {
        sceneHeight * judgmentLineYRatio
    }

    static func spawnY(sceneHeight: CGFloat) -> CGFloat {
        sceneHeight * spawnYRatio
    }

    /// The touch hit-test region's vertical span, centered on the judgment line and derived
    /// from the exact same timing constants (fall speed + timing window) as the ms-based
    /// judgment math — so a touch is spatially inside this range if and only if some note
    /// would also be time-valid there. This keeps the zone-based hit test purely a geometric
    /// restatement of the existing timing windows rather than an independent, narrower cutoff
    /// (it's intentionally taller than the visible `judgmentZoneHeight` band, which is just a
    /// compact aiming guide drawn on screen).
    static func hitTestYRange(sceneHeight: CGFloat, travelDuration: TimeInterval, windowSeconds: TimeInterval) -> ClosedRange<CGFloat> {
        let travelPixels = spawnY(sceneHeight: sceneHeight) - judgmentLineY(sceneHeight: sceneHeight)
        let halfSpan = CGFloat(windowSeconds / travelDuration) * travelPixels
        let center = judgmentLineY(sceneHeight: sceneHeight)
        return (center - halfSpan)...(center + halfSpan)
    }

    /// Linear interpolation of a note's y position given progress in [0, 1] from spawn to judgment line.
    static func noteY(progress: CGFloat, sceneHeight: CGFloat) -> CGFloat {
        let start = spawnY(sceneHeight: sceneHeight)
        let end = judgmentLineY(sceneHeight: sceneHeight)
        return start + (end - start) * progress
    }
}
