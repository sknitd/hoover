import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// User preferences are persisted locally. Launch at login uses the system's real registration state.
@MainActor
final class HooverSettings: ObservableObject {
    private let defaults: UserDefaults
    private var restoringLoginState = false

    @Published var enabled: Bool { didSet { save("enabled", enabled) } }
    @Published var folderEnabled: Bool { didSet { save("folderEnabled", folderEnabled) } }
    @Published var fileEnabled: Bool { didSet { save("fileEnabled", fileEnabled) } }
    @Published var folderDelay: Double { didSet { save("folderDelay", folderDelay) } }
    @Published var fileDelay: Double { didSet { save("fileDelay", fileDelay) } }
    @Published var innerDelay: Double { didSet { save("innerDelay", innerDelay) } }
    @Published var confirmTrash: Bool { didSet { save("confirmTrash", confirmTrash) } }
    @Published var followSymlinks: Bool { didSet { save("followSymlinks", followSymlinks) } }
    @Published var includeHidden: Bool { didSet { save("includeHidden", includeHidden) } }
    @Published var includePackages: Bool { didSet { save("includePackages", includePackages) } }
    @Published var maximumIndexDepth: Int { didSet { save("maximumIndexDepth", maximumIndexDepth) } }
    @Published var fuzzySearch: Bool { didSet { save("fuzzySearch", fuzzySearch) } }
    @Published var highlightMatches: Bool { didSet { save("highlightMatches", highlightMatches) } }
    @Published var clickOutsideDismiss: Bool { didSet { save("clickOutsideDismiss", clickOutsideDismiss) } }
    @Published var showCountdown: Bool { didSet { save("showCountdown", showCountdown) } }
    @Published var autoScroll: Bool { didSet { save("autoScroll", autoScroll) } }
    @Published var showConnectors: Bool { didSet { save("showConnectors", showConnectors) } }
    @Published var showPreviews: Bool { didSet { save("showPreviews", showPreviews) } }
    @Published var showFolderMetadata: Bool { didSet { save("showFolderMetadata", showFolderMetadata) } }
    @Published var showGitDetails: Bool { didSet { save("showGitDetails", showGitDetails) } }
    @Published var showTrashIcons: Bool { didSet { save("showTrashIcons", showTrashIcons) } }
    @Published var showThumbnail: Bool { didSet { save("showThumbnail", showThumbnail) } }
    @Published var showBasicMetadata: Bool { didSet { save("showBasicMetadata", showBasicMetadata) } }
    @Published var showDeepMetadata: Bool { didSet { save("showDeepMetadata", showDeepMetadata) } }
    @Published var showDeveloperMetadata: Bool { didSet { save("showDeveloperMetadata", showDeveloperMetadata) } }
    @Published var showMediaMetadata: Bool { didSet { save("showMediaMetadata", showMediaMetadata) } }
    @Published var showDownloadSource: Bool { didSet { save("showDownloadSource", showDownloadSource) } }
    @Published var showFinderTags: Bool { didSet { save("showFinderTags", showFinderTags) } }
    @Published var showNotes: Bool { didSet { save("showNotes", showNotes) } }
    @Published var liquidGlass: Bool { didSet { save("liquidGlass", liquidGlass) } }
    @Published var opacity: Double { didSet { save("opacity", opacity) } }
    @Published var hudOpacity: Double { didSet { save("hudOpacity", hudOpacity) } }
    @Published var theme: String { didSet { save("theme", theme) } }
    @Published var accent: String { didSet { save("accent", accent) } }
    @Published var glow: String { didSet { save("glow", glow) } }
    @Published var textSize: String { didSet { save("textSize", textSize) } }
    @Published var cardDensity: String { didSet { save("cardDensity", cardDensity) } }
    @Published var hudLayout: String { didSet { save("hudLayout", hudLayout) } }
    @Published var metadataOrder: [String] { didSet { save("metadataOrder", metadataOrder) } }
    @Published var exclusions: [String] { didSet { save("exclusions", exclusions) } }
    @Published var excludeExternalVolumes: Bool { didSet { save("excludeExternalVolumes", excludeExternalVolumes) } }
    @Published var excludeNetworkVolumes: Bool { didSet { save("excludeNetworkVolumes", excludeNetworkVolumes) } }
    @Published private(set) var loginItemError: String?
    @Published var launchAtLogin: Bool {
        didSet {
            guard !restoringLoginState, launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
                restoringLoginState = true
                launchAtLogin = oldValue
                restoringLoginState = false
            }
        }
    }

    static let categories = ["basic", "media", "photo", "document", "developer", "archive", "security"]
    static let accents = ["Electric Cyan", "Azure", "Violet", "Mint", "Graphite", "Sunset Orange", "Rose"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool = true) -> Bool {
            (defaults.object(forKey: "Hoover." + key) as? Bool) ?? fallback
        }
        func number(_ key: String, _ fallback: Double, range: ClosedRange<Double>) -> Double {
            guard let value = defaults.object(forKey: "Hoover." + key) as? Double, value.isFinite else { return fallback }
            return min(range.upperBound, max(range.lowerBound, value))
        }
        func choice(_ key: String, _ fallback: String, _ options: [String]) -> String {
            let value = defaults.string(forKey: "Hoover." + key) ?? fallback
            return options.contains(value) ? value : fallback
        }
        enabled = bool("enabled")
        folderEnabled = bool("folderEnabled")
        fileEnabled = bool("fileEnabled")
        folderDelay = number("folderDelay", 3, range: 1...5)
        fileDelay = number("fileDelay", 0.6, range: 0.1...2)
        innerDelay = number("innerDelay", 0.3, range: 0.1...1)
        confirmTrash = bool("confirmTrash")
        followSymlinks = bool("followSymlinks", false)
        includeHidden = bool("includeHidden", false)
        includePackages = bool("includePackages", false)
        maximumIndexDepth = max(0, defaults.integer(forKey: "Hoover.maximumIndexDepth"))
        fuzzySearch = bool("fuzzySearch", false)
        highlightMatches = bool("highlightMatches")
        clickOutsideDismiss = bool("clickOutsideDismiss")
        showCountdown = bool("showCountdown", false)
        autoScroll = bool("autoScroll")
        showConnectors = bool("showConnectors")
        showPreviews = bool("showPreviews")
        showFolderMetadata = bool("showFolderMetadata")
        showGitDetails = bool("showGitDetails")
        showTrashIcons = bool("showTrashIcons")
        showThumbnail = bool("showThumbnail")
        showBasicMetadata = bool("showBasicMetadata")
        showDeepMetadata = bool("showDeepMetadata")
        showDeveloperMetadata = bool("showDeveloperMetadata")
        showMediaMetadata = bool("showMediaMetadata")
        showDownloadSource = bool("showDownloadSource")
        showFinderTags = bool("showFinderTags")
        showNotes = bool("showNotes")
        liquidGlass = bool("liquidGlass", false)
        opacity = number("opacity", 0.94, range: 0.7...1)
        hudOpacity = number("hudOpacity", 0.94, range: 0.7...1)
        theme = choice("theme", "System", ["System", "Light", "Dark"])
        accent = choice("accent", "Electric Cyan", Self.accents)
        glow = choice("glow", "Medium", ["Low", "Medium", "High"])
        textSize = choice("textSize", "Default", ["Compact", "Default", "Large"])
        cardDensity = choice("cardDensity", "Comfortable", ["Compact", "Comfortable"])
        hudLayout = choice("hudLayout", "Rich", ["Rich", "Compact"])
        let storedOrder = defaults.stringArray(forKey: "Hoover.metadataOrder") ?? Self.categories
        var categoryOrder: [String] = []
        for category in storedOrder + Self.categories where Self.categories.contains(category) && !categoryOrder.contains(category) {
            categoryOrder.append(category)
        }
        metadataOrder = categoryOrder
        exclusions = defaults.stringArray(forKey: "Hoover.exclusions") ?? []
        excludeExternalVolumes = bool("excludeExternalVolumes", false)
        excludeNetworkVolumes = bool("excludeNetworkVolumes", false)
        launchAtLogin = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: "Hoover." + key)
    }

    var accentColor: Color {
        switch accent {
        case "Azure": return Color(red: 0.25, green: 0.58, blue: 1)
        case "Violet": return Color(red: 0.65, green: 0.47, blue: 1)
        case "Mint": return Color(red: 0.31, green: 0.86, blue: 0.68)
        case "Graphite": return Color(nsColor: .secondaryLabelColor)
        case "Sunset Orange", "Orange": return Color(red: 1, green: 0.57, blue: 0.25)
        case "Rose": return Color(red: 1, green: 0.4, blue: 0.64)
        default: return Color(red: 0.14, green: 0.82, blue: 0.91)
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch theme {
        case "Light": return .light
        case "Dark": return .dark
        default: return nil
        }
    }

    func isExcluded(_ url: URL) -> Bool {
        exclusionPredicate()(url)
    }

    /// Captures preferences and canonical exclusion paths once; directory workers can evaluate off-main.
    func exclusionPredicate() -> @Sendable (URL) -> Bool {
        let excludeExternal = excludeExternalVolumes
        let excludeNetwork = excludeNetworkVolumes
        var prefixSet = Set<String>()
        for excluded in exclusions {
            let expanded = (excluded as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/"), !expanded.isEmpty else { continue }
            let excludedURL = URL(fileURLWithPath: expanded).standardizedFileURL
            prefixSet.insert(excludedURL.path)
            prefixSet.insert(excludedURL.resolvingSymlinksInPath().standardizedFileURL.path)
        }
        let prefixes = Array(prefixSet)
        guard !prefixes.isEmpty || excludeExternal || excludeNetwork else { return { _ in false } }
        return { url in
            if !prefixes.isEmpty {
                let candidates = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path]
                for prefix in prefixes {
                    if candidates.contains(where: { $0 == prefix || $0.hasPrefix(prefix == "/" ? "/" : prefix + "/") }) { return true }
                }
            }
            if excludeExternal || excludeNetwork,
               let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey]) {
                if excludeNetwork && values.volumeIsLocal == false { return true }
                if excludeExternal && values.volumeIsInternal == false && values.volumeIsLocal != false { return true }
            }
            return false
        }
    }
}
