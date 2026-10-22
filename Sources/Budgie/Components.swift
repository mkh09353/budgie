import AppKit
import SwiftUI

/// A coloured pill summarising the current state in one word.
struct StatePill: View {
    let state: DictationState

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
        }
        .font(.system(size: 9.5, weight: .bold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    private var text: String {
        switch state {
        case .idle:         return "READY"
        case .recording:    return "LISTENING"
        case .transcribing: return "WORKING"
        case .error:        return "ATTENTION"
        }
    }

    private var color: Color {
        switch state {
        case .idle:         return .green
        case .recording:    return .red
        case .transcribing: return .blue
        case .error:        return .orange
        }
    }
}

/// A keyboard-key styled label.
struct Keycap: View {
    let text: String
    var size: CGFloat = 12

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .frame(minWidth: size + 8)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
    }
}

/// An LED-style microphone level meter.
struct LevelMeter: View {
    let level: Float
    var bars = 24
    var height: CGFloat = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                let threshold = Float(i) / Float(bars)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(threshold < level ? color(threshold)
                                            : Color.secondary.opacity(0.18))
                    .frame(height: height)
            }
        }
    }

    private func color(_ t: Float) -> Color {
        t < 0.6 ? .green : (t < 0.85 ? .yellow : .red)
    }
}

/// Behind-window blur for the floating panel and HUDs. Forced `.active` so
/// it stays frosted even though Budgie is never the active app.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// The small app icon shown next to a saved item's source.
struct AppIconView: View {
    let bundleID: String?
    var size: CGFloat = 13

    var body: some View {
        if let icon = AppIcons.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}

/// Caches app icons by bundle id — looked up for every row on every redraw.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

/// The budgie silhouette as a SwiftUI image, tinted by the caller.
struct BudgieGlyph: View {
    var size: CGFloat = 15

    var body: some View {
        Image(nsImage: MenuBarIcon.budgie(size: NSSize(width: size, height: size)))
            .renderingMode(.template)
    }
}
