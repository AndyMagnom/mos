import AppKit
import QuartzCore

// The Android/iOS two-cube chase, using native AppKit layers.
@MainActor final class CubeSpinnerView: NSView {
    override var isFlipped: Bool { true }
    private let cubes = [CALayer(), CALayer()]
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 26/255, green: 28/255, blue: 32/255, alpha: 0.8).cgColor
        layer?.cornerRadius = 16
        setAccessibilityElement(true); setAccessibilityLabel("Loading")
        for cube in cubes {
            cube.backgroundColor = NSColor(calibratedRed: 229/255, green: 36/255, blue: 0, alpha: 1).cgColor
            layer?.addSublayer(cube)
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func layout() {
        super.layout()
        let size: CGFloat = 30
        let cubeSize = size * 10 / 52
        let travel = size * 22 / 52
        let origin = CGPoint(x: (bounds.width - travel) / 2, y: (bounds.height - travel) / 2)
        for (index, cube) in cubes.enumerated() {
            cube.bounds = CGRect(x: 0, y: 0, width: cubeSize, height: cubeSize)
            cube.position = index == 0 ? origin : CGPoint(x: origin.x + travel, y: origin.y + travel)
            cube.removeAllAnimations()
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { continue }
            let position = CAKeyframeAnimation(keyPath: "position")
            position.values = [origin, CGPoint(x: origin.x + travel, y: origin.y),
                CGPoint(x: origin.x + travel, y: origin.y + travel), CGPoint(x: origin.x, y: origin.y + travel), origin].map { NSValue(point: $0) }
            let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            rotation.values = [0, -Double.pi / 2, -Double.pi, -3 * Double.pi / 2, -2 * Double.pi]
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [1, 0.5, 1, 0.5, 1]
            for animation in [position, rotation, scale] {
                animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
                animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
            }
            let group = CAAnimationGroup()
            group.animations = [position, rotation, scale]; group.duration = 1.8
            group.repeatCount = .infinity; group.beginTime = CACurrentMediaTime() - Double(index) * 0.9
            cube.add(group, forKey: "chase")
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
}
