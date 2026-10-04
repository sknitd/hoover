import AppKit
import Foundation
import HooverCore
import SwiftUI
import XCTest
@testable import Hoover

/// These are test-only views over a real temporary filesystem. They are never
/// compiled into Hoover, and do not simulate Finder detection or a product mode.
final class RenderSnapshotsTests: XCTestCase {
    @MainActor
    func testNativeViewsRenderAndExportEvaluationSnapshots() async throws {
        _ = NSApplication.shared
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("HooverRenderTests-" + UUID().uuidString)
        let root = temporary.appendingPathComponent("EdgeDock-source")
        let source = root.appendingPathComponent("EdgeDock/Core")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for folder in ["docs", "scripts", "EdgeDock/Views"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let code = source.appendingPathComponent("DockController.swift")
        try Data("@MainActor\nfinal class DockController {\n    private var isPinned = false\n    func presentEdgeOverlay() {\n        isPinned = true\n    }\n}\n".utf8).write(to: code)
        let readme = root.appendingPathComponent("README.md")
        try Data("# EdgeDock for macOS\n\nA local temporary fixture used to evaluate Hoover’s native views.\n".utf8).write(to: readme)
        var records: [IndexRecord] = []
        for await batch in RootIndexer().stream(root: root) { records += batch }
        let filtered = TreeSearch.search(query: "DockController", records: records)
        XCTAssertEqual(filtered.matches.count, 1)
        XCTAssertEqual(filtered.visibleIDs.count, 4)

        func state(theme: String, search: Bool = false) throws -> AppState {
            let suite = "HooverRenderTests-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            let settings = HooverSettings(defaults: defaults)
            settings.theme = theme
            settings.showNotes = false
            let state = AppState(settings: settings, workspace: WorkspaceStore(defaults: defaults))
            state.rootURL = root
            state.columns = [
                TreeColumn(parentURL: root, level: 1, items: try DirectoryReader.contents(of: root)),
                TreeColumn(parentURL: root.appendingPathComponent("EdgeDock"), level: 2,
                           items: try DirectoryReader.contents(of: root.appendingPathComponent("EdgeDock"))),
                TreeColumn(parentURL: source, level: 3, items: try DirectoryReader.contents(of: source))
            ]
            state.focusedNode = try DirectoryReader.node(at: code)
            state.selectedPath = Set([root.path, root.appendingPathComponent("EdgeDock").path, source.path, code.path])
            if search {
                state.isSearchActive = true
                state.query = "DockController"
                state.searchMatchCount = filtered.matches.count
                state.columns = state.columns.map { column in
                    TreeColumn(parentURL: column.parentURL, level: column.level,
                               items: column.items.filter { filtered.visibleIDs.contains($0.id) })
                }
            }
            defaults.removePersistentDomain(forName: suite)
            return state
        }

        for (name, theme, search) in [("dark-tree", "Dark", false), ("light-tree", "Light", false), ("dark-search", "Dark", true)] {
            let model = try state(theme: theme, search: search)
            try await render(XRayView(state: model, rootAnchor: CGPoint(x: 24, y: 270)), name: name,
                             size: NSSize(width: 1360, height: 880), dark: theme == "Dark")
        }
        let insightState = try state(theme: "Dark")
        insightState.insights = TreeInsights.analyze(records)
        insightState.showInsight(.largest)
        insightState.isPinned = true
        try await render(XRayView(state: insightState, rootAnchor: CGPoint(x: 24, y: 270)), name: "advanced-largest-pinned",
                         size: NSSize(width: 1360, height: 880), dark: true)
        try await render(HoverDiagnosticsView(state: insightState, tracker: insightState.tracker), name: "hover-diagnostics",
                         size: NSSize(width: 510, height: 400), dark: false)
        let fileState = try state(theme: "Dark")
        fileState.rootURL = nil
        fileState.focusedNode = try DirectoryReader.node(at: code)
        fileState.preview = await MetadataInspector.inspect(url: code)
        try await render(FileHUDView(state: fileState, maximumHeight: 620), name: "file-hud",
                         size: NSSize(width: 410, height: 660), dark: true)
    }

    @MainActor
    private func render<V: View>(_ content: V, name: String, size: NSSize, dark: Bool) async throws {
        let background = dark ? NSColor(calibratedRed: 0.075, green: 0.095, blue: 0.16, alpha: 1) : NSColor.windowBackgroundColor
        let view = NSHostingView(rootView: content.background(Color(nsColor: background)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = background
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw XCTSkip("This macOS test host cannot render an AppKit snapshot; inspect on a Mac with a WindowServer.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2_000, "Native view snapshot should contain rendered controls")
        if let path = ProcessInfo.processInfo.environment["HOOVER_SNAPSHOT_DIR"] {
            let output = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try png.write(to: output.appendingPathComponent(name + ".png"))
        }
        window.close()
    }
}
