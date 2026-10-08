import SwiftUI

/// Lune's mascot: a little pixel ghost, drawn from a pixel map so it stays crisp at any size.
struct GhostView: View {
    enum Mood {
        /// Eyes open.
        case awake
        /// Eyes closed — the diary is closed during the day.
        case asleep
    }

    var mood: Mood = .awake
    /// Gently bobs up and down, with its shadow shrinking as it rises.
    var floating = true

    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Canvas { context, size in
                Self.draw(Self.pixels(mood), in: context, size: size)
            }
            .aspectRatio(CGFloat(Self.width) / CGFloat(Self.height), contentMode: .fit)
            .offset(y: up ? -6 : 0)

            Capsule()
                .fill(Self.outline.opacity(0.55))
                .frame(height: 6)
                .scaleEffect(x: up ? 0.45 : 0.6)
                .padding(.top, 10)
        }
        .onAppear {
            guard floating, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { up = true }
        }
        .accessibilityHidden(true)
    }

    // MARK: Pixel map

    static let width = 16
    static let height = 14

    // O outline · W body · L shade · E eye · space empty
    private static let body: [String] = [
        "    OOOOOOOO    ",
        "  OOWWWWWWWWOO  ",
        " OWWWWWWWWWWWWO ",
        " OWWWWWWWWWWWWO ",
        "OWWWWWWWWWWWWWWO",
        "OWWWWWWWWWWWWWWO",
        "OWWWWWWWWWWWWWWO",
        "OWWWWWWWWWWWWWWO",
        "OWWWWWWWWWWWWWWO",
        "OLWWWWWWWWWWWWLO",
        "OLLWWWWWWWWWWLLO",
        "OLLLLLLLLLLLLLLO",
        "OLLLLOLLLLOLLLLO",
        " OOOO OOOO OOOO ",
    ]

    /// The body with eyes for a mood.
    static func pixels(_ mood: Mood) -> [[Character]] {
        var grid = body.map(Array.init)
        switch mood {
        case .awake:
            for row in 5...6 {
                grid[row][5] = "E"
                grid[row][10] = "E"
            }
        case .asleep:
            for column in [4, 5, 10, 11] {
                grid[6][column] = "E"
            }
        }
        return grid
    }

    // Same colours as the app icon: dark-gray outline and shading, near-black eyes.
    static let outline = Color(red: 0.227, green: 0.227, blue: 0.235)   // #3A3A3C
    static let eye = Color(red: 0.110, green: 0.110, blue: 0.118)       // #1C1C1E
    static let fill = Color(red: 0.949, green: 0.949, blue: 0.969)      // #F2F2F7
    static let shade = Color(red: 0.388, green: 0.388, blue: 0.400)     // #636366

    private static func draw(_ grid: [[Character]], in context: GraphicsContext, size: CGSize) {
        let cell = min(size.width / CGFloat(width), size.height / CGFloat(height))
        for (y, row) in grid.enumerated() {
            for (x, pixel) in row.enumerated() {
                let color: Color
                switch pixel {
                case "O": color = outline
                case "E": color = eye
                case "W": color = fill
                case "L": color = shade
                default: continue
                }
                // Slight overlap avoids hairline gaps between cells.
                let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell + 0.5, height: cell + 0.5)
                context.fill(Path(rect), with: .color(color))
            }
        }
    }
}

#Preview {
    HStack(spacing: 40) {
        GhostView(mood: .awake).frame(width: 120)
        GhostView(mood: .asleep).frame(width: 120)
    }
    .padding()
    .background(Color.black)
}
