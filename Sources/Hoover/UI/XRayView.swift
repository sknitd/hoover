import AppKit
import SwiftUI
import HooverCore

@MainActor
struct XRayView: View {
    @ObservedObject private var state: AppState
    @ObservedObject private var settings: HooverSettings
    private let rootAnchor: CGPoint?
    private let onInteractionRegions: ([CGRect]) -> Void
    @State private var nodeFrames: [String: CGRect] = [:]

    init(state: AppState, rootAnchor: CGPoint? = nil, onInteractionRegions: @escaping ([CGRect]) -> Void = { _ in }) {
        self.state = state
        self.settings = state.settings
        self.rootAnchor = rootAnchor
        self.onInteractionRegions = onInteractionRegions
    }

    var body: some View {
        GeometryReader { geometry in
            let anchor = rootAnchor ?? CGPoint(x: 24, y: geometry.size.height * 0.42)
            let leading = min(max(anchor.x + 70, 24), max(24, geometry.size.width - 342))
            let top = min(max(anchor.y - 132, 104), max(104, geometry.size.height - 440))
            ZStack(alignment: .topLeading) {
                if settings.showConnectors {
                    ConnectorCanvas(columns: state.columns, frames: nodeFrames, rootAnchor: anchor,
                                    activePath: state.selectedPath, focus: state.focusedNode?.id,
                                    accent: settings.accentColor, searching: state.isSearchActive && !state.query.isEmpty)
                        .allowsHitTesting(false)
                }
                canvas(leading: leading, top: top, height: max(180, geometry.size.height - top - 88))
                if state.isSearchActive {
                    ScopedSearchBar(state: state, settings: settings)
                        .frame(width: min(530, max(300, geometry.size.width - 48)))
                        .interactionRegion(in: "XRaySpace")
                        .position(x: min(max(leading + 218, 290), geometry.size.width - 290), y: max(38, top - 45))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                VStack(alignment: .trailing, spacing: 10) {
                    if state.isIndexing && state.isSearchActive {
                        Label("Indexing deeper folders…", systemImage: "circle.dotted")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .hooverGlass(settings, radius: 12)
                    }
                    if let message = state.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).lineLimit(3)
                            .frame(maxWidth: 370, alignment: .leading)
                            .padding(12).hooverGlass(settings, radius: 12)
                            .interactionRegion(in: "XRaySpace")
                    }
                    controlPill
                }
                .padding(.trailing, 24).padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .coordinateSpace(name: "XRaySpace")
            .onPreferenceChange(NodeFramePreference.self) { nodeFrames = $0 }
            .onPreferenceChange(InteractionPreference.self, perform: onInteractionRegions)
        }
        .preferredColorScheme(settings.preferredColorScheme)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: state.columns.map(\.id))
        .animation(.easeOut(duration: 0.20), value: state.isSearchActive)
        .accessibilityLabel("Hoover Folder X-Ray")
    }

    private func canvas(leading: CGFloat, top: CGFloat, height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .top, spacing: 48) {
                    if state.isSearchActive && !state.query.isEmpty && state.columns.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Label("No matches", systemImage: "magnifyingglass").font(.system(size: 12, weight: .medium))
                            Text("Try another name or extension inside this folder.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(18).frame(width: 260, alignment: .leading)
                        .hooverGlass(settings).interactionRegion(in: "XRaySpace")
                    }
                    ForEach(state.columns) { column in
                        TreeColumnView(state: state, settings: settings, column: column, availableHeight: height)
                            .frame(width: settings.cardDensity == "Compact" ? 276 : 300)
                            .id(column.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                    }
                }
                .padding(.leading, leading).padding(.trailing, 72).padding(.top, top).padding(.bottom, 76)
                .frame(minHeight: height + top + 76, alignment: .top)
            }
            .onChange(of: state.columns.map(\.id)) { ids in
                guard settings.autoScroll, let last = ids.last else { return }
                withAnimation(.spring(response: 0.40, dampingFraction: 0.9)) { proxy.scrollTo(last, anchor: .trailing) }
            }
        }
    }

    private var controlPill: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(settings.accentColor).frame(width: 5, height: 5)
                Text(state.isSearchActive ? "Filter Active" : "Folder X-Ray")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(settings.accentColor)
            }
            Rectangle().fill(Color.primary.opacity(0.13)).frame(width: 1, height: 18)
            Button { state.beginSearch() } label: { ShortcutHint(key: "⌘ F", label: "Filter Tree") }
                .buttonStyle(.plain).help("Filter this root folder’s subtree")
            Button {
                if let node = state.focusedNode { state.actions.quickLook(node) }
            } label: { ShortcutHint(key: "Space", label: "Quick Look") }
                .buttonStyle(.plain).disabled(state.focusedNode == nil)
            Button { state.escape() } label: {
                ShortcutHint(key: "Esc", label: state.isSearchActive ? "Clear Filter" : "Dismiss")
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .hooverGlass(settings, radius: 24).opacity(settings.opacity)
        .interactionRegion(in: "XRaySpace")
    }
}

@MainActor
private struct TreeColumnView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: HooverSettings
    let column: TreeColumn
    let availableHeight: CGFloat

    private var title: String {
        if column.level == 1 { return "DIRECT TREE" }
        if state.isSearchActive, !state.query.isEmpty, column.parentURL == state.rootURL {
            return "MATCHING BRANCHES"
        }
        return column.parentURL.lastPathComponent.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(settings.accentColor).frame(width: 5, height: 5)
                Text("LEVEL \(column.level) · \(title)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.6)
                    .foregroundStyle(settings.accentColor.opacity(column.level == 1 ? 0.95 : 0.72))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text("\(column.items.count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 4)
            if column.isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading folder…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .hooverGlass(settings).interactionRegion(in: "XRaySpace")
            } else if let error = column.error {
                emptyState(title: "Access unavailable", subtitle: error, icon: "lock")
            } else if column.items.isEmpty {
                emptyState(title: state.isSearchActive && !state.query.isEmpty ? "No matches" : "Empty folder",
                           subtitle: state.isSearchActive ? "Try another name or extension." : "Nothing inside this folder yet.",
                           icon: "folder")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: settings.cardDensity == "Compact" ? 8 : 12) {
                        ForEach(column.items) { node in
                            XRayNodeCard(state: state, settings: settings, node: node, level: column.level)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: NodeFramePreference.self,
                                                               value: [node.id: geometry.frame(in: .named("XRaySpace"))])
                                    }
                                }
                                .interactionRegion(in: "XRaySpace")
                                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                        }
                    }.padding(8)
                }.frame(maxHeight: max(130, availableHeight - 30))
            }
        }
        .animation(.easeOut(duration: 0.22), value: column.items.map(\.id))
    }

    private func emptyState(title: String, subtitle: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .hooverGlass(settings).interactionRegion(in: "XRaySpace")
    }
}

@MainActor
private struct XRayNodeCard: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: HooverSettings
    let node: FileNode
    let level: Int
    @State private var isHovered = false

    private var active: Bool { state.focusedNode?.id == node.id || state.selectedPath.contains(node.id) }
    private var isFocused: Bool { state.focusedNode?.id == node.id }
    private var preview: FileMetadata? { isFocused && settings.showPreviews && !node.isDirectory ? state.preview : nil }
    private var textSize: CGFloat { settings.textSize == "Large" ? 14 : settings.textSize == "Compact" ? 11 : 12 }

    private var detail: String {
        var parts = [node.isDirectory ? "Folder" : (node.url.pathExtension.isEmpty ? "File" : node.url.pathExtension.uppercased())]
        if node.isDirectory, settings.showFolderMetadata, !state.isSearchActive,
           let children = state.columns.first(where: { $0.parentURL == node.url && !$0.isLoading && $0.error == nil }) {
            parts.append("\(children.items.count) items")
        }
        if node.isSymbolicLink { parts.append("Symbolic link") }
        if let size = node.size, !node.isDirectory { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                FileGlyph(node: node, size: settings.cardDensity == "Compact" ? 27 : 34)
                VStack(alignment: .leading, spacing: 4) {
                    HighlightedName(name: node.name, query: state.query, accent: settings.accentColor,
                                    enabled: state.isSearchActive && settings.highlightMatches)
                        .font(.system(size: textSize, weight: .semibold))
                    Text(detail).font(.system(size: textSize - 2)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if settings.showTrashIcons {
                    Button { state.actions.moveToTrash(node) } label: {
                        Image(systemName: "trash").font(.system(size: 12))
                            .foregroundStyle(isHovered ? Color.primary.opacity(0.82) : Color.secondary.opacity(0.55))
                            .padding(5).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Move to Bin")
                        .accessibilityLabel("Move \(node.name) to Bin")
                }
                if node.isDirectory {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium))
                        .foregroundStyle(active ? settings.accentColor : Color.secondary)
                }
            }
            if let metadata = preview, metadata.url == node.url {
                InlineFilePreview(metadata: metadata, settings: settings)
            }
            if active && node.isDirectory {
                Divider().overlay(settings.accentColor.opacity(0.2))
                HStack(spacing: 5) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    Text(state.isSearchActive ? "Match path" : "Branch active")
                    Spacer()
                    Image(systemName: "arrow.right")
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(settings.accentColor)
            }
        }
        .padding(settings.cardDensity == "Compact" ? 11 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hooverGlass(settings, active: active || isHovered, radius: 14)
        .opacity(settings.opacity * (active || isHovered ? 1 : state.isSearchActive && !state.query.isEmpty ? 0.88 : 0.76))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovered in
            isHovered = hovered
            if hovered { state.hover(node, level: level) }
            else { state.unhover(node) }
        }
        .onTapGesture(count: 2) { state.open(node) }
        .onTapGesture { state.select(node, level: level) }
        .onDrag { NSItemProvider(contentsOf: node.url) ?? NSItemProvider(object: node.url as NSURL) }
        .contextMenu { NodeContextMenu(node: node, actions: state.actions, open: { state.open(node) }) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.name), \(detail)")
        .accessibilityHint(node.isDirectory ? "Hover to explore. Double-click to open a new Finder window." : "Double-click to open in the default application.")
    }
}

@MainActor
struct NodeContextMenu: View {
    let node: FileNode
    let actions: FileActions
    let open: () -> Void

    var body: some View {
        Button("Open", action: open)
        Button("Open With…") { actions.openWith(node) }
        Button("Quick Look") { actions.quickLook(node) }
        Button("Reveal in Finder") { actions.reveal(node) }
        Button("Get Info") { actions.getInfo(node) }
        Divider()
        Button("Copy") { actions.copy(node) }
        Button("Copy Path") { actions.copyPath(node) }
        Button("Copy Filename") { actions.copyName(node) }
        Divider()
        Button("Move to Bin") { actions.moveToTrash(node) }
    }
}

@MainActor
private struct ScopedSearchBar: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: HooverSettings
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(settings.accentColor)
            Text((state.rootURL?.lastPathComponent ?? "Folder") + "/")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(settings.accentColor)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 140)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(settings.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
            TextField("Filter this tree", text: Binding(get: { state.query }, set: { state.updateQuery($0) }))
                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                .focused($focused).accessibilityLabel("Search within the root folder")
            if !state.query.isEmpty {
                Text("\(state.searchMatchCount) \(state.searchMatchCount == 1 ? "match" : "matches")")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(settings.accentColor).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(settings.accentColor.opacity(0.13), in: Capsule())
            }
            Button { state.escape() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear filter (Esc)")
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
        .hooverGlass(settings, active: true, radius: 15).opacity(settings.opacity)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: state.isSearchActive) { focused = $0 }
    }
}

private struct ConnectorCanvas: View {
    let columns: [TreeColumn]
    let frames: [String: CGRect]
    let rootAnchor: CGPoint
    let activePath: Set<String>
    let focus: String?
    let accent: Color
    let searching: Bool

    var body: some View {
        Canvas { context, _ in
            for column in columns {
                for node in column.items {
                    guard let frame = frames[node.id] else { continue }
                    let source: CGPoint
                    if column.level == 1 {
                        source = rootAnchor
                    } else if let parent = frames[node.url.deletingLastPathComponent().path] {
                        source = CGPoint(x: parent.maxX, y: parent.midY)
                    } else { continue }
                    let target = CGPoint(x: frame.minX, y: frame.midY)
                    let active = activePath.contains(node.id) || node.id == focus
                    let bend = max(35, abs(target.x - source.x) * 0.43)
                    var path = Path()
                    path.move(to: source)
                    path.addCurve(to: target,
                                  control1: CGPoint(x: source.x + bend, y: source.y),
                                  control2: CGPoint(x: target.x - bend, y: target.y))
                    if active {
                        context.drawLayer { glow in
                            glow.addFilter(.blur(radius: 4))
                            glow.stroke(path, with: .color(accent.opacity(0.35)), lineWidth: searching ? 6 : 4)
                        }
                    }
                    context.stroke(path, with: .color(accent.opacity(active ? 0.88 : 0.13)),
                                   style: StrokeStyle(lineWidth: active ? 2 : 0.8, lineCap: .round))
                }
            }
            let ring = Path(ellipseIn: CGRect(x: rootAnchor.x - 6, y: rootAnchor.y - 6, width: 12, height: 12))
            context.stroke(ring, with: .color(accent.opacity(0.9)), lineWidth: 1.5)
            context.fill(Path(ellipseIn: CGRect(x: rootAnchor.x - 2, y: rootAnchor.y - 2, width: 4, height: 4)), with: .color(accent))
        }
    }
}
