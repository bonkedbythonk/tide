import SwiftUI
import UIKit

/// Tide's look on the TV: the Mac app's blue, its dark aurora behind everything
/// (coloured by the playing song's cover), and frosted panels.
enum Tide {
    static let blue = Color(red: 0.18, green: 0.47, blue: 0.98)
    /// The aurora's colours when nothing is playing.
    static let night: [Color] = [Color(red: 0.10, green: 0.30, blue: 0.85), Color(red: 0.05, green: 0.55, blue: 0.60),
                                 Color(red: 0.42, green: 0.18, blue: 0.70)]
}

/// Deep navy with three soft glows, in the playing cover's colours.
struct AuroraBackground: View {
    let artwork: URL?
    /// A playing video's colours, which take over from the cover's while it shows.
    var live: [Color]?
    @State private var cover = Tide.night
    private var colors: [Color] { live ?? cover }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.06, blue: 0.16), Color(red: 0.02, green: 0.03, blue: 0.07)],
                           startPoint: .top, endPoint: .bottom)
            glow(colors[0], x: 0.18, y: 0.15, size: 1300)
            glow(colors[min(1, colors.count - 1)], x: 0.85, y: 0.35, size: 1200)
            glow(colors[min(2, colors.count - 1)], x: 0.45, y: 0.95, size: 1400)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.8), value: colors)
        .task(id: artwork) {
            guard let artwork else { cover = Tide.night; return }
            guard let (data, _) = try? await URLSession.shared.data(from: artwork),
                  let image = UIImage(data: data)?.cgImage else { return }
            let found = CoverColors.palette(image)
            if !found.isEmpty { cover = found }
        }
    }

    private func glow(_ color: Color, x: CGFloat, y: CGFloat, size: CGFloat) -> some View {
        GeometryReader { geo in
            Circle()
                .fill(color.opacity(0.45))
                .frame(width: size, height: size)
                .blur(radius: 220)
                .position(x: geo.size.width * x, y: geo.size.height * y)
        }
    }
}

/// The Mac app's cover palette (Wallpaper.swift), in UIKit colours.
enum CoverColors {
    /// Up to three main colours: pixels grouped by hue, weighted by how colourful they are.
    static func palette(_ image: CGImage) -> [Color] {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var groups = [(r: Double, g: Double, b: Double, weight: Double)](repeating: (0, 0, 0, 0), count: 12)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            let weight = Double(s * v) + 0.01
            let group = min(11, Int(h * 12))
            groups[group].r += r * weight; groups[group].g += g * weight
            groups[group].b += b * weight; groups[group].weight += weight
        }
        return groups.filter { $0.weight > 0.5 }.sorted { $0.weight > $1.weight }.prefix(3).map { group in
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            UIColor(red: group.r / group.weight, green: group.g / group.weight, blue: group.b / group.weight, alpha: 1)
                .getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            return Color(hue: h, saturation: min(0.85, s * 1.1), brightness: max(0.55, min(0.95, v * 1.2)))
        }
    }
}

/// A frosted panel, like the Mac app's lyrics and song list.
struct Panel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(.ultraThinMaterial.opacity(0.7), in: RoundedRectangle(cornerRadius: 36, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 36, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

// MARK: Focus styles

/// A song row: a soft frosted highlight when focused, like hovering a row on the Mac.
struct RowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration) }

    private struct Look: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(focused ? 0.16 : 0)))
                .scaleEffect(configuration.isPressed ? 0.98 : focused ? 1.03 : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 20, y: 10)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}

/// A cover with its title under it: the cover lifts when focused.
struct CardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration) }

    private struct Look: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 1.02 : focused ? 1.08 : 1)
                .shadow(color: .black.opacity(focused ? 0.5 : 0.2), radius: focused ? 30 : 10, y: focused ? 20 : 6)
                .animation(.easeOut(duration: 0.2), value: focused)
        }
    }
}

/// Tide's pill buttons: blue for the main action, frosted for the rest.
struct PillStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration, prominent: prominent) }

    private struct Look: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(.system(size: 28, weight: .semibold))
                .padding(.horizontal, 34)
                .padding(.vertical, 16)
                .foregroundStyle(focused && !prominent ? .black : .white)
                .background(Capsule().fill(prominent ? Tide.blue : .white.opacity(focused ? 0.95 : 0.12)))
                .overlay(Capsule().strokeBorder(.white.opacity(prominent || focused ? 0 : 0.15)))
                .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.08 : 1)
                .brightness(prominent && focused ? 0.08 : 0)
                .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 18, y: 8)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}

/// Round player controls; the play button is the big white one, like the Mac's.
struct ControlStyle: ButtonStyle {
    var main = false

    func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration, main: main) }

    private struct Look: View {
        let configuration: ButtonStyleConfiguration
        let main: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(.system(size: main ? 40 : 30, weight: .semibold))
                .foregroundStyle(main || focused ? .black : .white)
                .frame(width: main ? 110 : 84, height: main ? 110 : 84)
                .background(Circle().fill(main || focused ? .white : .white.opacity(0.12)))
                .scaleEffect(configuration.isPressed ? 0.94 : focused ? 1.12 : 1)
                .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 18, y: 8)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}
