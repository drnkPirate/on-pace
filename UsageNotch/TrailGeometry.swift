import CoreGraphics

enum TrailGeometry {
    struct Dot {
        let x: CGFloat
        let radius: CGFloat
        let opacity: CGFloat

        func bounds(in size: CGFloat) -> CGRect {
            CGRect(x: (x - radius) * size / 100, y: (50 - radius) * size / 100,
                   width: 2 * radius * size / 100, height: 2 * radius * size / 100)
        }
    }

    static let lime: (red: CGFloat, green: CGFloat, blue: CGFloat) = (215 / 255, 250 / 255, 129 / 255)
    static let full = [
        Dot(x: 20.5, radius: 3, opacity: 0.25),
        Dot(x: 33, radius: 4.5, opacity: 0.45),
        Dot(x: 49, radius: 6.5, opacity: 0.70),
        Dot(x: 71.5, radius: 11, opacity: 1)
    ]
    static let small = [
        Dot(x: 24, radius: 5, opacity: 0.40),
        Dot(x: 42.5, radius: 7.5, opacity: 0.75),
        Dot(x: 69, radius: 13, opacity: 1)
    ]
}
