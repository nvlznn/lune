import SwiftUI

/// Lune's mascot: the moon, a perfect white circle with two eyes.
/// Awake, it squashes, stretches and twists; asleep, it breathes slowly.
struct MoonView: View {
    enum Mood {
        /// Tall oval eyes.
        case awake
        /// Eyes closed — writing is closed during the day.
        case asleep
    }

    var mood: Mood = .awake
    /// Moves, with a shadow on the ground. Off for small, still uses like list rows.
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if animated && !reduceMotion {
            switch mood {
            case .awake:
                KeyframeAnimator(initialValue: Pose(), repeating: true, content: figure) { _ in Self.wobble() }
            case .asleep:
                KeyframeAnimator(initialValue: Pose(), repeating: true, content: figure) { _ in Self.breathe() }
            }
        } else {
            figure(Pose())
        }
    }

    private func figure(_ pose: Pose) -> some View {
        VStack(spacing: 0) {
            Canvas { context, size in
                Self.draw(mood, in: context, size: size)
            }
            .aspectRatio(1, contentMode: .fit)
            // Squash and stretch from near the bottom, so it seems to rest on the ground.
            .scaleEffect(x: pose.width, y: pose.height, anchor: UnitPoint(x: 0.5, y: 0.85))
            .rotationEffect(.degrees(pose.angle), anchor: UnitPoint(x: 0.5, y: 0.85))

            if animated {
                GeometryReader { geometry in
                    Ellipse()
                        .fill(Self.shadow)
                        .frame(width: geometry.size.width * 0.55, height: geometry.size.width * 0.05)
                        .scaleEffect(x: pose.shadow)
                        .frame(maxWidth: .infinity)
                }
                .aspectRatio(1 / 0.05, contentMode: .fit)
                .padding(.top, 12)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Motion

    struct Pose {
        var width: CGFloat = 1
        var height: CGFloat = 1
        var angle: Double = 0
        var shadow: CGFloat = 1
    }

    /// 3.2 s: squash and lean left, stretch and lean right, settle.
    @KeyframesBuilder<Pose>
    private static func wobble() -> some Keyframes<Pose> {
        KeyframeTrack(\.width) {
            CubicKeyframe(1.07, duration: 0.8)
            CubicKeyframe(0.95, duration: 0.96)
            CubicKeyframe(1.02, duration: 0.8)
            CubicKeyframe(1, duration: 0.64)
        }
        KeyframeTrack(\.height) {
            CubicKeyframe(0.93, duration: 0.8)
            CubicKeyframe(1.05, duration: 0.96)
            CubicKeyframe(0.98, duration: 0.8)
            CubicKeyframe(1, duration: 0.64)
        }
        KeyframeTrack(\.angle) {
            CubicKeyframe(-5, duration: 0.8)
            CubicKeyframe(4, duration: 0.96)
            CubicKeyframe(-1, duration: 0.8)
            CubicKeyframe(0, duration: 0.64)
        }
        KeyframeTrack(\.shadow) {
            CubicKeyframe(1.12, duration: 0.8)
            CubicKeyframe(0.9, duration: 0.96)
            CubicKeyframe(1, duration: 1.44)
        }
    }

    /// 4.8 s: a slow, slight squash and back.
    @KeyframesBuilder<Pose>
    private static func breathe() -> some Keyframes<Pose> {
        KeyframeTrack(\.width) {
            CubicKeyframe(1.03, duration: 2.4)
            CubicKeyframe(1, duration: 2.4)
        }
        KeyframeTrack(\.height) {
            CubicKeyframe(0.97, duration: 2.4)
            CubicKeyframe(1, duration: 2.4)
        }
        KeyframeTrack(\.shadow) {
            CubicKeyframe(1.04, duration: 2.4)
            CubicKeyframe(1, duration: 2.4)
        }
    }

    // MARK: Drawing

    // Same colours as the app icon.
    static let fill = Color(red: 0.949, green: 0.949, blue: 0.969)    // #F2F2F7
    static let eye = Color(red: 0.110, green: 0.110, blue: 0.118)     // #1C1C1E
    static let shadow = Color(red: 0.173, green: 0.173, blue: 0.180)  // #2C2C2E

    /// Drawn on a 100 × 100 grid, the same one as `design/app-icon/generate.swift`.
    private static func draw(_ mood: Mood, in context: GraphicsContext, size: CGSize) {
        let unit = min(size.width, size.height) / 100
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: x * unit, y: y * unit, width: width * unit, height: height * unit)
        }

        context.fill(Path(ellipseIn: rect(0, 0, 100, 100)), with: .color(fill))

        switch mood {
        case .awake:
            // Tall ovals, 9 × 15, centred at (37, 44) and (63, 44).
            context.fill(Path(ellipseIn: rect(32.5, 36.5, 9, 15)), with: .color(eye))
            context.fill(Path(ellipseIn: rect(58.5, 36.5, 9, 15)), with: .color(eye))
        case .asleep:
            // Closed: gentle downward arcs under the same eyes.
            var lids = Path()
            for center in [CGFloat(37), 63] {
                lids.move(to: CGPoint(x: (center - 6) * unit, y: 46 * unit))
                lids.addQuadCurve(to: CGPoint(x: (center + 6) * unit, y: 46 * unit), control: CGPoint(x: center * unit, y: 52 * unit))
            }
            context.stroke(lids, with: .color(eye), style: StrokeStyle(lineWidth: 3.5 * unit, lineCap: .round))
        }
    }
}

#Preview {
    HStack(spacing: 40) {
        MoonView(mood: .awake).frame(width: 120)
        MoonView(mood: .asleep).frame(width: 120)
        MoonView(mood: .awake, animated: false).frame(width: 40)
    }
    .padding()
    .background(Color.black)
}
