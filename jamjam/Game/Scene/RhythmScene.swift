import SpriteKit

final class RhythmScene: SKScene {
    private let travelDuration: TimeInterval = 1.2
    private let maxConcurrentTouches = 2

    private var allNotes: [ActiveNote] = []
    private var nextSpawnIndex = 0
    private var activeSpawnedNotes: [ActiveNote] = []
    private var trackedTouches: [ObjectIdentifier: UUID] = [:]

    private var songStartTime: TimeInterval?
    private var hasFinished = false

    private var judgmentLine: SKShapeNode?

    let scoreEngine: ScoreEngine
    weak var gameState: GameState?

    init(size: CGSize, runtimeNotes: [RuntimeNote], gameState: GameState) {
        self.allNotes = runtimeNotes.map { ActiveNote(runtime: $0) }
        self.scoreEngine = ScoreEngine(totalNotes: runtimeNotes.count)
        self.gameState = gameState
        super.init(size: size)
        scaleMode = .resizeFill
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMove(to view: SKView) {
        view.isMultipleTouchEnabled = true
        backgroundColor = SKColor(red: 0.04, green: 0.05, blue: 0.10, alpha: 1.0)
        setUpLanes()
        setUpJudgmentLine()
    }

    private func setUpLanes() {
        for lane in Lane.allCases where lane.rawValue > 0 {
            let x = size.width / CGFloat(Lane.allCases.count) * CGFloat(lane.rawValue)
            let divider = SKShapeNode(rectOf: CGSize(width: 1, height: size.height))
            divider.position = CGPoint(x: x, y: size.height / 2)
            divider.fillColor = SKColor.white.withAlphaComponent(0.08)
            divider.strokeColor = .clear
            divider.zPosition = -2
            addChild(divider)
        }
    }

    private func setUpJudgmentLine() {
        let line = SKShapeNode(rectOf: CGSize(width: size.width, height: 4))
        line.position = CGPoint(x: size.width / 2, y: LaneLayout.judgmentLineY(sceneHeight: size.height))
        line.fillColor = SKColor.white.withAlphaComponent(0.4)
        line.strokeColor = .clear
        line.glowWidth = 6
        line.zPosition = -1
        addChild(line)
        judgmentLine = line
    }

    // MARK: - Update loop

    override func update(_ currentTime: TimeInterval) {
        if songStartTime == nil {
            songStartTime = currentTime
        }
        guard let startTime = songStartTime else { return }
        let elapsed = currentTime - startTime

        spawnDueNotes(elapsed: elapsed)
        positionOnScreenNotes(elapsed: elapsed)
        checkForAutoMisses(elapsed: elapsed)
        checkForChartEnd(elapsed: elapsed)
    }

    private func spawnDueNotes(elapsed: TimeInterval) {
        while nextSpawnIndex < allNotes.count {
            let note = allNotes[nextSpawnIndex]
            guard note.startTime - travelDuration <= elapsed else { break }
            spawn(note)
            nextSpawnIndex += 1
        }
    }

    private func spawn(_ note: ActiveNote) {
        let travelPixels = LaneLayout.spawnY(sceneHeight: size.height) - LaneLayout.judgmentLineY(sceneHeight: size.height)
        let tailLength: CGFloat
        if let duration = note.runtime.chartNote.duration {
            tailLength = CGFloat(duration / travelDuration) * travelPixels
        } else {
            tailLength = 0
        }
        let node = NoteNode(activeNote: note, tailLength: tailLength)
        node.position = CGPoint(
            x: LaneLayout.laneCenterX(lane: note.lane, sceneWidth: size.width),
            y: LaneLayout.spawnY(sceneHeight: size.height)
        )
        addChild(node)
        note.node = node
        activeSpawnedNotes.append(note)
    }

    private func positionOnScreenNotes(elapsed: TimeInterval) {
        for note in activeSpawnedNotes {
            let spawnElapsed = note.startTime - travelDuration
            let progress = CGFloat((elapsed - spawnElapsed) / travelDuration)
            note.node?.position.y = LaneLayout.noteY(progress: progress, sceneHeight: size.height)
        }
    }

    private func checkForAutoMisses(elapsed: TimeInterval) {
        for note in activeSpawnedNotes {
            switch note.holdState {
            case .pending:
                if elapsed - note.startTime > Judgment.windows.last!.1 / 1000 {
                    resolve(note, finalJudgment: .miss)
                }
            case .holding:
                if let endTime = note.endTime, elapsed - endTime > Judgment.holdReleaseWindowMs / 1000 {
                    // Still held past the deadline with no release event: treat as a late/abandoned finish.
                    resolve(note, finalJudgment: .bad)
                }
            case .completed:
                break
            }
        }
    }

    private func checkForChartEnd(elapsed: TimeInterval) {
        guard !hasFinished, !allNotes.isEmpty else { return }
        guard nextSpawnIndex >= allNotes.count, activeSpawnedNotes.isEmpty else { return }
        let lastNote = allNotes[allNotes.count - 1]
        let lastDeadline = (lastNote.endTime ?? lastNote.startTime) + Judgment.holdReleaseWindowMs / 1000 + 0.1
        guard elapsed > lastDeadline else { return }
        hasFinished = true
        gameState?.result = scoreEngine.result
    }

    // MARK: - Resolution

    private func resolve(_ note: ActiveNote, finalJudgment: Judgment) {
        guard !note.isJudged else { return }
        note.isJudged = true
        note.holdState = .completed(finalJudgment: finalJudgment)
        activeSpawnedNotes.removeAll { $0 === note }

        scoreEngine.record(finalJudgment)

        if let node = note.node {
            let burst = JudgmentEffects.particleBurst(color: note.lane.uiColor, at: node.position)
            addChild(burst)
            node.run(.sequence([
                .group([.fadeOut(withDuration: 0.15), .scale(to: 1.3, duration: 0.15)]),
                .removeFromParent()
            ]))
        }
        if let line = judgmentLine {
            JudgmentEffects.pulse(on: line)
        }

        gameState?.score = scoreEngine.score
        gameState?.combo = scoreEngine.combo
        gameState?.lastJudgment = JudgmentPopup(judgment: finalJudgment)
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if trackedTouches.count >= maxConcurrentTouches { break }
            let id = ObjectIdentifier(touch)
            guard trackedTouches[id] == nil else { continue }
            handleTouchDown(touch)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { releaseTouch(touch) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { releaseTouch(touch) }
    }

    private func handleTouchDown(_ touch: UITouch) {
        guard let startTime = songStartTime else { return }
        let location = touch.location(in: self)
        let laneIndex = LaneLayout.laneIndex(forX: location.x, sceneWidth: size.width)
        let elapsed = touch.timestamp - startTime

        let candidates = activeSpawnedNotes.filter { note in
            note.lane.rawValue == laneIndex &&
            !note.isJudged &&
            abs((note.startTime - elapsed) * 1000) <= Judgment.windows.last!.1
        }
        guard let nearest = candidates.min(by: { abs($0.startTime - elapsed) < abs($1.startTime - elapsed) }) else {
            return
        }

        let id = ObjectIdentifier(touch)
        trackedTouches[id] = nearest.runtime.id

        let offsetMs = (elapsed - nearest.startTime) * 1000
        let startJudgment = judge(offsetMs: offsetMs)

        switch nearest.type {
        case .tap:
            resolve(nearest, finalJudgment: startJudgment)
        case .hold:
            nearest.holdState = .holding(touchId: id, startJudgment: startJudgment)
            nearest.node?.setHeld(true)
        }
    }

    private func releaseTouch(_ touch: UITouch) {
        let id = ObjectIdentifier(touch)
        defer { trackedTouches.removeValue(forKey: id) }

        guard let noteId = trackedTouches[id],
              let note = activeSpawnedNotes.first(where: { $0.runtime.id == noteId }),
              case .holding(_, let startJudgment) = note.holdState,
              !note.isJudged else { return }

        note.node?.setHeld(false)

        guard let startTime = songStartTime, let endTime = note.endTime else { return }
        let elapsed = touch.timestamp - startTime
        let releaseOffsetMs = (elapsed - endTime) * 1000

        // touchesCancelled is treated identically to touchesEnded — the outcome is purely
        // a function of when the release happened relative to the hold's end window.
        let heldContinuously = elapsed >= endTime - Judgment.holdReleaseWindowMs / 1000
        let finalJudgment = resolveHoldOutcome(
            startJudgment: startJudgment,
            heldContinuously: heldContinuously,
            releaseOffsetMs: heldContinuously ? releaseOffsetMs : nil
        )
        resolve(note, finalJudgment: finalJudgment)
    }
}
