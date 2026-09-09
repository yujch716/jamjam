import SpriteKit

/// Visual representation of one falling note. For hold notes, a tail extends upward
/// (toward less-elapsed time) from the head by a length in points computed from the note's
/// duration and the scene's fall speed. While the note is actively held, the scene calls
/// `updateTailRemaining(_:)` every frame to shrink that tail down toward the head as the
/// remaining hold time runs out — the tail's current length is the player's only visual cue
/// for how much longer to keep holding.
final class NoteNode: SKNode {
    let activeNote: ActiveNote
    private let headGlow: SKShapeNode
    private let head: SKShapeNode
    private var tail: SKShapeNode?
    private let tailWidth: CGFloat

    init(activeNote: ActiveNote, noteWidth: CGFloat, noteHeight: CGFloat, tailLength: CGFloat) {
        self.activeNote = activeNote
        let color = activeNote.lane.uiColor

        // Pill/stadium shape: corner radius = height / 2 fully rounds the short ends.
        let height = noteHeight
        let cornerRadius = height / 2

        head = SKShapeNode(rectOf: CGSize(width: noteWidth, height: height), cornerRadius: cornerRadius)
        head.fillColor = color
        head.strokeColor = .white
        head.lineWidth = 2
        head.glowWidth = 4

        let glowSize = CGSize(width: noteWidth * 1.12, height: height * 1.55)
        headGlow = SKShapeNode(rectOf: glowSize, cornerRadius: glowSize.height / 2)
        headGlow.fillColor = color.withAlphaComponent(0.35)
        headGlow.strokeColor = .clear
        headGlow.zPosition = -1

        tailWidth = noteWidth * 0.62

        super.init()

        addChild(headGlow)
        addChild(head)

        if activeNote.type == .hold, tailLength > 0 {
            let tailShape = SKShapeNode()
            tailShape.fillColor = color.withAlphaComponent(0.5)
            tailShape.strokeColor = .clear
            tailShape.zPosition = -0.5
            addChild(tailShape)
            tail = tailShape
            setTailPath(tailShape, length: tailLength)
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Dims the note while a hold is being actively tracked, as light feedback that contact registered.
    func setHeld(_ held: Bool) {
        head.alpha = held ? 0.6 : 1.0
    }

    /// Shrinks the tail to `length` points, keeping its near end anchored at the head (y=0)
    /// and its far end receding downward — i.e. the tail always represents exactly how much
    /// hold time is left, in the same points-per-second the note originally fell at.
    func updateTailRemaining(_ length: CGFloat) {
        guard let tail else { return }
        if length <= 0.5 {
            tail.isHidden = true
            return
        }
        tail.isHidden = false
        setTailPath(tail, length: length)
    }

    private func setTailPath(_ tail: SKShapeNode, length: CGFloat) {
        let rect = CGRect(x: -tailWidth / 2, y: 0, width: tailWidth, height: length)
        tail.path = CGPath(roundedRect: rect, cornerWidth: tailWidth / 2, cornerHeight: tailWidth / 2, transform: nil)
    }
}
