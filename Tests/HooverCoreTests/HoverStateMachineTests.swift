import Foundation
import XCTest
@testable import HooverCore

final class HoverStateMachineTests: XCTestCase {
    private func node(_ name: String, folder: Bool = true) -> FileNode {
        FileNode(url: URL(fileURLWithPath: "/tmp/" + name), isDirectory: folder)
    }

    func testFolderRequiresContinuousDwellAndSwitchCancelsPreviousTimer() {
        var machine = HoverStateMachine()
        let first = node("first"), second = node("second")
        XCTAssertEqual(machine.update(node: first, timestamp: 0), .none)
        XCTAssertEqual(machine.update(node: first, timestamp: 2), .none)
        XCTAssertEqual(machine.progress, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(machine.update(node: second, timestamp: 2.8), .none)
        XCTAssertEqual(machine.progress, 0)
        XCTAssertEqual(machine.update(node: second, timestamp: 5), .none)
        XCTAssertEqual(machine.update(node: second, timestamp: 6), .showFolder(second.url))
        XCTAssertEqual(machine.update(node: second, timestamp: 10), .none)
    }

    func testLeavingCandidateCancelsAndDoesNotCountTimeElsewhere() {
        var machine = HoverStateMachine()
        let folder = node("folder")
        _ = machine.update(node: folder, timestamp: 0)
        XCTAssertEqual(machine.update(node: nil, timestamp: 2.9), .none)
        _ = machine.update(node: folder, timestamp: 20)
        XCTAssertEqual(machine.update(node: folder, timestamp: 22.9), .none)
        XCTAssertEqual(machine.update(node: folder, timestamp: 23), .showFolder(folder.url))
    }

    func testDraggingContextMenuAndRenameBlockAndRestartTheDwell() {
        for _ in ["dragging", "context menu", "renaming"] {
            var machine = HoverStateMachine()
            let folder = node("folder")
            _ = machine.update(node: folder, timestamp: 0)
            XCTAssertEqual(machine.update(node: folder, timestamp: 3, blocked: true), .none)
            XCTAssertEqual(machine.progress, 0)
            _ = machine.update(node: folder, timestamp: 4)
            XCTAssertEqual(machine.update(node: folder, timestamp: 6.9), .none)
            XCTAssertEqual(machine.update(node: folder, timestamp: 7), .showFolder(folder.url))
        }
    }

    func testFilesUseSeparateShortDelayAndDismissWhenNoLongerRelevant() {
        var machine = HoverStateMachine()
        let pdf = node("statement.pdf", folder: false)
        XCTAssertEqual(machine.update(node: pdf, timestamp: 0), .none)
        XCTAssertEqual(machine.update(node: pdf, timestamp: 0.59), .none)
        XCTAssertEqual(machine.update(node: pdf, timestamp: 0.6), .showFile(pdf.url))
        XCTAssertEqual(machine.update(node: pdf, timestamp: 0.7), .none)
        XCTAssertEqual(machine.update(node: nil, timestamp: 0.8), .dismiss)
        XCTAssertNil(machine.presentedNode)
    }

    func testSwitchingFromShownFileDismissesImmediatelyAndWaitsForNextFile() {
        var machine = HoverStateMachine(fileDelay: 1)
        let first = node("first.pdf", folder: false), next = node("next.png", folder: false)
        _ = machine.update(node: first, timestamp: 0)
        XCTAssertEqual(machine.update(node: first, timestamp: 1), .showFile(first.url))
        XCTAssertEqual(machine.update(node: next, timestamp: 2), .dismiss)
        XCTAssertEqual(machine.update(node: next, timestamp: 2.9), .none)
        XCTAssertEqual(machine.update(node: next, timestamp: 3), .showFile(next.url))
    }

    func testFolderSessionSurvivesTravelFromFinderIntoCanvas() {
        var machine = HoverStateMachine()
        let folder = node("folder")
        _ = machine.update(node: folder, timestamp: 0)
        _ = machine.update(node: folder, timestamp: 3)
        XCTAssertEqual(machine.update(node: nil, timestamp: 4), .none)
        XCTAssertEqual(machine.presentedNode, folder)
    }

    func testDismissSuppressionRequiresPointerToLeaveBeforeReopening() {
        var machine = HoverStateMachine(folderDelay: 1)
        let folder = node("folder")
        _ = machine.update(node: folder, timestamp: 0)
        _ = machine.update(node: folder, timestamp: 1)
        machine.reset(suppressCurrentNode: true)
        XCTAssertEqual(machine.update(node: folder, timestamp: 10), .none)
        XCTAssertEqual(machine.update(node: folder, timestamp: 20), .none)
        _ = machine.update(node: nil, timestamp: 21)
        _ = machine.update(node: folder, timestamp: 22)
        XCTAssertEqual(machine.update(node: folder, timestamp: 23), .showFolder(folder.url))
    }

    func testBackwardClockDoesNotAccidentallyCompleteCountdown() {
        var machine = HoverStateMachine(folderDelay: 1)
        let folder = node("folder")
        _ = machine.update(node: folder, timestamp: 10)
        XCTAssertEqual(machine.update(node: folder, timestamp: 9), .none)
        XCTAssertEqual(machine.progress, 0)
        XCTAssertEqual(machine.update(node: folder, timestamp: 10), .showFolder(folder.url))
    }

    func testEscapeClearsFilterThenDismissesSession() {
        var navigation = SessionNavigationState()
        navigation.beginSearch()
        navigation.setQuery("DockController")
        XCTAssertEqual(navigation.escape(), .restoreTree)
        XCTAssertTrue(navigation.isSessionActive)
        XCTAssertFalse(navigation.isSearchActive)
        XCTAssertEqual(navigation.query, "")
        XCTAssertEqual(navigation.escape(), .dismissSession)
        XCTAssertFalse(navigation.isSessionActive)
        XCTAssertEqual(navigation.escape(), .none)
    }

    func testEscapeWithoutSearchDismissesInOneStep() {
        var navigation = SessionNavigationState()
        XCTAssertEqual(navigation.escape(), .dismissSession)
        navigation.beginSearch()
        XCTAssertFalse(navigation.isSearchActive)
    }
}
