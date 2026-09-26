import AppKit
import XCTest
@testable import Kvist

final class AppDialogTests: XCTestCase {
    @MainActor
    func testCommandDetailsAreAvailableWithoutRunningAnAsyncTask() throws {
        let output = "Command: git fetch\n\n" + String(repeating: "diagnostic output\n", count: 1_000)
        let accessory = AppDialogDisclosureAccessoryView(disclosure: AppDialogDisclosure(
            title: "Output",
            summary: "Full command output",
            text: output,
            isDiff: false
        ))
        let scrollView = try XCTUnwrap(accessory.subviews.compactMap { $0 as? NSScrollView }.first)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        XCTAssertEqual(textView.string, output)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertLessThanOrEqual(accessory.fittingSize.height, 300)
    }

    @MainActor
    func testExpandedDetailsReceiveClicksInsideTheAlert() throws {
        let alert = NSAlert()
        let accessory = AppDialogDisclosureAccessoryView(disclosure: AppDialogDisclosure(
            title: "Release Notes",
            summary: "Kvist",
            text: String(repeating: "release note line\n", count: 200),
            isDiff: false
        ))
        accessory.alert = alert
        alert.accessoryView = accessory
        alert.addButton(withTitle: "OK")
        alert.layout()
        let button = try XCTUnwrap(accessory.subviews.compactMap { $0 as? NSButton }.first)
        button.performClick(nil)

        let scrollView = try XCTUnwrap(accessory.subviews.compactMap { $0 as? NSScrollView }.first)
        let center = scrollView.convert(
            NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
            to: nil
        )
        let hit = alert.window.contentView?.superview?.hitTest(center)
        XCTAssertTrue(hit?.isDescendant(of: scrollView) == true)
        let textView = try XCTUnwrap(scrollView.documentView)
        XCTAssertGreaterThan(textView.frame.height, scrollView.contentSize.height)
    }
}
