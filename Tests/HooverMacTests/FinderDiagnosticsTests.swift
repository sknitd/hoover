import Combine
import XCTest
@testable import Hoover

final class FinderDiagnosticsTests: XCTestCase {
    func testPermissionDiagnosticRequiresObservedPermissionDenial() {
        XCTAssertEqual(FinderDiagnostic.preflight(permissionGranted: false, mouseButtonDown: false,
                                                 finderAvailable: true, activeApplicationAvailable: true),
                       .permissionRequired)
        XCTAssertEqual(FinderDiagnostic.preflight(permissionGranted: true, mouseButtonDown: false,
                                                 finderAvailable: false, activeApplicationAvailable: true),
                       .finderUnavailable,
                       "Missing Finder must not be presented as an Accessibility denial.")
        XCTAssertEqual(FinderDiagnostic.preflight(permissionGranted: true, mouseButtonDown: false,
                                                 finderAvailable: true, activeApplicationAvailable: false),
                       .activeApplicationUnavailable)
    }

    func testReleasingMouseOnlyClearsPreflightBlockAndDoesNotClaimVerifiedItem() {
        XCTAssertEqual(FinderDiagnostic.preflight(permissionGranted: true, mouseButtonDown: true,
                                                 finderAvailable: true, activeApplicationAvailable: true),
                       .mouseButtonDown)
        XCTAssertNil(FinderDiagnostic.preflight(permissionGranted: true, mouseButtonDown: false,
                                               finderAvailable: true, activeApplicationAvailable: true),
                     "Passing preflight still requires a successful Finder hit and file resolution.")
    }

    @MainActor
    func testRepeatedStopDoesNotRepublishIdenticalDiagnostic() {
        let tracker = FinderTracker()
        var statuses: [String] = []
        let subscription = tracker.$diagnosticStatus.sink { statuses.append($0) }
        defer { subscription.cancel() }

        tracker.stop()
        tracker.stop()

        XCTAssertEqual(statuses, [FinderDiagnostic.stopped.rawValue],
                       "Unchanged tracking state must not repeatedly invalidate the diagnostics view.")
    }
}
