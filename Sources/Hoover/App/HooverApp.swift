import AppKit
import Combine
import Quartz
import SwiftUI

@main
enum HooverApplication {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = HooverAppDelegate()
        app.delegate = delegate
        app.nextResponder = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class HooverAppDelegate: NSResponder, NSApplicationDelegate, NSMenuDelegate {
    private let settings = HooverSettings()
    private lazy var state = AppState(settings: settings)
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var permissionWindow: NSWindow?
    private var diagnosticsPanel: NSPanel?
    private var subscriptions = Set<AnyCancellable>()
    private var activeItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var folderItem: NSMenuItem?
    private var fileItem: NSMenuItem?
    private var permissionItem: NSMenuItem?
    private var favoritesMenu: NSMenu?
    private var recentMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        state.start()
        settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.updateMenu()
            }
        }.store(in: &subscriptions)
        state.tracker.$permissionGranted.sink { [weak self] granted in
            guard let self else { return }
            self.updateMenu()
            if granted { self.permissionWindow?.close() }
        }.store(in: &subscriptions)
        state.$rootURL.sink { [weak self] root in
            self?.statusItem?.button?.toolTip = root == nil ? "Hoover — Hover deeper. See everything." : "Hoover — Folder X-Ray active"
        }.store(in: &subscriptions)
        state.$errorMessage.compactMap { $0 }.sink { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, !self.state.overlay.isVisible,
                      self.state.errorMessage == message, NSApp.modalWindow == nil else { return }
                // Saved locations can fail before a HUD exists to display the error.
                let alert = NSAlert()
                alert.messageText = "Hoover could not complete this action"
                alert.informativeText = message
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }.store(in: &subscriptions)
        if !state.tracker.permissionGranted { showPermissionWindow() }
        if ProcessInfo.processInfo.environment["HOOVER_LAUNCH_SMOKE_TEST"] == "1" {
            NSLog("Hoover native launch completed")
        }
    }

    func applicationWillTerminate(_ notification: Notification) { state.stop() }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { state.actions.hasPreview }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { state.actions.beginPreviewPanelControl(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { state.actions.endPreviewPanelControl(panel) }

    private func configureMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: "Hoover")
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.toolTip = "Hoover — Hover deeper. See everything."
        let menu = NSMenu(title: "Hoover")
        menu.delegate = self
        let title = NSMenuItem(title: "Hoover", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        activeItem = addItem("● Active", action: nil, menu: menu)
        menu.addItem(.separator())
        pauseItem = addItem("Pause Hoover", action: #selector(toggleEnabled), menu: menu)
        folderItem = addItem("Folder X-Ray", action: #selector(toggleFolder), menu: menu)
        fileItem = addItem("File Hover", action: #selector(toggleFile), menu: menu)
        menu.addItem(.separator())
        _ = addItem("Open Folder X-Ray…", action: #selector(chooseFolder), menu: menu)
        let favorites = addItem("Favorite Folders", action: nil, menu: menu)
        favoritesMenu = NSMenu(title: "Favorite Folders")
        favorites.submenu = favoritesMenu
        let recent = addItem("Recent Folders", action: nil, menu: menu)
        recentMenu = NSMenu(title: "Recent Folders")
        recent.submenu = recentMenu
        menu.addItem(.separator())
        permissionItem = addItem("Accessibility Permission…", action: #selector(showPermissionWindow), menu: menu)
        _ = addItem("Hover Diagnostics…", action: #selector(showDiagnostics), menu: menu)
        _ = addItem("Settings…", action: #selector(showSettings), key: ",", menu: menu)
        _ = addItem("About Hoover", action: #selector(showAbout), menu: menu)
        menu.addItem(.separator())
        _ = addItem("Quit Hoover", action: #selector(quit), key: "q", menu: menu)
        item.menu = menu
        statusItem = item
        updateMenu()
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector?, key: String = "", menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenu()
        populateLocations(favoritesMenu, roots: state.favoriteRoots, empty: "No favorite folders")
        populateLocations(recentMenu, roots: state.recentRoots, empty: "No recent folders")
        if !state.recentRoots.isEmpty, let menu = recentMenu {
            menu.addItem(.separator())
            _ = addItem("Clear Recent Folders", action: #selector(clearRecent), menu: menu)
        }
    }

    private func populateLocations(_ menu: NSMenu?, roots: [URL], empty: String) {
        guard let menu else { return }
        menu.removeAllItems()
        if roots.isEmpty {
            let item = NSMenuItem(title: empty, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for root in roots {
            let item = addItem(root.lastPathComponent, action: #selector(openLocation(_:)), menu: menu)
            item.representedObject = root
            item.toolTip = root.path
        }
    }

    @objc private func openLocation(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { state.openWorkspace(url) }
    }

    @objc private func clearRecent() { state.clearRecentRoots() }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Explore"
        panel.message = "Choose the root folder to explore in Hoover."
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.state.openWorkspace(url) }
        }
    }

    private func updateMenu() {
        let trusted = state.tracker.permissionGranted
        activeItem?.title = !settings.enabled ? "○ Paused" : trusted ? "● Active" : "○ Accessibility Required"
        activeItem?.isEnabled = false
        pauseItem?.title = settings.enabled ? "Pause Hoover" : "Resume Hoover"
        folderItem?.state = settings.folderEnabled ? .on : .off
        fileItem?.state = settings.fileEnabled ? .on : .off
        permissionItem?.isHidden = trusted
        statusItem?.button?.appearsDisabled = !settings.enabled
    }

    @objc private func toggleEnabled() { settings.enabled.toggle() }
    @objc private func toggleFolder() { settings.folderEnabled.toggle() }
    @objc private func toggleFile() { settings.fileEnabled.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showDiagnostics() {
        if diagnosticsPanel == nil {
            let panel = HoverDiagnosticsPanel(contentRect: NSRect(x: 0, y: 0, width: 510, height: 400),
                                              styleMask: [.titled, .closable, .nonactivatingPanel],
                                              backing: .buffered, defer: false)
            panel.title = "Hoover Hover Diagnostics"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: HoverDiagnosticsView(state: state, tracker: state.tracker))
            panel.center()
            diagnosticsPanel = panel
        }
        // Keeping this panel non-key allows real Finder hit testing to continue.
        diagnosticsPanel?.orderFrontRegardless()
    }

    @objc private func showSettings() {
        state.dismiss(restoreFinder: false)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Hoover Settings"
            window.minSize = NSSize(width: 680, height: 540)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showPermissionWindow() {
        state.dismiss(restoreFinder: false)
        if permissionWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 390),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Welcome to Hoover"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PermissionView(tracker: state.tracker))
            window.center()
            permissionWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        permissionWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showAbout() {
        state.dismiss(restoreFinder: false)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Hoover"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        alert.informativeText = "Hover deeper. See everything.\n\nFolder X-Ray and rich file metadata, directly above Finder.\n\nAll indexing and previews stay on this Mac.\nVersion \(version)\n\nFinder tracking inspired by KoukeNeko/FinderHover (MIT)."
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }
}

private struct PermissionView: View {
    @ObservedObject var tracker: FinderTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40, weight: .light)).foregroundStyle(.cyan)
            Text("Hover deeper. See everything.")
                .font(.system(size: 25, weight: .semibold, design: .rounded))
            Text("Hoover adds a quiet spatial layer above Finder. Hover a folder for 3 seconds to explore it. Hover a file to see a rich preview.")
                .foregroundStyle(.secondary)
            Text("Accessibility lets Hoover identify the Finder item beneath your pointer. File inspection, search, and previews run locally. Hoover sends no file contents or analytics to a server.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Enable Accessibility…") { tracker.requestPermission() }
                    .buttonStyle(.borderedProminent)
                Button("Open System Settings") { tracker.openPermissionSettings() }
            }
            Text(tracker.permissionGranted ? "Permission granted. Hoover is active in the menu bar." : "Enable Hoover under Privacy & Security → Accessibility, then return to Finder.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
