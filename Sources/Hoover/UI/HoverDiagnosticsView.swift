import AppKit
import SwiftUI

final class HoverDiagnosticsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
struct HoverDiagnosticsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var tracker: FinderTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Live hover diagnostics", systemImage: "waveform.path.ecg")
                .font(.title2.weight(.semibold))
            Text("Move your pointer over a visible Finder item. This window stays open while Hoover checks the hover.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Label(tracker.permissionGranted ? "Accessibility granted" : "Accessibility required",
                      systemImage: tracker.permissionGranted ? "checkmark.shield" : "lock.shield")
                Label(state.settings.enabled ? "Enabled" : "Paused", systemImage: state.settings.enabled ? "power" : "pause.circle")
            }.font(.caption)
            Divider()
            Text(tracker.diagnosticStatus).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(state.diagnosticReason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(state.diagnosticItem)
                Spacer()
                if state.hoverProgress > 0 {
                    Text("Hover delay \(Int(state.hoverProgress * 100))%")
                }
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Button("Restart Tracking") { state.restartTracking() }
                Button("Accessibility Settings") { tracker.openPermissionSettings() }
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
            }
        }.padding(24)
    }

    private var report: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        return """
        Hoover \(version)
        \(ProcessInfo.processInfo.operatingSystemVersionString)
        Accessibility granted: \(tracker.permissionGranted)
        Enabled: \(state.settings.enabled)
        Finder pointer verified: \(state.diagnosticFinderOwned)
        Probe: \(tracker.diagnosticStatus)
        Activation: \(state.diagnosticReason)
        Item: \(state.diagnosticItem)
        """
    }
}
