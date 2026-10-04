import AppKit
import SwiftUI
import HooverCore

/// The tree's extra tools live in native menus and two small popovers so the
/// spatial canvas remains the primary interface.
@MainActor
struct WorkspaceToolsView: View {
    @ObservedObject private var state: AppState
    @ObservedObject private var settings: HooverSettings
    @State private var toolsPresented = false
    @State private var insightsPresented = false

    init(state: AppState) {
        self.state = state
        self.settings = state.settings
    }

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Button(state.isFavoriteRoot ? "Remove Root from Favorites" : "Favorite This Root") {
                    state.toggleFavoriteRoot()
                }
                Divider()
                Menu("Favorite Folders") { workspaceItems(state.favoriteRoots, empty: "No favorite folders yet") }
                Menu("Recent Folders") {
                    workspaceItems(state.recentRoots, empty: "No recent folders yet")
                    if !state.recentRoots.isEmpty {
                        Divider()
                        Button("Clear Recent Folders") { state.clearRecentRoots() }
                    }
                }
                Divider()
                SavedQueryMenu(state: state)
            } label: {
                Label("Workspace", systemImage: "square.stack.3d.up")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Favorite folders, recent roots, and saved filters")

            Button { insightsPresented.toggle() } label: {
                Label("Insights", systemImage: "chart.bar.xaxis")
            }
            .buttonStyle(.plain).help("Explore this root’s files and statistics")
            .popover(isPresented: $insightsPresented, arrowEdge: .bottom) {
                insightsPopover
            }

            Button { toolsPresented.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain).help("Sorting, pinning, visibility, and export")
            .accessibilityLabel("Tree tools")
            .popover(isPresented: $toolsPresented, arrowEdge: .bottom) {
                toolsPopover
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .disabled(state.rootURL == nil)
    }

    @ViewBuilder
    private func workspaceItems(_ roots: [URL], empty: String) -> some View {
        if roots.isEmpty { Text(empty).foregroundStyle(.secondary) }
        ForEach(roots, id: \.path) { url in
            Button {
                state.openWorkspace(url)
            } label: {
                Text(url.lastPathComponent + " — " + url.deletingLastPathComponent().lastPathComponent)
            }.help(url.path)
        }
    }

    private var toolsPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            popoverHeading("TREE TOOLS", subtitle: state.rootURL?.lastPathComponent ?? "Folder")
            VStack(alignment: .leading, spacing: 9) {
                Text("Sort by").font(.system(size: 11, weight: .medium))
                Picker("Sort by", selection: Binding(get: { state.sortOrder }, set: { state.setSortOrder($0) })) {
                    ForEach(NodeSortOrder.allCases, id: \.self) { order in
                        Text(order == .modified ? "Modified" : order.title).tag(order)
                    }
                }.labelsHidden().pickerStyle(.segmented)
                Toggle("Ascending order", isOn: Binding(get: { state.sortAscending }, set: { state.setAscending($0) }))
            }
            Divider()
            Toggle("Pin this session", isOn: Binding(get: { state.isPinned }, set: { value in
                if value != state.isPinned { state.togglePin() }
            }))
            .help("Keep Hoover open when the pointer leaves. Esc still dismisses it.")
            Toggle("Show hidden files", isOn: $settings.includeHidden)
            Divider()
            toolAction("Refresh & Reindex", symbol: "arrow.clockwise") {
                toolsPresented = false
                state.refresh()
            }
            toolAction("New Folder…", symbol: "folder.badge.plus") {
                toolsPresented = false
                if let parent = newFolderParent { state.createFolder(in: parent) }
            }
            .disabled(newFolderParent == nil)
            toolAction("Export Tree Manifest…", symbol: "square.and.arrow.up") {
                toolsPresented = false
                state.exportManifest()
            }
        }
        .font(.system(size: 11)).toggleStyle(.switch)
        .padding(20).frame(width: 300)
        .preferredColorScheme(settings.preferredColorScheme)
    }

    private var insightsPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            popoverHeading("ROOT INSIGHTS", subtitle: state.rootURL?.lastPathComponent ?? "Folder")
            if let summary = state.insights {
                summaryView(summary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Gathering folder information…").foregroundStyle(.secondary)
                }
            }
            Divider()
            insightAction("Largest Files", detail: "Review the largest indexed files.", symbol: "arrow.up.right", mode: .largest)
            insightAction("Recently Modified", detail: "See the newest changes within this root.", symbol: "clock", mode: .recent)
            insightAction("Same-Name Items", detail: "Find repeated names across folders.", symbol: "doc.on.doc", mode: .duplicateNames)
            if state.insightMode != .none {
                Divider()
                toolAction("Return to Tree", symbol: "point.3.connected.trianglepath.dotted") {
                    insightsPresented = false
                    state.resetInsight()
                }
            }
            if state.isIndexing {
                Text("Indexing is in progress. Insights are available when the scan finishes.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11)).padding(20).frame(width: 306)
        .preferredColorScheme(settings.preferredColorScheme)
    }

    private var newFolderParent: URL? {
        if let node = state.focusedNode, node.isDirectory {
            if node.isSymbolicLink, !settings.followSymlinks,
               node.url.standardizedFileURL != state.rootURL?.standardizedFileURL { return nil }
            return node.url
        }
        return state.rootURL
    }

    private func popoverHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .tracking(1.5).foregroundStyle(settings.accentColor)
            Text(subtitle).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
        }
    }

    private func summaryView(_ summary: TreeInsightSummary) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 18) {
                statistic("Files", value: String(summary.fileCount))
                statistic("Folders", value: String(summary.folderCount))
                statistic("Links", value: String(summary.symlinkCount))
            }
            HStack {
                Text("Known file size").foregroundStyle(.secondary)
                Spacer()
                Text((summary.totalBytesOverflowed ? "≥ " : "") + ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file))
                    .fontWeight(.medium)
            }
            if summary.unknownSizeFileCount > 0 {
                Text("Size metadata is unavailable for \(summary.unknownSizeFileCount) files.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let group = summary.duplicateNameGroups.first {
                HStack {
                    Text("Repeated name").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(group.name) × \(group.count)").lineLimit(1).truncationMode(.middle)
                }
            }
            let kinds = summary.kindCounts.filter { $0.key != .folder && $0.value > 0 }
                .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
            if !kinds.isEmpty {
                Text(kinds.prefix(3).map { "\($0.key.title) \($0.value)" }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func statistic(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 19, weight: .medium, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func insightAction(_ title: String, detail: String, symbol: String, mode: InsightMode) -> some View {
        Button {
            insightsPresented = false
            state.showInsight(mode)
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: symbol).foregroundStyle(settings.accentColor).frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if state.insightMode == mode { Image(systemName: "checkmark").foregroundStyle(settings.accentColor) }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func toolAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

@MainActor
struct SavedQueryMenu: View {
    @ObservedObject var state: AppState

    var body: some View {
        Menu("Saved Filters") {
            Button("Save Current Filter") { state.saveCurrentSearch() }
                .disabled(state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !state.savedSearches.isEmpty {
                Divider()
                ForEach(state.savedSearches) { search in
                    Button(search.name) { state.applySavedSearch(search) }.help(search.query)
                }
                Divider()
                Menu("Remove Saved Filter") {
                    ForEach(state.savedSearches) { search in
                        Button(search.name) { state.removeSavedSearch(search.id) }
                    }
                }
            }
        }
    }
}

@MainActor
struct WorkspaceBreadcrumbView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: HooverSettings

    var body: some View {
        HStack(spacing: 10) {
            Button { state.toggleFavoriteRoot() } label: {
                Image(systemName: state.isFavoriteRoot ? "star.fill" : "star")
                    .foregroundStyle(state.isFavoriteRoot ? settings.accentColor : Color.secondary)
            }.buttonStyle(.plain).help(state.isFavoriteRoot ? "Remove root from favorites" : "Favorite this root")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(Array(state.breadcrumbURLs.enumerated()), id: \.element.path) { index, url in
                        if index > 0 { Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(.tertiary) }
                        Button { state.navigateToBreadcrumb(url) } label: {
                            Text(url.lastPathComponent).lineLimit(1)
                                .foregroundStyle(index == 0 ? settings.accentColor : Color.secondary)
                        }.buttonStyle(.plain).help(url.path)
                    }
                }
            }
            if state.insightMode != .none {
                Button { state.resetInsight() } label: {
                    HStack(spacing: 5) {
                        Text(insightTitle).lineLimit(1)
                        Image(systemName: "xmark").font(.system(size: 7))
                    }.foregroundStyle(settings.accentColor)
                }.buttonStyle(.plain).help("Return to the normal tree")
            }
            if state.isPinned {
                Image(systemName: "pin.fill").foregroundStyle(settings.accentColor).help("Session pinned")
            }
        }
        .font(.system(size: 10))
        .padding(.horizontal, 13).padding(.vertical, 10)
        .hooverGlass(settings, radius: 13).opacity(settings.opacity)
        .accessibilityLabel("Explored folder path")
    }

    private var insightTitle: String {
        switch state.insightMode {
        case .none: return "Tree"
        case .largest: return "Largest"
        case .recent: return "Recent"
        case .duplicateNames: return "Same names"
        }
    }
}
