import AppKit
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class OverlayController {
    private weak var state: AppState?
    private let panel: HooverPanel
    private let hosting: NSHostingView<AnyView>
    private let keyboard = OverlayKeyboardBridge()
    private var interactionRects: [CGRect] = []
    private var pointerTimer: Timer?
    private var localKeyMonitor: Any?
    private var subscriptions = Set<AnyCancellable>()
    private var finderAnchor = CGRect.zero
    private var folderMode = false

    var isVisible: Bool { panel.isVisible }

    /// Transparent areas pass pointer events through, while the gap between the
    /// Finder item and the first column remains a safe travel corridor.
    var containsPointer: Bool {
        guard isVisible else { return false }
        if !folderMode { return panel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation) }
        if finderAnchor.insetBy(dx: -12, dy: -12).contains(NSEvent.mouseLocation) { return true }
        let point = localPointer
        if interactionRects.contains(where: { $0.insetBy(dx: -12, dy: -12).contains(point) }) { return true }
        let nodes = interactionRects.filter { $0.width > 190 && $0.height > 40 && $0.height < 420 }
        guard let nearest = nodes.min(by: { $0.minX < $1.minX }) else { return false }
        let root = CGPoint(x: finderAnchor.maxX - panel.frame.minX, y: panel.frame.maxY - finderAnchor.midY)
        let corridor = CGRect(x: min(root.x, nearest.minX) - 12,
                              y: min(root.y, nearest.midY) - 22,
                              width: abs(nearest.minX - root.x) + 24,
                              height: abs(nearest.midY - root.y) + 44)
        return corridor.contains(point)
    }

    init(state: AppState) {
        self.state = state
        panel = HooverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        keyboard.onCommand = { [weak self] command in self?.handle(command) }
        state.$isSearchActive.dropFirst().sink { [weak self] active in
            guard active else { return }
            self?.focusSearch()
        }.store(in: &subscriptions)
    }

    func showFolder(anchor: CGRect) {
        guard let state else { return }
        let screen = screen(containing: anchor)
        let frame = screen.visibleFrame
        finderAnchor = anchor
        folderMode = true
        interactionRects = []
        panel.setFrame(frame, display: false)
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        let point = CGPoint(x: anchor.maxX - frame.minX + 4, y: frame.maxY - anchor.midY)
        hosting.rootView = AnyView(XRayView(state: state, rootAnchor: point) { [weak self] rects in
            self?.interactionRects = rects
            self?.updatePointerRouting()
        })
        present()
    }

    func showFile(anchor: CGRect) {
        guard let state else { return }
        let screen = screen(containing: anchor)
        let visible = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        let compact = state.settings.hudLayout == "Compact"
        let size = CGSize(width: min(compact ? 350 : 410, visible.width),
                          height: min(compact ? 282 : 660, visible.height))
        let right = anchor.maxX + 16
        let preferredX = right + size.width <= visible.maxX ? right : anchor.minX - size.width - 16
        let origin = CGPoint(x: min(max(preferredX, visible.minX), visible.maxX - size.width),
                             y: min(max(anchor.maxY - size.height + 30, visible.minY), visible.maxY - size.height))
        finderAnchor = anchor
        folderMode = false
        interactionRects = [CGRect(origin: .zero, size: size)]
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.rootView = AnyView(FileHUDView(state: state, maximumHeight: size.height - 24))
        present()
    }

    func focusSearch() {
        guard isVisible, folderMode else { return }
        panel.ignoresMouseEvents = false
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        updatePointerRouting()
    }

    func dismiss(restoreFinder: Bool = true) {
        // File opening disables restoration explicitly: Launch Services can
        // return before the new default application becomes frontmost.
        let shouldRestoreFinder = restoreFinder && panel.isKeyWindow && NSApp.keyWindow === panel
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
            && NSApp.modalWindow == nil
            && !NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeKey }
        keyboard.stop()
        pointerTimer?.invalidate()
        pointerTimer = nil
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor) }
        localKeyMonitor = nil
        panel.orderOut(nil)
        panel.alphaValue = 1
        hosting.rootView = AnyView(EmptyView())
        interactionRects = []
        if shouldRestoreFinder {
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?
                .activate(options: [.activateIgnoringOtherApps])
        }
    }

    private var localPointer: CGPoint {
        let screen = NSEvent.mouseLocation
        return CGPoint(x: screen.x - panel.frame.minX, y: panel.frame.maxY - screen.y)
    }

    private func screen(containing anchor: CGRect) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func present() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        pointerTimer?.invalidate()
        pointerTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePointerRouting() }
        }
        if let pointerTimer { RunLoop.main.add(pointerTimer, forMode: .common) }
        let tapAvailable = keyboard.start()
        installLocalFallback(enabled: !tapAvailable)
        updatePointerRouting()
        if !tapAvailable, folderMode {
            state?.errorMessage = "Keyboard shortcuts need Accessibility access. You can use the filter and dismiss buttons."
        }
    }

    private func updatePointerRouting() {
        guard isVisible else { return }
        let point = localPointer
        let interactive = !folderMode || interactionRects.contains { $0.insetBy(dx: -3, dy: -3).contains(point) }
        panel.ignoresMouseEvents = !interactive
        let finderActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        let editing = panel.firstResponder is NSTextView
        keyboard.update(active: finderActive || panel.isKeyWindow, folder: folderMode, editing: editing)
    }

    private func installLocalFallback(enabled: Bool) {
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor) }
        localKeyMonitor = nil
        guard enabled else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.window === self.panel,
                  let command = OverlayCommand.match(keyCode: event.keyCode, flags: event.modifierFlags,
                                                      folder: self.folderMode,
                                                      editing: self.panel.firstResponder is NSTextView) else { return event }
            self.handle(command)
            return nil
        }
    }

    private func handle(_ command: OverlayCommand) {
        guard isVisible, let state else { return }
        switch command {
        case .search: state.beginSearch(); focusSearch()
        case .escape: state.escape()
        case .quickLook: if let node = state.focusedNode { state.actions.quickLook(node) }
        case .open: if let node = state.focusedNode { state.open(node) }
        }
    }
}

private final class HooverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum OverlayCommand {
    case search, escape, quickLook, open

    static func match(keyCode: UInt16, flags: NSEvent.ModifierFlags, folder: Bool, editing: Bool) -> OverlayCommand? {
        let modifiers = flags.intersection([.command, .control, .option, .shift])
        if keyCode == 3 && modifiers == .command && folder { return .search }
        guard modifiers.isEmpty else { return nil }
        if keyCode == 53 { return .escape }
        guard !editing else { return nil }
        if keyCode == 49 { return .quickLook }
        if keyCode == 36 || keyCode == 76 { return .open }
        return nil
    }
}

/// The event tap only handles Hoover shortcuts during an actual visible session.
/// The lock is needed because CoreGraphics may deliver timeout callbacks off-main.
private final class OverlayKeyboardBridge: @unchecked Sendable {
    @MainActor var onCommand: ((OverlayCommand) -> Void)?
    private let lock = NSLock()
    private var active = false
    private var folder = false
    private var editing = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func update(active: Bool, folder: Bool, editing: Bool) {
        lock.lock()
        self.active = active
        self.folder = folder
        self.editing = editing
        lock.unlock()
    }

    func start() -> Bool {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                              options: .defaultTap, eventsOfInterest: mask,
                                              callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let bridge = Unmanaged<OverlayKeyboardBridge>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = bridge.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            bridge.lock.lock()
            let active = bridge.active
            let folder = bridge.folder
            let editing = bridge.editing
            bridge.lock.unlock()
            guard active, type == .keyDown,
                  let command = OverlayCommand.match(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                                                      flags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
                                                      folder: folder, editing: editing) else { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async { bridge.onCommand?(command) }
            return nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    func stop() {
        update(active: false, folder: false, editing: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    deinit { stop() }
}
