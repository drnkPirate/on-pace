// Run from the project root with:
// swiftc UsageNotch/TrailGeometry.swift Scripts/RenderAppIcon.swift -o /tmp/on-pace-icon && /tmp/on-pace-icon
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum RenderAppIcon {
    static func main() throws {
        let output = URL(fileURLWithPath: "UsageNotch/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: rgb, components: [red / 255, green / 255, blue / 255, alpha])!
        }

        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: rgb,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let size = CGFloat(pixels)
            let tile = CGRect(x: size * 100 / 1024, y: size * 100 / 1024,
                              width: size * 824 / 1024, height: size * 824 / 1024)
            let corner = size * 185 / 1024
            let silhouette = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)
            context.saveGState()
            context.addPath(silhouette)
            context.clip()
            let gradient = CGGradient(colorsSpace: rgb, colors: [color(42, 51, 45), color(12, 15, 13)] as CFArray,
                                      locations: [0, 1])!
            // CSS-style 160 degrees, clockwise from the top of the tile.
            let angle = CGFloat(160) * .pi / 180
            let dx = sin(angle)
            let dy = cos(angle)
            let extent = tile.width / 2 * (abs(dx) + abs(dy))
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: tile.midX - dx * extent, y: tile.midY - dy * extent),
                                       end: CGPoint(x: tile.midX + dx * extent, y: tile.midY + dy * extent),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

            // Clipping keeps one scaled design pixel of the stroke inside the tile.
            context.addPath(silhouette)
            context.setLineWidth(2 * size / 1024)
            context.setStrokeColor(color(255, 255, 255, alpha: 0.10))
            context.strokePath()
            context.restoreGState()

            let dots = pixels <= 32 ? TrailGeometry.small : TrailGeometry.full
            for (index, dot) in dots.enumerated() {
                let lime = TrailGeometry.lime
                let stop = index == dots.count - 1
                context.setFillColor(stop ? color(lime.red * 255, lime.green * 255, lime.blue * 255)
                                          : color(255, 255, 255, alpha: dot.opacity))
                let bounds = dot.bounds(in: tile.width).offsetBy(dx: tile.minX, dy: tile.minY)
                context.fillEllipse(in: bounds)
            }

            let file = output.appendingPathComponent("UsageNotch-\(pixels).png")
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
