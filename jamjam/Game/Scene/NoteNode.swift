import SpriteKit

/// Visual representation of one falling note. For hold notes, a tail extends upward
/// (toward less-elapsed time) from the head by a fixed length in points, computed once at
/// spawn time from the note's duration and the scene's fall speed — since head and tail-end
/// travel at the same constant speed, that length never needs to be recomputed per frame.
final class NoteNode: SKNode {
    let activeNote: ActiveNote
    private let headGlow: SKShapeNode
    private let head: SKShapeNode
    private var tail: SKShapeNode?

    init(activeNote: ActiveNote, noteWidth: CGFloat, tailLength: CGFloat) {
        self.activeNote = activeNote
        let color = activeNote.lane.uiColor

        // Pill/stadium shape: corner radius = height / 2 fully rounds the short ends.
        let height = LaneLayout.noteHeight
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

        super.init()

        addChild(headGlow)
        addChild(head)

        if activeNote.type == .hold, tailLength > 0 {
            let tailWidth = noteWidth * 0.62
            let tailShape = SKShapeNode(rectOf: CGSize(width: tailWidth, height: tailLength), cornerRadius: tailWidth / 2)
            tailShape.fillColor = color.withAlphaComponent(0.5)
            tailShape.strokeColor = .clear
            tailShape.position = CGPoint(x: 0, y: tailLength / 2)
            tailShape.zPosition = -0.5
            addChild(tailShape)
            tail = tailShape
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Dims the note while a hold is being actively tracked, as light feedback that contact registered.
    func setHeld(_ held: Bool) {
        head.alpha = held ? 0.6 : 1.0
    }
}
