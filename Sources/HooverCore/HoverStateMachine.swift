import Foundation

public enum HoverAction: Equatable, Sendable {
    case none
    case showFolder(URL)
    case showFile(URL)
    case dismiss
}

/// Time is injected so a Finder probe can use a monotonic clock and tests never
/// depend on wall-clock sleeps. Tiny pointer movements over the same item do not
/// restart its countdown.
public struct HoverStateMachine: Sendable {
    public var folderDelay: TimeInterval
    public var fileDelay: TimeInterval
    public private(set) var hoveredNode: FileNode?
    public private(set) var presentedNode: FileNode?
    public private(set) var progress: Double = 0
    private var beganAt: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var suppressedID: String?

    public init(folderDelay: TimeInterval = 3, fileDelay: TimeInterval = 0.6) {
        self.folderDelay = folderDelay
        self.fileDelay = fileDelay
    }

    @discardableResult
    public mutating func update(node: FileNode?, timestamp: TimeInterval,
                                blocked: Bool = false) -> HoverAction {
        let time = timestamp.isFinite ? timestamp : (lastTimestamp ?? 0)
        let clockMovedBack = lastTimestamp.map { time < $0 } ?? false
        lastTimestamp = time

        if node?.id != suppressedID { suppressedID = nil }
        if blocked || node == nil || node?.id == suppressedID {
            hoveredNode = nil
            beganAt = nil
            progress = 0
            // A folder session remains open as the pointer travels into its
            // spatial canvas. Its owner resets it when Finder becomes invalid.
            if let presentedNode, !presentedNode.isDirectory {
                self.presentedNode = nil
                return .dismiss
            }
            return .none
        }

        guard let node else { return .none }
        let changed = hoveredNode?.id != node.id
        if changed || clockMovedBack {
            hoveredNode = node
            beganAt = time
            progress = 0
        }

        if let presentedNode, presentedNode.id != node.id, !presentedNode.isDirectory {
            self.presentedNode = nil
            return .dismiss
        }
        if presentedNode?.id == node.id {
            progress = 1
            return .none
        }

        let configuredDelay = node.isDirectory ? folderDelay : fileDelay
        let delay = configuredDelay.isFinite ? max(0, configuredDelay) : (node.isDirectory ? 3 : 0.6)
        let elapsed = max(0, time - (beganAt ?? time))
        progress = delay == 0 ? 1 : min(1, elapsed / delay)
        guard elapsed >= delay else { return .none }
        presentedNode = node
        return node.isDirectory ? .showFolder(node.url) : .showFile(node.url)
    }

    /// Suppression is useful after Escape: a stationary pointer must leave the
    /// dismissed item before it can reopen automatically.
    public mutating func reset(suppressCurrentNode: Bool = false) {
        suppressedID = suppressCurrentNode ? (hoveredNode?.id ?? presentedNode?.id) : nil
        hoveredNode = nil
        presentedNode = nil
        beganAt = nil
        lastTimestamp = nil
        progress = 0
    }
}

public enum EscapeAction: Equatable, Sendable {
    case none
    case restoreTree
    case dismissSession
}

/// Keeps the mandatory two-step Escape interaction independent of rendering.
public struct SessionNavigationState: Sendable {
    public private(set) var isSessionActive: Bool
    public private(set) var isSearchActive: Bool
    public private(set) var query: String

    public init(isSessionActive: Bool = true, isSearchActive: Bool = false, query: String = "") {
        self.isSessionActive = isSessionActive
        self.isSearchActive = isSessionActive && isSearchActive
        self.query = self.isSearchActive ? query : ""
    }

    public mutating func activateSession() {
        isSessionActive = true
        isSearchActive = false
        query = ""
    }

    public mutating func beginSearch() {
        guard isSessionActive else { return }
        isSearchActive = true
    }

    public mutating func setQuery(_ query: String) {
        guard isSessionActive else { return }
        isSearchActive = true
        self.query = query
    }

    @discardableResult
    public mutating func escape() -> EscapeAction {
        guard isSessionActive else { return .none }
        if isSearchActive {
            isSearchActive = false
            query = ""
            return .restoreTree
        }
        isSessionActive = false
        return .dismissSession
    }
}
