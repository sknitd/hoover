import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: HooverSettings
    @State private var accessibilityGranted = AXIsProcessTrusted()

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "switch.2") }
            appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }
            folderXRay.tabItem { Label("Folder X-Ray", systemImage: "square.stack.3d.up") }
            fileHUD.tabItem { Label("File HUD", systemImage: "doc.text.magnifyingglass") }
            search.tabItem { Label("Search", systemImage: "magnifyingglass") }
            exclusions.tabItem { Label("Exclusions", systemImage: "folder.badge.minus") }
        }
        .frame(width: 760, height: 650)
        .tint(settings.accentColor)
        .preferredColorScheme(settings.preferredColorScheme)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    private var general: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(settings.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hoover").font(.title2.weight(.semibold))
                        Text("Hover deeper. See everything.").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Toggle("Hoover enabled", isOn: $settings.enabled)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                if let error = settings.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if SMLoginNeedsApproval {
                    Button("Review Login Item in System Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Section("Hover activation") {
                Toggle("Folder X-Ray", isOn: $settings.folderEnabled)
                delaySlider("Folder hover delay", value: $settings.folderDelay, range: 1...5)
                    .disabled(!settings.folderEnabled)
                Toggle("Individual File HUD", isOn: $settings.fileEnabled)
                delaySlider("File hover delay", value: $settings.fileDelay, range: 0.1...2)
                    .disabled(!settings.fileEnabled)
                Toggle("Show folder hover countdown", isOn: $settings.showCountdown)
                Toggle("Click outside to dismiss", isOn: $settings.clickOutsideDismiss)
            }
            Section("Accessibility permission") {
                Label(accessibilityGranted ? "Finder tracking is authorized" : "Permission required to identify Finder items under the pointer",
                      systemImage: accessibilityGranted ? "checkmark.shield" : "hand.raised")
                    .foregroundStyle(accessibilityGranted ? Color.secondary : Color.primary)
                Text("Hoover reads Finder's accessible item names and positions to detect hover. File inspection and metadata remain on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if !accessibilityGranted {
                    Button("Grant Accessibility Permission…") {
                        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                        accessibilityGranted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var appearance: some View {
        Form {
            Section("Color") {
                choices("Theme", selection: $settings.theme, values: ["System", "Light", "Dark"])
                choices("Accent", selection: $settings.accent, values: HooverSettings.accents)
                choices("Glow intensity", selection: $settings.glow, values: ["Low", "Medium", "High"])
            }
            Section("Surfaces") {
                Toggle("Enable Liquid Glass", isOn: $settings.liquidGlass)
                Text("Uses system glass where available and translucent material on earlier macOS releases.")
                    .font(.caption).foregroundStyle(.secondary)
                opacitySlider("X-Ray window opacity", value: $settings.opacity)
            }
            Section("Layout") {
                choices("Text size", selection: $settings.textSize, values: ["Compact", "Default", "Large"])
                choices("Card density", selection: $settings.cardDensity, values: ["Compact", "Comfortable"])
            }
        }
        .formStyle(.grouped)
    }

    private var folderXRay: some View {
        Form {
            Section("Navigation") {
                Toggle("Enable Folder X-Ray", isOn: $settings.folderEnabled)
                delaySlider("Root hover delay", value: $settings.folderDelay, range: 1...5)
                delaySlider("Inner folder hover delay", value: $settings.innerDelay, range: 0.1...1)
                Toggle("Auto-scroll to new level", isOn: $settings.autoScroll)
                Toggle("Show connector lines", isOn: $settings.showConnectors)
            }
            Section("Cards") {
                Toggle("Show file previews", isOn: $settings.showPreviews)
                Toggle("Show folder metadata", isOn: $settings.showFolderMetadata)
                Toggle("Show Git details", isOn: $settings.showGitDetails)
                Toggle("Show Bin icons", isOn: $settings.showTrashIcons)
                Toggle("Confirm before moving to Bin", isOn: $settings.confirmTrash)
            }
            Section("Traversal") {
                Toggle("Follow symbolic links", isOn: $settings.followSymlinks)
                Text("Off by default. Search stays within the original root and avoids recursive link loops.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var fileHUD: some View {
        Form {
            Section("Presentation") {
                Toggle("Enable File Hover", isOn: $settings.fileEnabled)
                delaySlider("Hover delay", value: $settings.fileDelay, range: 0.1...2)
                choices("Layout", selection: $settings.hudLayout, values: ["Rich", "Compact"])
                opacitySlider("HUD opacity", value: $settings.hudOpacity)
                Toggle("Show thumbnail", isOn: $settings.showThumbnail)
            }
            Section("Metadata") {
                Toggle("Basic metadata", isOn: $settings.showBasicMetadata)
                Toggle("Deep metadata", isOn: $settings.showDeepMetadata)
                Toggle("Developer metadata", isOn: $settings.showDeveloperMetadata)
                Toggle("Media metadata", isOn: $settings.showMediaMetadata)
                Toggle("Download source", isOn: $settings.showDownloadSource)
                Toggle("Finder tags", isOn: $settings.showFinderTags)
                Toggle("Notes", isOn: $settings.showNotes)
            }
            Section("Category order") {
                ForEach(Array(settings.metadataOrder.enumerated()), id: \.element) { index, category in
                    HStack {
                        Text(category.capitalized)
                        Spacer()
                        Button { moveCategory(at: index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .help("Move \(category) earlier")
                        Button { moveCategory(at: index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == settings.metadataOrder.count - 1)
                            .help("Move \(category) later")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var search: some View {
        Form {
            Section("Live tree filtering") {
                Toggle("Enable lightweight fuzzy fallback", isOn: $settings.fuzzySearch)
                Toggle("Highlight matched characters", isOn: $settings.highlightMatches)
                Text("Search covers the original root folder's subtree. Results retain their complete ancestry.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Background indexing") {
                Toggle("Index hidden files", isOn: $settings.includeHidden)
                Toggle("Include package contents", isOn: $settings.includePackages)
                Stepper(value: $settings.maximumIndexDepth, in: 0...1024) {
                    HStack {
                        Text("Maximum indexing depth")
                        Spacer()
                        Text(settings.maximumIndexDepth == 0 ? "Auto" : "\(settings.maximumIndexDepth) levels")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Auto indexes progressively without an artificial depth limit. A custom limit only restricts background search indexing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var exclusions: some View {
        Form {
            Section("Volumes") {
                Toggle("Exclude external disks", isOn: $settings.excludeExternalVolumes)
                Toggle("Exclude network shares", isOn: $settings.excludeNetworkVolumes)
            }
            Section("Excluded paths") {
                Text("Hoover skips these items and their descendants for hover and recursive indexing.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.exclusions.isEmpty {
                    Label("No excluded paths", systemImage: "folder").foregroundStyle(.secondary)
                }
                ForEach(settings.exclusions, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button {
                            settings.exclusions.removeAll { $0 == path }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove exclusion")
                    }
                }
                Button("Add Path…", action: addExclusion)
            }
        }
        .formStyle(.grouped)
    }

    private var SMLoginNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    private func delaySlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 190, alignment: .leading)
            Slider(value: value, in: range, step: 0.1)
            Text(String(format: "%.1f s", value.wrappedValue)).monospacedDigit().frame(width: 58, alignment: .trailing)
        }
    }

    private func opacitySlider(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 190, alignment: .leading)
            Slider(value: value, in: 0.7...1, step: 0.01)
            Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit().frame(width: 58, alignment: .trailing)
        }
    }

    private func choices(_ title: String, selection: Binding<String>, values: [String]) -> some View {
        Picker(title, selection: selection) {
            ForEach(values, id: \.self) { value in Text(value).tag(value) }
        }
    }

    private func moveCategory(at index: Int, by offset: Int) {
        let destination = index + offset
        guard settings.metadataOrder.indices.contains(index), settings.metadataOrder.indices.contains(destination) else { return }
        settings.metadataOrder.swapAt(index, destination)
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.title = "Exclude From Hoover"
        panel.prompt = "Exclude"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if !settings.exclusions.contains(path) { settings.exclusions.append(path) }
        }
    }
}
