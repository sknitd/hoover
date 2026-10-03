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
}

/// Produces observations; the coordinator owns dwell timers and overlay retention.
/// Accessibility work is serial, bounded, and never performed on the UI thread.
@MainActor
final class FinderTracker: ObservableObject {
    @Published private(set) var permissionGranted = AXIsProcessTrusted()
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

    private func poll() {
        guard timer != nil else { return }
        if Date().timeIntervalSince(lastPermissionCheck) >= 2 { refreshPermission() }
        let pointer = NSEvent.mouseLocation
        let active = NSWorkspace.shared.frontmostApplication
        let finderActive = active?.bundleIdentifier == "com.apple.finder"
        let ownAppActive = active?.processIdentifier == getpid()
        // Once a panel becomes key, continue observing its originating Finder
        // window's lifetime, without resolving hover items behind our own UI.
        let finderPID = finderActive ? active?.processIdentifier : (ownAppActive ?
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier : nil)
        guard permissionGranted, NSEvent.pressedMouseButtons == 0,
              let pid = finderPID, let activePID = active?.processIdentifier else {
            generation &+= 1
            onObservation?(FinderObservation(node: nil, bounds: nil,
                                             blocked: !permissionGranted || NSEvent.pressedMouseButtons != 0,
                                             finderActive: finderActive, pointer: pointer))
            return
        }
        guard !inFlight else { return }
        inFlight = true
        let token = generation
        let coordinates = FinderScreenCoordinates.current()
        let snapshot = FinderProbeSnapshot(pid: pid, pointer: pointer, coordinates: coordinates,
                                           allowHitTesting: finderActive)
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
                    self.onObservation?(FinderObservation(node: nil, bounds: nil,
                                                         blocked: NSEvent.pressedMouseButtons != 0,
                                                         finderActive: currentApp?.bundleIdentifier == "com.apple.finder",
                                                         pointer: currentPointer))
                    return
                }
                // A slow AX answer must never activate a file the pointer already left.
                // Also reject large movement within a tall row, since another child may
                // now be under the cursor. The following tick resolves that position.
                let distance = hypot(currentPointer.x - pointer.x, currentPointer.y - pointer.y)
                guard !finderActive || result.blocked || (distance <= 8 && result.bounds?.insetBy(dx: -1, dy: -1).contains(currentPointer) != false) else {
                    self.onObservation?(FinderObservation(node: nil, bounds: nil, blocked: false,
                                                         finderActive: finderActive, pointer: currentPointer,
                                                         liveWindowIDs: result.liveWindowIDs))
                    return
                }
                self.onObservation?(FinderObservation(node: result.node, bounds: result.bounds,
                                                     blocked: result.blocked, finderActive: finderActive,
                                                     pointer: currentPointer,
                                                     sourceWindowID: result.sourceWindowID,
                                                     liveWindowIDs: result.liveWindowIDs))
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
        let entries: [String: [URL]]
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
        guard let finder else { return FinderProbeResult() }
        let liveWindows = liveWindowSnapshot(finder)
        var result = snapshot.allowHitTesting ? observeItem(snapshot, app: finder) : FinderProbeResult()
        result.liveWindowIDs = liveWindows
        return result
    }

    private func observeItem(_ snapshot: FinderProbeSnapshot, app: AXUIElement) -> FinderProbeResult {
        if interactionIsBlocked(app) { return FinderProbeResult(blocked: true) }

        let point = snapshot.coordinates.quartzPoint(snapshot.pointer)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return FinderProbeResult() }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid == snapshot.pid else { return FinderProbeResult() }

        let chain = ancestors(of: hit, limit: 14)
        guard !chain.contains(where: isChrome), !chain.contains(where: isMenu) else {
            return FinderProbeResult(blocked: chain.contains(where: isMenu))
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
                return result(url: url, bounds: rect, coordinates: snapshot.coordinates, sourceWindowID: sourceWindowID)
            }
        }

        guard let base = safeDirectoryContext(chain: chain, candidates: candidates),
              let url = resolveName(candidates: candidates, in: base) else { return FinderProbeResult() }
        return result(url: url, bounds: rect, coordinates: snapshot.coordinates, sourceWindowID: sourceWindowID)
    }

    private func result(url: URL, bounds: CGRect?, coordinates: FinderScreenCoordinates,
                        sourceWindowID: Int?) -> FinderProbeResult {
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
        guard let cachedNode else { return FinderProbeResult() }
        return FinderProbeResult(node: cachedNode, bounds: bounds.map(coordinates.appKitRect),
                                 sourceWindowID: sourceWindowID)
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
        // Ambiguous labels are rejected. A description containing a comma or a
        // localized “folder” decoration only succeeds if it is an actual name.
        for name in names {
            let exact = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: exact.path) { return exact }
        }
        // Respect Finder's hidden extensions and localized display names without
        // guessing among coincidentally matching filenames. Bound this work and
        // cache it so moving among rows does not enumerate a directory every tick.
        let now = Date()
        let key = directory.path
        if directoryCache[key].map({ now.timeIntervalSince($0.created) >= 2 }) ?? true {
            var entries: [String: [URL]] = [:]
            let resourceKeys: [URLResourceKey] = [.nameKey, .localizedNameKey, .hasHiddenExtensionKey]
            if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: resourceKeys,
                                                              options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) {
                var count = 0
                while let url = enumerator.nextObject() as? URL, count < 2_000 {
                    count += 1
                    let values = try? url.resourceValues(forKeys: Set(resourceKeys))
                    var labels = Set([url.lastPathComponent])
                    if let localized = values?.localizedName { labels.insert(localized) }
                    if values?.hasHiddenExtension == true { labels.insert(url.deletingPathExtension().lastPathComponent) }
                    for label in labels { entries[label, default: []].append(url) }
                }
            }
            if directoryCache.count >= 8 { directoryCache.removeAll(keepingCapacity: true) }
            directoryCache[key] = NameCache(created: now, entries: entries)
        }
        for name in names {
            if let matches = directoryCache[key]?.entries[name], matches.count == 1 { return matches[0] }
        }
        return nil
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
