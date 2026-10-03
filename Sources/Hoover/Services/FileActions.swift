import AppKit
import HooverCore
import Quartz
import UniformTypeIdentifiers

/// Explicit user actions only. Paths are passed as argv, never interpolated into AppleScript.
@MainActor
final class FileActions: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var onDismiss: (() -> Void)?
    var onChanged: ((URL) -> Void)?
    var onError: ((String) -> Void)?
    private let settings: HooverSettings
    private var previewURL: URL?
    var hasPreview: Bool { previewURL != nil }

    init(settings: HooverSettings) {
        self.settings = settings
        super.init()
    }

    func open(_ node: FileNode) {
        let isPackage = (try? node.url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        if node.isDirectory && !isPackage {
            runFinderScript("""
                on run argv
                    set folderItem to POSIX file (item 1 of argv) as alias
                    tell application "Finder"
                        set target of (make new Finder window) to folderItem
                        activate
                    end tell
                    return ""
                end run
                """, path: node.url.path, dismissOnSuccess: true)
        } else if NSWorkspace.shared.open(node.url) {
            onDismiss?()
        } else {
            onError?("The default application could not open “\(node.name)”.")
        }
    }

    func reveal(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
        onDismiss?()
    }

    func quickLook(_ node: FileNode) {
        previewURL = node.url
        guard let panel = QLPreviewPanel.shared() else {
            onError?("Quick Look is unavailable.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        previewURL = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index == 0 else { return nil }
        return previewURL as NSURL?
    }

    func copy(_ node: FileNode) {
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.writeObjects([node.url as NSURL]) {
            onError?("Could not copy “\(node.name)” to the clipboard.")
        }
    }

    func copyPath(_ node: FileNode) { copyText(node.url.path) }
    func copyName(_ node: FileNode) { copyText(node.name) }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(text, forType: .string) {
            onError?("The clipboard is unavailable.")
        }
    }

    func getInfo(_ node: FileNode) {
        runFinderScript("""
            on run argv
                set finderItem to POSIX file (item 1 of argv) as alias
                tell application "Finder"
                    open information window of finderItem
                    activate
                end tell
                return ""
            end run
            """, path: node.url.path, dismissOnSuccess: false)
    }

    func moveToTrash(_ node: FileNode) {
        if settings.confirmTrash {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Move “\(node.name)” to Bin?"
            alert.informativeText = node.isDirectory
                ? "This folder and all of its contents will move to the Bin. You can restore them from Finder."
                : "You can restore this item from the Bin in Finder."
            alert.addButton(withTitle: "Move to Bin")
            alert.addButton(withTitle: "Cancel")
            // A destructive action never becomes an accidental Return-key default.
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: node.url, resultingItemURL: &trashedURL)
            onChanged?(node.url)
        } catch {
            onError?("Could not move “\(node.name)” to the Bin. \(error.localizedDescription)")
        }
    }

    func openWith(_ node: FileNode) {
        let menu = applicationsMenu(for: node)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func contextMenu(for node: FileNode) -> NSMenu {
        let menu = NSMenu()
        addItem("Open", to: menu) { [weak self] in self?.open(node) }
        let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWithItem.submenu = applicationsMenu(for: node)
        menu.addItem(openWithItem)
        addItem("Quick Look", to: menu) { [weak self] in self?.quickLook(node) }
        addItem("Reveal in Finder", to: menu) { [weak self] in self?.reveal(node) }
        menu.addItem(.separator())
        addItem("Copy", to: menu) { [weak self] in self?.copy(node) }
        addItem("Copy Path", to: menu) { [weak self] in self?.copyPath(node) }
        addItem("Copy Filename", to: menu) { [weak self] in self?.copyName(node) }
        addItem("Get Info", to: menu) { [weak self] in self?.getInfo(node) }
        menu.addItem(.separator())
        addItem("Move to Bin", to: menu) { [weak self] in self?.moveToTrash(node) }
        return menu
    }

    private func applicationsMenu(for node: FileNode) -> NSMenu {
        let menu = NSMenu(title: "Open With")
        let applications = NSWorkspace.shared.urlsForApplications(toOpen: node.url)
        let sorted = applications.sorted {
            $0.deletingPathExtension().lastPathComponent.localizedStandardCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending
        }
        for application in sorted {
            let name = application.deletingPathExtension().lastPathComponent
            let item = addItem(name, to: menu) { [weak self] in self?.open(node, using: application) }
            let icon = NSWorkspace.shared.icon(forFile: application.path).copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        if sorted.isEmpty {
            let empty = NSMenuItem(title: "No compatible applications found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        addItem("Other…", to: menu) { [weak self] in
            let panel = NSOpenPanel()
            panel.title = "Open “\(node.name)” With"
            panel.prompt = "Open"
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            if panel.runModal() == .OK, let application = panel.url { self?.open(node, using: application) }
        }
        return menu
    }

    private func open(_ node: FileNode, using application: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([node.url], withApplicationAt: application, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.onError?(error.localizedDescription) }
                else { self?.onDismiss?() }
            }
        }
    }

    @discardableResult
    private func addItem(_ title: String, to menu: NSMenu, action: @escaping () -> Void) -> NSMenuItem {
        let target = MenuAction(action: action)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
        item.target = target
        // NSMenuItem's target is weak; keep the action alive for the lifetime of this menu item.
        item.representedObject = target
        menu.addItem(item)
        return item
    }

    private func runFinderScript(_ script: String, path: String, dismissOnSuccess: Bool) {
        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                // Allow time for the first system Automation consent dialog, while bounding a stuck Finder.
                guard let result = InspectionProcess.run("/usr/bin/osascript", ["-e", script, path], timeout: 45, limit: 16_384) else {
                    return "Finder automation could not start."
                }
                if result.limited { return "Finder took too long to complete this action. Try again after responding to any macOS permission dialog." }
                if result.status == 0 { return nil }
                if result.stderr.contains("-1743") {
                    return "Allow Hoover to control Finder in System Settings → Privacy & Security → Automation, then try again."
                }
                let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return message.isEmpty ? "Finder could not complete this action." : message
            }.value
            if let failure { self?.onError?(failure) }
            else if dismissOnSuccess { self?.onDismiss?() }
        }
    }
}

@MainActor
private final class MenuAction: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
