import AppKit
import SwiftUI
import HooverCore

@MainActor
final class FileIconCache {
    static let shared = FileIconCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() { cache.countLimit = 384 }

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let icon = cache.object(forKey: key) { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

@MainActor
struct GlassSurface: ViewModifier {
    @ObservedObject var settings: HooverSettings
    @Environment(\.colorScheme) private var scheme
    var active = false
    var radius: CGFloat = 16

    private var glow: Double {
        switch settings.glow {
        case "Low": return 0.10
        case "High": return 0.38
        default: return 0.22
        }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background { surface(shape) }
            .background(shape.fill((scheme == .dark ? Color(red: 0.055, green: 0.072, blue: 0.13) : Color.white).opacity(0.36)))
            .overlay {
                shape.fill(LinearGradient(
                    colors: [Color.white.opacity(settings.liquidGlass ? 0.12 : 0.035), Color.clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )).allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(active ? settings.accentColor.opacity(0.95) : Color.primary.opacity(scheme == .dark ? 0.16 : 0.09), lineWidth: active ? 1.7 : 0.7)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.23 : 0.11), radius: 11, y: 6)
            .shadow(color: active ? settings.accentColor.opacity(glow) : .clear, radius: 14)
    }

    @ViewBuilder
    private func surface(_ shape: RoundedRectangle) -> some View {
        // Xcode 26 supplies Liquid Glass; older SDKs retain the same readable material surface.
        #if compiler(>=6.2)
        if settings.liquidGlass {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        } else {
            shape.fill(.ultraThinMaterial)
        }
        #else
        shape.fill(.ultraThinMaterial)
        #endif
    }
}

extension View {
    @MainActor
    func hooverGlass(_ settings: HooverSettings, active: Bool = false, radius: CGFloat = 16) -> some View {
        modifier(GlassSurface(settings: settings, active: active, radius: radius))
    }
}

@MainActor
struct FileGlyph: View {
    let node: FileNode
    let size: CGFloat

    var body: some View {
        Image(nsImage: FileIconCache.shared.icon(for: node.url))
            .resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            .overlay(alignment: .bottomLeading) {
                if node.isSymbolicLink {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .padding(2).background(.regularMaterial, in: Circle())
                }
            }
            .accessibilityHidden(true)
    }
}

struct HighlightedName: View {
    let name: String
    let query: String
    let accent: Color
    let enabled: Bool

    private var highlighted: Text {
        guard enabled, !query.isEmpty,
              let range = name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(name)
        }
        return Text(String(name[..<range.lowerBound]))
            + Text(String(name[range])).foregroundColor(accent).bold()
            + Text(String(name[range.upperBound...]))
    }

    var body: some View { highlighted.lineLimit(1).truncationMode(.middle) }
}

struct ShortcutHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            Text(key).font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct SyntaxSnippet: View {
    let text: String
    let accent: Color
    var maximumLines = 10

    private var lines: [String] { Array(text.components(separatedBy: .newlines).prefix(maximumLines)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(index + 1)).foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                    styled(line).lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    private func styled(_ line: String) -> Text {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") || line.trimmingCharacters(in: .whitespaces).hasPrefix("# ") {
            return Text(line).foregroundColor(.secondary)
        }
        let pattern = #"\"(?:[^\"\\]|\\.)*\"|\b(?:import|class|struct|enum|func|let|var|private|public|internal|final|return|if|else|guard|for|while|switch|case|async|await|throws|throw|try|def|function|const|export|from|true|false|null|nil)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return Text(line) }
        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        var result = Text("")
        var start = 0
        for match in matches {
            result = result + Text(nsLine.substring(with: NSRange(location: start, length: match.range.location - start)))
            let token = nsLine.substring(with: match.range)
            result = result + Text(token).foregroundColor(token.hasPrefix("\"") ? .mint : accent)
            start = match.range.location + match.range.length
        }
        return result + Text(nsLine.substring(from: start))
    }
}

struct NodeFramePreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, last in last })
    }
}

struct InteractionPreference: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    func interactionRegion(in coordinateSpace: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: InteractionPreference.self, value: [geometry.frame(in: .named(coordinateSpace))])
            }
        }
    }
}
