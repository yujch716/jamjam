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

    /// Extra slack added only to the *safety-net* auto-resolve sweep timers (never to the
    /// actual ms-based judgment math, which is always computed from touch.timestamp). This
    /// absorbs real-device touch-delivery latency so a legitimate touchesEnded/touchesBegan
    /// that's merely a frame or two late isn't preempted by the per-frame sweep declaring
    /// Miss/Bad first.
    private let autoResolveGraceBuffer: TimeInterval = 0.1

    private var judgmentZone: SKShapeNode?

    /// Per-lane "I'm pressing here" feedback, entirely independent of judgment outcome.
    /// Keyed by lane rawValue. A lane can have more than one touch on it at once (up to the
    /// overall 2-touch cap), so visibility is refcounted rather than a plain bool.
    private var laneHighlightNodes: [SKShapeNode] = []
    private var laneHighlightActiveCount: [Int: Int] = [:]
    private var touchLaneHighlight: [ObjectIdentifier: Int] = [:]

    let scoreEngine: ScoreEngine
    weak var gameState: GameState?

    init(size: CGSize, runtimeNotes: [RuntimeNote], gameState: GameState) {
        self.allNotes = runtimeNotes.map { ActiveNote(runtime: $0) }
        let totalUnits = runtimeNotes.reduce(0) { $0 + $1.unitCount }
        self.scoreEngine = ScoreEngine(totalUnits: totalUnits)
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
        setUpJudgmentZone()
        setUpLaneHighlights()
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

    private func setUpJudgmentZone() {
        let zoneHeight = LaneLayout.judgmentZoneHeight
        let zone = SKShapeNode(rectOf: CGSize(width: size.width, height: zoneHeight))
        zone.position = CGPoint(x: size.width / 2, y: LaneLayout.judgmentLineY(sceneHeight: size.height))
        zone.fillColor = SKColor.white.withAlphaComponent(0.10)
        zone.strokeColor = SKColor.white.withAlphaComponent(0.45)
        zone.lineWidth = 1.5
        zone.glowWidth = 4
        zone.zPosition = -1
        addChild(zone)
        judgmentZone = zone

        let centerLine = SKShapeNode(rectOf: CGSize(width: size.width, height: 2))
        centerLine.position = .zero
        centerLine.fillColor = SKColor.white.withAlphaComponent(0.5)
        centerLine.strokeColor = .clear
        centerLine.zPosition = 0.1
        zone.addChild(centerLine)
    }

    private func setUpLaneHighlights() {
        let width = LaneLayout.laneWidth(sceneWidth: size.width)
        let height = LaneLayout.judgmentZoneHeight
        laneHighlightNodes = Lane.allCases.map { lane in
            let node = SKShapeNode(rectOf: CGSize(width: width, height: height))
            node.position = CGPoint(
                x: LaneLayout.laneCenterX(lane: lane, sceneWidth: size.width),
                y: LaneLayout.judgmentLineY(sceneHeight: size.height)
            )
            node.fillColor = lane.uiColor
            node.strokeColor = .clear
            node.alpha = 0
            node.zPosition = -0.7
            node.blendMode = .add
            addChild(node)
            return node
        }
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
        let noteWidth = LaneLayout.noteWidth(sceneWidth: size.width)
        let node = NoteNode(activeNote: note, noteWidth: noteWidth, tailLength: tailLength)
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
            var progress = CGFloat((elapsed - spawnElapsed) / travelDuration)
            if case .holding = note.holdState {
                // Freeze the head at the judgment line while actively held. Without this, a
                // note's head keeps falling at constant speed past the line for the entire
                // hold duration, carrying it (and, at completion, its particle burst) off the
                // bottom of the screen for long holds.
                progress = min(progress, 1.0)
            }
            note.node?.position.y = LaneLayout.noteY(progress: progress, sceneHeight: size.height)
        }
    }

    private func checkForAutoMisses(elapsed: TimeInterval) {
        for note in activeSpawnedNotes {
            switch note.holdState {
            case .pending:
                let deadline = Judgment.windows.last!.1 / 1000 + autoResolveGraceBuffer
                if elapsed - note.startTime > deadline {
                    resolveSingleUnit(note, judgment: .miss)
                }
            case .holding:
                advanceHoldingUnits(note, elapsed: elapsed)
            case .completed:
                break
            }
        }
    }

    /// Progressively scores each middle unit as its time span fully elapses while the note is
    /// still `.holding`. Being `.holding` at that moment already proves the touch was down
    /// continuously through it — any release synchronously transitions the note out of
    /// `.holding` in `releaseTouch` before this could ever see a lapsed unit that wasn't
    /// genuinely held. Deliberately stops one unit short of the last unit: that one is only
    /// judged by an actual release, or by the abandoned-hold timeout below — never by elapsed
    /// time alone.
    private func advanceHoldingUnits(_ note: ActiveNote, elapsed: TimeInterval) {
        while note.nextUnitIndex < note.unitCount - 1, elapsed >= note.unitEndTime(note.nextUnitIndex) {
            recordUnit(.perfect, showPopup: false)
            note.nextUnitIndex += 1
        }

        guard note.nextUnitIndex == note.unitCount - 1, let endTime = note.endTime else { return }
        if elapsed - endTime > Judgment.holdReleaseWindowMs / 1000 + autoResolveGraceBuffer {
            // Held all the way through but no touchesEnded ever arrived: the release unit
            // becomes a late/abandoned finish. The grace buffer gives a genuinely-on-time
            // touchesEnded room to arrive and be honored on its own accurate timestamp before
            // this safety net fires.
            debugLog("auto-resolved abandoned hold's release unit as BAD (note \(note.runtime.id))")
            recordUnit(.bad, showPopup: true)
            finalizeNote(note, lastJudgment: .bad)
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

    // MARK: - Unit scoring primitives

    /// Scores exactly one unit and reflects the running total into the HUD. `showPopup`
    /// controls whether the corner judgment-text popup appears — suppressed for the silent
    /// per-tick "still holding" units so a long hold doesn't spam PERFECT text every 150ms;
    /// the always-visible center combo counter is the intended continuous feedback for that.
    private func recordUnit(_ judgment: Judgment, showPopup: Bool) {
        scoreEngine.record(judgment)
        gameState?.score = scoreEngine.score
        gameState?.combo = scoreEngine.combo
        if showPopup {
            gameState?.lastJudgment = JudgmentPopup(judgment: judgment)
        }
    }

    /// Marks a note fully done — no more units to score — removes it from the active list,
    /// and plays its one-time completion visuals (particle burst + fade-out + zone pulse).
    private func finalizeNote(_ note: ActiveNote, lastJudgment: Judgment) {
        note.isJudged = true
        note.holdState = .completed(finalJudgment: lastJudgment)
        activeSpawnedNotes.removeAll { $0 === note }

        if let node = note.node {
            let burst = JudgmentEffects.particleBurst(color: note.lane.uiColor, at: node.position)
            addChild(burst)
            node.run(.sequence([
                .group([.fadeOut(withDuration: 0.15), .scale(to: 1.3, duration: 0.15)]),
                .removeFromParent()
            ]))
        }
        if let zone = judgmentZone {
            JudgmentEffects.pulse(on: zone)
        }
    }

    /// Convenience for a note with only ever one unit: a tap, or a note auto-missed before
    /// any unit was scored. Scores that single unit and finalizes in the same step.
    private func resolveSingleUnit(_ note: ActiveNote, judgment: Judgment) {
        recordUnit(judgment, showPopup: true)
        finalizeNote(note, lastJudgment: judgment)
    }

    // MARK: - Lane touch highlight (feedback only — never affects judgment/scoring)

    private func setHighlightVisible(lane: Int, visible: Bool) {
        guard laneHighlightNodes.indices.contains(lane) else { return }
        let node = laneHighlightNodes[lane]
        node.removeAllActions()
        node.run(.fadeAlpha(to: visible ? 0.55 : 0.0, duration: visible ? 0.05 : 0.12))
    }

    private func beginLaneHighlight(_ lane: Int, for touch: UITouch) {
        let id = ObjectIdentifier(touch)
        guard touchLaneHighlight[id] == nil else { return }
        touchLaneHighlight[id] = lane
        let count = (laneHighlightActiveCount[lane] ?? 0) + 1
        laneHighlightActiveCount[lane] = count
        if count == 1 { setHighlightVisible(lane: lane, visible: true) }
    }

    private func endLaneHighlight(for touch: UITouch) {
        let id = ObjectIdentifier(touch)
        guard let lane = touchLaneHighlight.removeValue(forKey: id) else { return }
        let count = max((laneHighlightActiveCount[lane] ?? 1) - 1, 0)
        laneHighlightActiveCount[lane] = count
        if count == 0 { setHighlightVisible(lane: lane, visible: false) }
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

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Intentionally does no re-targeting: once a touch is assigned to a note (tracked in
        // `trackedTouches`), it stays assigned regardless of finger drift or which lane the
        // finger is now over — holding validity is purely by touch identity (ObjectIdentifier),
        // never re-checked against the note's current position or the touch's current lane.
        // This override exists (rather than omitting it) so SpriteKit never forwards
        // touchesMoved up the responder chain looking for a handler, which could let a
        // competing gesture recognizer claim/cancel the touch.
        //
        // Debug-only: confirms on-device whether touchesMoved keeps firing for the whole
        // duration of a hold. Remove once hold recognition is confirmed fixed on device.
        for touch in touches {
            debugLog("touchesMoved id=\(ObjectIdentifier(touch)) tracked=\(trackedTouches[ObjectIdentifier(touch)] != nil)")
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            debugLog("touchesEnded id=\(ObjectIdentifier(touch))")
            releaseTouch(touch)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            debugLog("touchesCancelled id=\(ObjectIdentifier(touch))")
            releaseTouch(touch)
        }
    }

    /// The touch hit-test region for a lane: full lane width × a Y-range derived from the
    /// same fall-speed/timing-window constants as the ms judgment math (see
    /// `LaneLayout.hitTestYRange`). Replaces any node-based hit testing (`atPoint`/`nodes(at:)`)
    /// entirely — a touch only needs to land in this rectangle, not on the note's shape itself.
    private func hitTestYRange() -> ClosedRange<CGFloat> {
        LaneLayout.hitTestYRange(
            sceneHeight: size.height,
            travelDuration: travelDuration,
            windowSeconds: Judgment.windows.last!.1 / 1000
        )
    }

    private func handleTouchDown(_ touch: UITouch) {
        guard let startTime = songStartTime else { return }
        let location = touch.location(in: self)

        // Zone-based hit test: lane x-range × judgment hit-test y-range. A touch outside this
        // rectangle isn't an attempt to hit anything, so it doesn't consume a touch slot.
        guard hitTestYRange().contains(location.y) else { return }
        let laneIndex = LaneLayout.laneIndex(forX: location.x, sceneWidth: size.width)

        // Press feedback fires purely from the touch landing in the zone — independent of
        // whether any note actually matches, so it also answers "is my press being heard at
        // all" separately from "is the timing landing on a note."
        beginLaneHighlight(laneIndex, for: touch)

        let elapsed = touch.timestamp - startTime
        debugLog("touchesBegan id=\(ObjectIdentifier(touch)) lane=\(laneIndex) elapsed=\(String(format: "%.3f", elapsed))s")

        let candidates = activeSpawnedNotes.filter { note in
            guard note.lane.rawValue == laneIndex, !note.isJudged else { return false }
            guard case .pending = note.holdState else { return false }
            return abs((note.startTime - elapsed) * 1000) <= Judgment.windows.last!.1
        }
        guard let nearest = candidates.min(by: { abs($0.startTime - elapsed) < abs($1.startTime - elapsed) }) else {
            debugLog("no candidate note in lane \(laneIndex) at elapsed=\(String(format: "%.3f", elapsed))s")
            return
        }

        let id = ObjectIdentifier(touch)
        let offsetMs = (elapsed - nearest.startTime) * 1000
        let startJudgment = judge(offsetMs: offsetMs)

        switch nearest.type {
        case .tap:
            resolveSingleUnit(nearest, judgment: startJudgment)
            // Nothing more to track for this touch — free its slot immediately rather than
            // holding it hostage (against the 2-concurrent-touch cap) for as long as the
            // finger happens to stay down after an already-resolved tap.
        case .hold:
            recordUnit(startJudgment, showPopup: true)
            nearest.nextUnitIndex = 1
            if nearest.nextUnitIndex >= nearest.unitCount {
                // Degenerate case: a hold shorter than one unit (≤ 0.15s) resolves entirely
                // at touch-down, like a tap — there's no separate middle/release unit left.
                finalizeNote(nearest, lastJudgment: startJudgment)
            } else {
                trackedTouches[id] = nearest.runtime.id
                nearest.holdState = .holding(touchId: id)
                nearest.node?.setHeld(true)
                debugLog("hold STARTED note=\(nearest.runtime.id) lane=\(laneIndex) unit0=\(startJudgment.label) totalUnits=\(nearest.unitCount)")
            }
        }
    }

    private func releaseTouch(_ touch: UITouch) {
        let id = ObjectIdentifier(touch)
        defer {
            trackedTouches.removeValue(forKey: id)
            endLaneHighlight(for: touch)
        }

        guard let noteId = trackedTouches[id],
              let note = activeSpawnedNotes.first(where: { $0.runtime.id == noteId }),
              case .holding = note.holdState,
              !note.isJudged else { return }

        note.node?.setHeld(false)

        guard let startTime = songStartTime, let endTime = note.endTime else { return }
        let elapsed = touch.timestamp - startTime

        // touchesCancelled is treated identically to touchesEnded — the outcome is purely a
        // function of when the release happened relative to the hold's end window.
        let heldContinuously = elapsed >= endTime - Judgment.holdReleaseWindowMs / 1000

        if heldContinuously {
            let releaseOffsetMs = (elapsed - endTime) * 1000
            let finalJudgment = resolveHoldReleaseUnit(releaseOffsetMs: releaseOffsetMs)
            debugLog("hold RELEASED note=\(note.runtime.id) releaseOffsetMs=\(String(format: "%.1f", releaseOffsetMs)) -> \(finalJudgment.label)")
            recordUnit(finalJudgment, showPopup: true)
            finalizeNote(note, lastJudgment: finalJudgment)
        } else {
            // Premature release: every not-yet-scored unit from here through the last one
            // becomes its own Miss — not one flat penalty for the whole note — so releasing
            // early on a long hold costs proportionally more than on a short one.
            let missedUnits = note.unitCount - note.nextUnitIndex
            debugLog("hold RELEASED EARLY note=\(note.runtime.id) at unit \(note.nextUnitIndex)/\(note.unitCount) -> \(missedUnits) unit(s) MISS")
            for i in 0..<missedUnits {
                recordUnit(.miss, showPopup: i == missedUnits - 1)
            }
            note.nextUnitIndex = note.unitCount
            finalizeNote(note, lastJudgment: .miss)
        }
    }

    // MARK: - Debug logging (temporary — safe to remove once hold recognition is confirmed fixed)

    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[RhythmScene] \(message())")
        #endif
    }
}
