import UIKit

/// A small square pad with a draggable circular knob. Reports its knob
/// position normalized to ±1 on each axis (origin at the box center, +x right,
/// +y down — matches the shader's screen-space `lightDir` convention).
final class LightPanner: UIView {

    var onPositionChanged: ((SIMD2<Float>) -> Void)?
    private let knob = UIView()
    private let knobRadius: CGFloat = 14
    private var didLayoutInitialKnob = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        layer.cornerRadius = 10
        layer.borderColor = UIColor.white.withAlphaComponent(0.30).cgColor
        layer.borderWidth = 1
        layer.cornerCurve = .continuous

        knob.bounds = CGRect(x: 0, y: 0, width: knobRadius * 2, height: knobRadius * 2)
        knob.backgroundColor = .white
        knob.layer.cornerRadius = knobRadius
        knob.isUserInteractionEnabled = false
        addSubview(knob)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handle(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("LightPanner is code-only") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !didLayoutInitialKnob, bounds.width > 0 {
            // Default: upper-left quadrant — matches the shader's default light
            // direction of (-0.7, -0.7).
            let r = knobRadius
            knob.center = CGPoint(x: r + (bounds.width  - 2 * r) * 0.20,
                                  y: r + (bounds.height - 2 * r) * 0.20)
            didLayoutInitialKnob = true
            report()
        }
    }

    @objc private func handle(_ g: UIGestureRecognizer) {
        moveKnob(to: g.location(in: self))
    }

    private func moveKnob(to point: CGPoint) {
        let r = knobRadius
        let x = max(r, min(bounds.width  - r, point.x))
        let y = max(r, min(bounds.height - r, point.y))
        knob.center = CGPoint(x: x, y: y)
        report()
    }

    private func report() {
        let r = knobRadius
        let availW = bounds.width  - 2 * r
        let availH = bounds.height - 2 * r
        guard availW > 0, availH > 0 else { return }
        let nx = Float((knob.center.x - bounds.midX) / (availW * 0.5))
        let ny = Float((knob.center.y - bounds.midY) / (availH * 0.5))
        onPositionChanged?(SIMD2<Float>(nx, ny))
    }
}
