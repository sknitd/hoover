import AppKit
import SwiftUI
import HooverCore

@MainActor
struct FileHUDView: View {
    @ObservedObject private var state: AppState
    @ObservedObject private var settings: HooverSettings
    private let maximumHeight: CGFloat

    init(state: AppState, maximumHeight: CGFloat = 660) {
        self.state = state
        self.settings = state.settings
        self.maximumHeight = maximumHeight
    }

    private var compact: Bool { settings.hudLayout == "Compact" }

    var body: some View {
        Group {
            if let node = state.focusedNode {
                fileCard(node)
            } else { Color.clear }
        }
        .padding(12)
        .preferredColorScheme(settings.preferredColorScheme)
        .accessibilityLabel("Hoover File HUD")
    }

    private func fileCard(_ node: FileNode) -> some View {
        let metadata = state.preview?.url == node.url ? state.preview : nil
        return VStack(alignment: .leading, spacing: 0) {
            header(node, metadata: metadata)
            Divider().padding(.horizontal, 16)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                    if let metadata {
                        if !compact { InlineFilePreview(metadata: metadata, settings: settings, expanded: true) }
                        ForEach(visibleSections(metadata)) { section in
                            MetadataSectionView(section: section, settings: settings, compact: compact)
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading metadata…").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.vertical, 12)
                    }
                    if !compact && settings.showNotes { FileNoteEditor(url: node.url, settings: settings) }
                    if let message = state.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3)
                    }
                }.padding(16)
            }
            .frame(maxHeight: compact ? 140 : max(100, maximumHeight - 152))
            Divider().padding(.horizontal, 16)
            footer(node)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hooverGlass(settings, active: false, radius: 19).opacity(settings.hudOpacity)
        .contentShape(RoundedRectangle(cornerRadius: 19))
        .onTapGesture(count: 2) { state.open(node) }
        .onDrag { NSItemProvider(contentsOf: node.url) ?? NSItemProvider(object: node.url as NSURL) }
        .contextMenu { NodeContextMenu(node: node, actions: state.actions, open: { state.open(node) }) }
    }

    private func header(_ node: FileNode, metadata: FileMetadata?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            FileGlyph(node: node, size: compact ? 30 : 40)
            VStack(alignment: .leading, spacing: 5) {
                Text(node.name).font(.system(size: compact ? 12 : 14, weight: .semibold))
                    .lineLimit(2).truncationMode(.middle)
                Text(metadata?.kind ?? (node.url.pathExtension.isEmpty ? "File" : node.url.pathExtension.uppercased()))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                if !compact {
                    Text("HOOVER").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(2.2)
                        .foregroundStyle(settings.accentColor.opacity(0.85))
                }
            }
            Spacer(minLength: 0)
            Button { state.dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary).padding(4)
            }.buttonStyle(.plain).help("Dismiss (Esc)")
        }.padding(16)
    }

    private func footer(_ node: FileNode) -> some View {
        HStack(spacing: 10) {
            Text("Double-click to open").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Button { state.actions.quickLook(node) } label: {
                Image(systemName: "eye").font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(settings.accentColor).help("Quick Look (Space)")
            Button { state.actions.reveal(node) } label: {
                Image(systemName: "folder").font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
            Button { state.actions.moveToTrash(node) } label: {
                Image(systemName: "trash").font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("Move to Bin")
        }.padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func visibleSections(_ metadata: FileMetadata) -> [MetadataSection] {
        let sections = metadata.sections.filter { section in
            let category = metadataCategory(section.title)
            if section.title == "Notes" { return false } // The editable note below is the single notes surface.
            if section.title == "Origin" && !settings.showDownloadSource { return false }
            if category == "basic" && !settings.showBasicMetadata { return false }
            if compact { return section.title == "File" || section.title == "Access" }
            if category != "basic" && !settings.showDeepMetadata { return false }
            if category == "developer" && !settings.showDeveloperMetadata { return false }
            if ["media", "photo"].contains(category) && !settings.showMediaMetadata { return false }
            return true
        }
        return sections.enumerated().sorted { left, right in
            let a = settings.metadataOrder.firstIndex(of: metadataCategory(left.element.title)) ?? 99
            let b = settings.metadataOrder.firstIndex(of: metadataCategory(right.element.title)) ?? 99
            return a == b ? left.offset < right.offset : a < b
        }.map { item in
            let section = item.element
            let fields = section.fields.filter { field in
                if !settings.showFinderTags && field.label.localizedCaseInsensitiveContains("tag") { return false }
                if compact { return ["Size", "Modified", "Created", "Path", "Type"].contains(field.label) }
                return true
            }
            return MetadataSection(id: section.id, title: section.title, fields: fields)
        }.filter { !$0.fields.isEmpty }
    }
}

private func metadataCategory(_ title: String) -> String {
    switch title {
    case "File", "Access", "Preview", "Inspection", "Notes": return "basic"
    case "Image", "IPTC", "XMP", "EXIF", "Photography": return "photo"
    case "Audio", "Video", "Media": return "media"
    case "PDF", "Font", "SVG", "PSD", "3D model": return "document"
    case "Archive": return "archive"
    case "Origin", "Security", "Signing": return "security"
    default: return "developer"
    }
}

@MainActor
struct InlineFilePreview: View {
    let metadata: FileMetadata
    @ObservedObject var settings: HooverSettings
    var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = metadata.thumbnail, settings.showThumbnail {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: .infinity).frame(maxHeight: expanded ? 190 : 120)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .transition(.opacity)
                    .accessibilityLabel("File thumbnail")
            }
            if let text = metadata.textPreview, settings.showDeveloperMetadata {
                if metadata.url.pathExtension.lowercased() == "md" {
                    markdown(text)
                } else {
                    SyntaxSnippet(text: text, accent: settings.accentColor, maximumLines: expanded ? 14 : 7)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: metadata.thumbnail != nil)
    }

    private func markdown(_ text: String) -> some View {
        let preview = String(text.prefix(expanded ? 1200 : 400))
        let attributed = try? AttributedString(markdown: preview,
                                              options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(attributed ?? AttributedString(preview))
            .font(.system(size: 11)).lineLimit(expanded ? 12 : 6)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
private struct MetadataSectionView: View {
    let section: MetadataSection
    @ObservedObject var settings: HooverSettings
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
            if !compact {
                Text(section.title.uppercased()).font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .tracking(1.5).foregroundStyle(settings.accentColor.opacity(0.75))
            }
            ForEach(section.fields) { field in
                HStack(alignment: .top, spacing: 12) {
                    Text(field.label).foregroundStyle(.secondary).frame(width: compact ? 66 : 90, alignment: .leading)
                    Text(field.value).foregroundStyle(.primary).textSelection(.enabled)
                        .lineLimit(compact ? 2 : 5).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: settings.textSize == "Large" ? 12 : 10.5))
            }
        }
    }
}

@MainActor
private struct FileNoteEditor: View {
    let url: URL
    @ObservedObject var settings: HooverSettings
    @State private var text = ""
    @State private var savedText = ""
    @State private var saving = false
    @State private var error: String?
    private let service = MetadataService()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PERSONAL NOTE").font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .tracking(1.5).foregroundStyle(settings.accentColor.opacity(0.75))
                Spacer()
                Button(saving ? "Saving…" : "Save") { save() }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(settings.accentColor)
                    .disabled(saving || text == savedText)
            }
            TextEditor(text: $text).font(.system(size: 11)).scrollContentBackground(.hidden)
                .frame(height: 48).padding(6)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Personal note for this file")
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
        }
        .task(id: url.path) {
            let value = await service.note(url: url) ?? ""
            guard !Task.isCancelled else { return }
            text = value
            savedText = value
        }
    }

    private func save() {
        saving = true
        error = nil
        let value = text
        Task { @MainActor in
            do {
                try await service.saveNote(value, url: url)
                savedText = value
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
