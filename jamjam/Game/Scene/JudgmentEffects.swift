import SpriteKit

/// Programmatic particle burst on judgment, plus a brief pulse on the judgment line. No
/// .sks files — everything's generated in code.
enum JudgmentEffects {
    /// A small soft-circle texture generated procedurally so the particle burst doesn't
    /// depend on a bundled image asset.
    private static let sparkTexture: SKTexture = {
        let size = CGSize(width: 16, height: 16)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
                endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: rect.width / 2,
                options: []
            )
        }
        return SKTexture(image: image)
    }()

    /// `comboIntensity` (0...1, see `ComboIntensity`) modestly scales particle count/speed —
    /// deliberately a small bump (max +8 particles), not a multiplier, so a 4-player screen
    /// with all four windows simultaneously at max combo never spawns enough particles at
    /// once to risk a frame drop.
    static func particleBurst(color: UIColor, at position: CGPoint, comboIntensity: Double = 0) -> SKEmitterNode {
        let emitter = SKEmitterNode()
        emitter.position = position
        emitter.particleColor = color
        emitter.particleColorBlendFactor = 1.0
        emitter.particleBirthRate = 400
        emitter.numParticlesToEmit = 14 + Int(8 * comboIntensity)
        emitter.particleLifetime = 0.35
        emitter.particleSpeed = 90 + 30 * CGFloat(comboIntensity)
        emitter.particleSpeedRange = 50
        emitter.particleAlpha = 0.9
        emitter.particleAlphaSpeed = -2.4
        emitter.particleScale = 0.18
        emitter.particleScaleRange = 0.08
        emitter.particleScaleSpeed = -0.3
        emitter.emissionAngleRange = .pi * 2
        emitter.particleTexture = sparkTexture
        emitter.run(.sequence([.wait(forDuration: 0.5), .removeFromParent()]))
        return emitter
    }

    static func pulse(on node: SKShapeNode) {
        let scaleUp = SKAction.scale(to: 1.15, duration: 0.08)
        let scaleDown = SKAction.scale(to: 1.0, duration: 0.12)
        node.run(.sequence([scaleUp, scaleDown]))
    }
}
