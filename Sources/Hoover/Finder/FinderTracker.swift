import AppKit
import ApplicationServices
import Combine
import HooverCore

/// The pointer and item frame use AppKit's global, bottom-left screen coordinates.
/// A nil node means there is no verified Finder item underneath the pointer.
struct FinderObservation {
    let node: FileNode?
    let bounds: CGRect?
    let blocked: Bool
    let finderActive: Bool
    let pointer: CGPoint
    var sourceWindowID: Int? = nil
    /// Nil means the window snapshot was unavailable or incomplete, not empty.
    var liveWindowIDs: Set<Int>? = nil
    /// True only after AX hit testing verifies Finder owns the element under the pointer.
    var pointerOverFinder = false
}

/// Fixed messages describe observed states without retaining filenames, paths,
/// Accessibility labels, or a history of what the user hovered.
enum FinderDiagnostic: String {
    case stopped = "Finder hover tracking is stopped."
    case permissionRequired = "Accessibility permission is required."
    case mouseButtonDown = "Hover is paused while a mouse button is held."
    case finderUnavailable = "Finder is not available."
    case activeApplicationUnavailable = "The foreground application could not be identified."
    case hooverWindowActive = "Hover is paused while a Hoover window is active."
    case applicationChanged = "The foreground application changed; waiting for a fresh hover."
    case pointerMoved = "The pointer moved before Finder answered; waiting for a fresh hover."
    case hitUnavailable = "Accessibility could not identify the item under the pointer."
    case ownershipUnavailable = "Accessibility could not identify which app owns the item."
    case pointerOutsideFinder = "The pointer is outside Finder."
    case interactionBlocked = "A menu, editor, or modal interaction is pausing Finder hover."
    case finderControls = "The pointer is over Finder controls rather than a file item."
    case noItem = "No Finder file item was verified under the pointer."
    case directoryContextUnavailable = "Finder did not expose a safe containing folder for this item."
    case nameUnresolved = "Finder's item name could not be matched uniquely in its folder."
    case itemUnreadable = "Finder identified an item, but its file information could not be read."
    case directItemVerified = "Finder item verified from its file location."
    case uniqueNameVerified = "Finder item verified from a unique name in its containing folder."

    static func preflight(permissionGranted: Bool, mouseButtonDown: Bool,
                          finderAvailable: Bool, activeApplicationAvailable: Bool) -> Self? {
        if !permissionGranted { return .permissionRequired }
        if mouseButtonDown { return .mouseButtonDown }
        if !finderAvailable { return .finderUnavailable }
        if !activeApplicationAvailable { return .activeApplicationUnavailable }
        return nil
    }
}

/// Produces observations; the coordinator owns dwell timers and overlay retention.
/// Accessibility work is serial, bounded, and never performed on the UI thread.
@MainActor
final class FinderTracker: ObservableObject {
    @Published private(set) var permissionGranted = AXIsProcessTrusted()
    @Published private(set) var diagnosticStatus = FinderDiagnostic.stopped.rawValue
    var onObservation: ((FinderObservation) -> Void)?

    private let queue = DispatchQueue(label: "com.hoover.finder-accessibility", qos: .userInitiated)
    private let probe = FinderAccessibilityProbe()
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var inFlight = false
    private var lastPermissionCheck = Date.distantPast

    func start() {
        guard timer == nil else { return }
        refreshPermission()
        let timer = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
            // Timer is installed exclusively on the main run loop.
            DispatchQueue.main.async { [weak self] in self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation &+= 1
        setDiagnostic(.stopped)
        // Let an outstanding probe finish; its generation will be discarded.
        onObservation?(FinderObservation(node: nil, bounds: nil, blocked: true,
                                         finderActive: false, pointer: NSEvent.mouseLocation))
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        permissionGranted = AXIsProcessTrustedWithOptions(options)
        lastPermissionCheck = Date()
        if !permissionGranted { openPermissionSettings() }
    }

    func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshPermission() {
        permissionGranted = AXIsProcessTrusted()
        lastPermissionCheck = Date()
    }

    private func setDiagnostic(_ diagnostic: FinderDiagnostic) {
        let message = diagnostic.rawValue
        if diagnosticStatus != message { diagnosticStatus = message }
    }

    private func poll() {
        guard timer != nil else { return }
        if Date().timeIntervalSince(lastPermissionCheck) >= 2 { refreshPermission() }
        let pointer = NSEvent.mouseLocation
        let active = NSWorkspace.shared.frontmostApplication
        let finderActive = active?.bundleIdentifier == "com.apple.finder"
        let ownAppActive = active?.processIdentifier == getpid()
        let ownWindowActive = ownAppActive && (NSApp.keyWindow != nil || NSApp.modalWindow != nil)
        // A key/modal Hoover window keeps probes context-only. Closing onboarding
        // can leave the accessory app frontmost with no key window; actual Finder
        // hit testing must resume there without requiring another click.
        let finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
        let mouseButtonDown = NSEvent.pressedMouseButtons != 0
        if let diagnostic = FinderDiagnostic.preflight(permissionGranted: permissionGranted,
                                                        mouseButtonDown: mouseButtonDown,
                                                        finderAvailable: finderPID != nil,
                                                        activeApplicationAvailable: active != nil) {
            generation &+= 1
            setDiagnostic(diagnostic)
            onObservation?(FinderObservation(node: nil, bounds: nil,
                                             blocked: !permissionGranted || mouseButtonDown,
                                             finderActive: finderActive, pointer: pointer))
            return
        }
        guard let pid = finderPID, let activePID = active?.processIdentifier else { return }
        guard !inFlight else { return }
        inFlight = true
        let token = generation
        let coordinates = FinderScreenCoordinates.current()
        let snapshot = FinderProbeSnapshot(pid: pid, pointer: pointer, coordinates: coordinates,
                                           allowHitTesting: !ownWindowActive)
        let probe = self.probe
        queue.async { [weak self] in
            let result = probe.observe(snapshot)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard self.timer != nil, self.generation == token else { return }
                let currentPointer = NSEvent.mouseLocation
                let currentApp = NSWorkspace.shared.frontmostApplication
                let stillActive = currentApp?.processIdentifier == activePID
                guard stillActive, NSEvent.pressedMouseButtons == 0 else {
                    self.setDiagnostic(NSEvent.pressedMouseButtons != 0 ? .mouseButtonDown : .applicationChanged)
                    self.onObservation?(FinderObservation(node: nil, bounds: nil,
                                                         blocked: NSEvent.pressedMouseButtons != 0,
                                                         finderActive: currentApp?.bundleIdentifier == "com.apple.finder",
                                                         pointer: currentPointer))
                    return
                }
                if snapshot.allowHitTesting, currentApp?.processIdentifier == getpid(),
                   NSApp.keyWindow != nil || NSApp.modalWindow != nil {
                    // Opening settings/onboarding can retain the same foreground
                    // PID while changing whether hover behind Hoover is allowed.
                    self.setDiagnostic(.hooverWindowActive)
                    self.onObservation?(FinderObservation(node: nil, bounds: nil, blocked: false,
                                                         finderActive: false, pointer: currentPointer,
                                                         liveWindowIDs: result.liveWindowIDs))
                    return
                }
                // A slow AX answer must never activate a file the pointer already left.
                // Also reject large movement within a tall row, since another child may
                // now be under the cursor. The following tick resolves that position.
                let distance = hypot(currentPointer.x - pointer.x, currentPointer.y - pointer.y)
                guard !snapshot.allowHitTesting || result.blocked || (distance <= 8 && result.bounds?.insetBy(dx: -1, dy: -1).contains(currentPointer) != false) else {
                    self.setDiagnostic(.pointerMoved)
                    self.onObservation?(FinderObservation(node: nil, bounds: nil, blocked: false,
                                                         finderActive: finderActive, pointer: currentPointer,
                                                         liveWindowIDs: result.liveWindowIDs))
                    return
                }
                self.setDiagnostic(result.diagnostic)
                self.onObservation?(FinderObservation(node: result.node, bounds: result.bounds,
                                                     blocked: result.blocked, finderActive: finderActive,
                                                     pointer: currentPointer,
                                                     sourceWindowID: result.sourceWindowID,
                                                     liveWindowIDs: result.liveWindowIDs,
                                                     pointerOverFinder: result.pointerOverFinder))
            }
        }
    }

    deinit { timer?.invalidate() }
}

/// Global Quartz coordinates are reflected around the primary display, even for
/// displays above, below, or to the left. Reflecting around the hovered display
/// would put AX hits on the wrong screen in vertical multi-display arrangements.
private struct FinderScreenCoordinates {
    let xOffset: CGFloat
    let top: CGFloat

    static func current() -> FinderScreenCoordinates {
        let primaryID = CGMainDisplayID()
        let primary = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == primaryID
        } ?? NSScreen.screens.first
        let quartz = CGDisplayBounds(primaryID)
        let appKit = primary?.frame ?? CGRect(x: 0, y: 0, width: quartz.width, height: quartz.height)
        return FinderScreenCoordinates(xOffset: appKit.minX - quartz.minX,
                                       top: appKit.maxY + quartz.minY)
    }

    func quartzPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - xOffset, y: top - point.y)
    }

    func appKitRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + xOffset, y: top - rect.maxY, width: rect.width, height: rect.height)
    }
}

private struct FinderProbeSnapshot {
    let pid: pid_t
    let pointer: CGPoint
    let coordinates: FinderScreenCoordinates
    let allowHitTesting: Bool
}

private struct FinderProbeResult {
    var node: FileNode? = nil
    var bounds: CGRect? = nil
    var blocked = false
    var sourceWindowID: Int? = nil
    var liveWindowIDs: Set<Int>? = nil
    var pointerOverFinder = false
    var diagnostic: FinderDiagnostic = .noItem
}

/// This object is accessed exclusively by FinderTracker's serial background queue.
private final class FinderAccessibilityProbe {
    private let system = AXUIElementCreateSystemWide()
    private var finder: AXUIElement?
    private var finderPID: pid_t = 0
    private var cachedNode: FileNode?
    private var cachedNodeDate = Date.distantPast
    private var directoryCache: [String: NameCache] = [:]

    private struct NameCache {
        let created: Date
        let index: FinderDisplayNameIndex
    }

    init() { AXUIElementSetMessagingTimeout(system, 0.04) }

    func observe(_ snapshot: FinderProbeSnapshot) -> FinderProbeResult {
        if finderPID != snapshot.pid {
            finderPID = snapshot.pid
            finder = AXUIElementCreateApplication(snapshot.pid)
            if let finder { AXUIElementSetMessagingTimeout(finder, 0.04) }
            cachedNode = nil
            directoryCache.removeAll()
        }
        guard let finder else { return FinderProbeResult(diagnostic: .finderUnavailable) }
        let liveWindows = liveWindowSnapshot(finder)
        var result = snapshot.allowHitTesting ? observeItem(snapshot, app: finder)
            : FinderProbeResult(diagnostic: .hooverWindowActive)
        result.liveWindowIDs = liveWindows
        return result
    }

    private func observeItem(_ snapshot: FinderProbeSnapshot, app: AXUIElement) -> FinderProbeResult {
        let point = snapshot.coordinates.quartzPoint(snapshot.pointer)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return FinderProbeResult(diagnostic: .hitUnavailable) }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success else {
            return FinderProbeResult(diagnostic: .ownershipUnavailable)
        }
        guard pid == snapshot.pid else { return FinderProbeResult(diagnostic: .pointerOutsideFinder) }
        var result = resolveFinderHit(hit, snapshot: snapshot, app: app, point: point)
        result.pointerOverFinder = true
        return result
    }

    private func resolveFinderHit(_ hit: AXUIElement, snapshot: FinderProbeSnapshot,
                                  app: AXUIElement, point: CGPoint) -> FinderProbeResult {
        if interactionIsBlocked(app) { return FinderProbeResult(blocked: true, diagnostic: .interactionBlocked) }
        let chain = ancestors(of: hit, limit: 14)
        if chain.contains(where: isMenu) {
            return FinderProbeResult(blocked: true, diagnostic: .interactionBlocked)
        }
        if chain.contains(where: isChrome) {
            return FinderProbeResult(diagnostic: .finderControls)
        }
        // Candidate elements must be actual hit items, not a viewport, window,
        // toolbar label, a selected child elsewhere, or the directory itself.
        let candidates = chain.prefix { role($0) != "AXWindow" }.filter {
            isItem($0) && frame($0)?.insetBy(dx: -1, dy: -1).contains(point) == true
        }
        guard !candidates.isEmpty else { return FinderProbeResult() }
        let item = candidates.first(where: { role($0) == "AXRow" }) ?? candidates.first!
        let rect = frame(item)
        let sourceWindowID = chain.first(where: { role($0) == "AXWindow" }).map(windowID)

        // Prefer file URLs or absolute paths on the hit item and its small leaf
        // descendants. The children are filtered to the hit row/cell only.
        for candidate in candidates {
            if let url = directFileURL(candidate) ?? descendantFileURL(candidate, depth: 2) {
                return result(url: url, bounds: rect, coordinates: snapshot.coordinates,
                              sourceWindowID: sourceWindowID, diagnostic: .directItemVerified)
            }
        }

        guard let base = safeDirectoryContext(chain: chain, candidates: candidates) else {
            return FinderProbeResult(diagnostic: .directoryContextUnavailable)
        }
        guard let url = resolveName(candidates: candidates, in: base) else {
            return FinderProbeResult(diagnostic: .nameUnresolved)
        }
        return result(url: url, bounds: rect, coordinates: snapshot.coordinates,
                      sourceWindowID: sourceWindowID, diagnostic: .uniqueNameVerified)
    }

    private func result(url: URL, bounds: CGRect?, coordinates: FinderScreenCoordinates,
                        sourceWindowID: Int?, diagnostic: FinderDiagnostic) -> FinderProbeResult {
        let now = Date()
        if cachedNode?.url != url || now.timeIntervalSince(cachedNodeDate) > 0.8 {
            if let node = try? DirectoryReader.node(at: url) {
                let knownPackages: Set<String> = ["app", "bundle", "xcodeproj", "xcworkspace", "pages", "numbers", "key", "rtfd", "photoslibrary"]
                let ext = node.url.pathExtension.lowercased()
                let package = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
                // Finder presents document/application packages as files. Opening
                // them should launch the default app, not browse their internals.
                // Asset catalog folders remain expandable source-tree folders.
                if node.isDirectory && ext != "xcassets" && (package || knownPackages.contains(ext)) {
                    cachedNode = FileNode(url: node.url, isDirectory: false,
                                          isSymbolicLink: node.isSymbolicLink, size: node.size, modified: node.modified)
                } else {
                    cachedNode = node
                }
            } else {
                cachedNode = nil
            }
            cachedNodeDate = now
        }
        guard let cachedNode else { return FinderProbeResult(diagnostic: .itemUnreadable) }
        return FinderProbeResult(node: cachedNode, bounds: bounds.map(coordinates.appKitRect),
                                 sourceWindowID: sourceWindowID, diagnostic: diagnostic)
    }

    private func windowID(_ window: AXUIElement) -> Int {
        Int(truncatingIfNeeded: CFHash(window))
    }

    private func liveWindowSnapshot(_ app: AXUIElement) -> Set<Int>? {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(app, "AXWindows" as CFString, &count) == .success,
              count >= 0, count <= 100 else { return nil }
        if count == 0 { return [] }
        let windows = array(app, "AXWindows", limit: count)
        // Finder can change its windows while querying; incomplete snapshots must
        // never falsely dismiss a session whose source window is still present.
        guard windows.count == count else { return nil }
        var ids = Set<Int>()
        for window in windows {
            guard !role(window).isEmpty else { return nil }
            var minimized: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(window, "AXMinimized" as CFString, &minimized)
            if status != .success && status != .attributeUnsupported && status != .noValue { return nil }
            if status == .success, minimized as? Bool == nil { return nil }
            if minimized as? Bool == true { continue }
            ids.insert(windowID(window))
        }
        var finalCount: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(app, "AXWindows" as CFString, &finalCount) == .success,
              finalCount == count else { return nil }
        return ids
    }

    private func interactionIsBlocked(_ app: AXUIElement) -> Bool {
        if let focused = element(app, "AXFocusedUIElement") {
            let focusChain = ancestors(of: focused, limit: 7)
            if focusChain.contains(where: isMenu) { return true }
            // Suppress rename editors, Finder's search box, and modal text editing.
            if focusChain.contains(where: { ["AXTextField", "AXTextArea"].contains(role($0)) }) { return true }
        }
        if let focused = element(system, "AXFocusedUIElement"),
           ancestors(of: focused, limit: 7).contains(where: isMenu) { return true }
        if children(app, limit: 16).contains(where: { role($0) == "AXMenu" }) { return true }
        if let window = element(app, "AXFocusedWindow") {
            if ["AXDialog", "AXSheet"].contains(role(window)) { return true }
            if ["AXFloatingWindow", "AXSystemDialog"].contains(string(window, "AXSubrole") ?? "") { return true }
            if !array(window, "AXSheets", limit: 4).isEmpty { return true }
        }
        return false
    }

    private func isMenu(_ element: AXUIElement) -> Bool {
        ["AXMenu", "AXMenuItem"].contains(role(element))
    }

    private func isChrome(_ element: AXUIElement) -> Bool {
        let role = role(element)
        if ["AXButton", "AXToolbar", "AXMenuBar", "AXScrollBar", "AXSearchField", "AXTextField",
            "AXTextArea", "AXSheet", "AXDialog", "AXPopUpButton", "AXDisclosureTriangle"].contains(role) { return true }
        // Sidebar entries can expose valid folder URLs but are Finder navigation
        // controls, not content items. Check only container identifiers/descriptions
        // so a real file named “Sidebar” is never accidentally excluded.
        if ["AXOutline", "AXTable", "AXGroup", "AXScrollArea", "AXSplitGroup"].contains(role) {
            let labels = [string(element, "AXIdentifier"), string(element, "AXSubrole"),
                          string(element, "AXRoleDescription")].compactMap { $0?.lowercased() }
            return labels.contains { $0.contains("sidebar") || $0.contains("source list") || $0.contains("sourcelist") || $0.contains("pathbar") }
        }
        return false
    }

    private func isItem(_ element: AXUIElement) -> Bool {
        let role = role(element)
        if ["AXRow", "AXCell", "AXImage"].contains(role) { return true }
        if role == "AXStaticText" {
            // A text leaf is safe only when it belongs to a verified item parent.
            guard let parent = self.element(element, "AXParent") else { return false }
            return ["AXRow", "AXCell", "AXImage"].contains(self.role(parent)) || isSmallIconGroup(parent)
        }
        return isSmallIconGroup(element)
    }

    private func isSmallIconGroup(_ element: AXUIElement) -> Bool {
        guard role(element) == "AXGroup" else { return false }
        let leaves = children(element, limit: 9)
        guard !leaves.isEmpty, leaves.count < 9 else { return false }
        let roles = leaves.map(role)
        return roles.filter { $0 == "AXImage" }.count == 1 && roles.contains("AXStaticText") &&
            !roles.contains { ["AXRow", "AXCell", "AXScrollArea", "AXOutline", "AXTable"].contains($0) }
    }

    private func directFileURL(_ element: AXUIElement) -> URL? {
        for attribute in ["AXURL", "AXFilename", "AXFileURL", "AXPath"] {
            if let url = fileURL(attributeValue(element, attribute)) { return url }
        }
        // Some Finder versions put an absolute path in AXValue/AXDescription.
        // These are accepted as paths only, never as guessed filenames here.
        for attribute in ["AXValue", "AXDescription", "AXTitle"] {
            if let url = fileURL(attributeValue(element, attribute)) { return url }
        }
        return nil
    }

    private func descendantFileURL(_ element: AXUIElement, depth: Int) -> URL? {
        guard depth > 0 else { return nil }
        let leaves = children(element, limit: 12)
        // A row contains cells for name, date, size, etc. We never enumerate a
        // browser/table container here, and never query AXSelectedChildren.
        for child in leaves where ["AXCell", "AXImage", "AXStaticText", "AXGroup"].contains(role(child)) {
            if let url = directFileURL(child) ?? descendantFileURL(child, depth: depth - 1) { return url }
        }
        return nil
    }

    private func safeDirectoryContext(chain: [AXUIElement], candidates: [AXUIElement]) -> URL? {
        // A column view may expose its own directory URL on an outline/list.
        // That context is safer than a window document describing a different
        // column. Never take a candidate's URL as its own parent directory.
        for container in chain where !candidates.contains(where: { CFEqual($0, container) }) &&
            ["AXOutline", "AXTable", "AXList", "AXBrowser", "AXScrollArea"].contains(role(container)) {
            for attribute in ["AXURL", "AXDocument"] {
                if let url = fileURL(attributeValue(container, attribute)), isDirectory(url) { return url }
            }
        }
        // Without column-local context, the window's document can refer to the
        // selected final column instead of the hovered earlier column. Suppress
        // that ambiguous fallback rather than showing/actions on the wrong file.
        guard !chain.contains(where: { role($0) == "AXBrowser" }),
              !chain.contains(where: { (string($0, "AXIdentifier") ?? "").lowercased().contains("column") }),
              let window = chain.first(where: { role($0) == "AXWindow" }),
              let base = fileURL(attributeValue(window, "AXDocument")), isDirectory(base) else { return nil }
        return base
    }

    private func resolveName(candidates: [AXUIElement], in directory: URL) -> URL? {
        var names: [String] = []
        func appendNames(_ item: AXUIElement) {
            for attribute in ["AXFilename", "AXTitle", "AXValue", "AXDescription"] {
                guard let name = string(item, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty, !name.contains("/"), name != ".", name != "..", !names.contains(name) else { continue }
                names.append(name)
            }
        }
        // In a list, the cursor may be over a Size/Date/Kind cell. Resolve the
        // name cell from that very row rather than treating “Yesterday” or “4 KB”
        // as filenames that might coincidentally exist in the same directory.
        if let row = candidates.first(where: { role($0) == "AXRow" }) {
            if let filename = string(row, "AXFilename"), !filename.contains("/") { names.append(filename) }
            let cells = children(row, limit: 16).filter { role($0) == "AXCell" }
            if let nameCell = cells.first {
                appendNames(nameCell)
                for leaf in children(nameCell, limit: 6) where ["AXStaticText", "AXImage"].contains(role(leaf)) {
                    appendNames(leaf)
                }
            } else {
                // Column/list rows may expose the name label directly.
                appendNames(row)
                for child in children(row, limit: 8) where ["AXStaticText", "AXImage"].contains(role(child)) {
                    appendNames(child)
                }
            }
        } else {
            for candidate in candidates {
                appendNames(candidate)
                for child in children(candidate, limit: 8) where ["AXStaticText", "AXImage"].contains(role(child)) {
                    appendNames(child)
                }
            }
        }
        // A raw filename is also a display label. It cannot bypass the complete
        // uniqueness check: “Report” may label both Report and hidden Report.pdf.
        // Cache only the local, bounded snapshot; direct per-item URLs above never
        // use this fallback and do not depend on directory enumeration.
        let now = Date()
        let key = directory.path
        if directoryCache[key].map({ now.timeIntervalSince($0.created) >= 2 }) ?? true {
            let index = FinderDisplayNameIndex.scan(directory: directory)
            if directoryCache.count >= 8 { directoryCache.removeAll(keepingCapacity: true) }
            directoryCache[key] = NameCache(created: now, index: index)
        }
        return directoryCache[key]?.index.uniqueURL(matchingAny: names)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func fileURL(_ value: CFTypeRef?) -> URL? {
        if let url = value as? URL, url.isFileURL { return url.standardizedFileURL }
        guard let raw = value as? String else { return nil }
        if raw.hasPrefix("file:"), let url = URL(string: raw), url.isFileURL { return url.standardizedFileURL }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw).standardizedFileURL }
        return nil
    }

    private func ancestors(of element: AXUIElement, limit: Int) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var current: AXUIElement? = element
        while let element = current, result.count < limit {
            if result.contains(where: { CFEqual($0, element) }) { break }
            result.append(element)
            if role(element) == "AXWindow" || role(element) == "AXApplication" { break }
            current = self.element(element, "AXParent")
        }
        return result
    }

    private func role(_ element: AXUIElement) -> String { string(element, "AXRole") ?? "" }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        attributeValue(element, attribute) as? String
    }

    private func attributeValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ item: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = attributeValue(item, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }

    private func children(_ item: AXUIElement, limit: Int) -> [AXUIElement] { array(item, "AXChildren", limit: limit) }

    private func array(_ item: AXUIElement, _ attribute: String, limit: Int) -> [AXUIElement] {
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(item, attribute as CFString, 0, limit, &values) == .success,
              let values = values as? [AXUIElement] else { return [] }
        return values
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attributeValue(element, "AXPosition"), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attributeValue(element, "AXSize"), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let pointValue = position as! AXValue
        let sizeValue = size as! AXValue
        guard AXValueGetType(pointValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(pointValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
