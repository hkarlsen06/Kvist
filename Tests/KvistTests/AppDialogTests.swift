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
}
