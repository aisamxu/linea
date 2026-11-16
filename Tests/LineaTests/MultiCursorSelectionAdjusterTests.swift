import Foundation
import XCTest
@testable import Linea

final class MultiCursorSelectionAdjusterTests: XCTestCase {
    func testTypingAcrossTwoSelections() {
        var adjuster = MultiCursorSelectionAdjuster(
            ranges: [
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 3),
            ]
        )

        // STTextView 从后往前替换：先处理第二个选区，再处理第一个。
        adjuster.apply(editRange: NSRange(location: 4, length: 3), replacementLength: 1)
        XCTAssertEqual(
            adjuster.ranges,
            [
                NSRange(location: 0, length: 3),
                NSRange(location: 5, length: 0),
            ]
        )

        adjuster.apply(editRange: NSRange(location: 0, length: 3), replacementLength: 1)
        XCTAssertEqual(
            adjuster.ranges,
            [
                NSRange(location: 1, length: 0),
                NSRange(location: 3, length: 0),
            ]
        )

        adjuster.clamp(to: 3)
        XCTAssertEqual(
            adjuster.ranges,
            [
                NSRange(location: 1, length: 0),
                NSRange(location: 3, length: 0),
            ]
        )
    }

    func testInsertionBeforeSelectionShiftsIt() {
        var adjuster = MultiCursorSelectionAdjuster(
            ranges: [NSRange(location: 5, length: 2)]
        )

        adjuster.apply(editRange: NSRange(location: 2, length: 0), replacementLength: 2)

        XCTAssertEqual(
            adjuster.ranges,
            [NSRange(location: 7, length: 2)]
        )
    }

    func testInsertionAtCaretMovesAfterInsertedText() {
        var adjuster = MultiCursorSelectionAdjuster(
            ranges: [NSRange(location: 3, length: 0)]
        )

        adjuster.apply(editRange: NSRange(location: 3, length: 0), replacementLength: 2)

        XCTAssertEqual(
            adjuster.ranges,
            [NSRange(location: 5, length: 0)]
        )
    }

    func testInsertionAfterSelectionLeavesItUnchanged() {
        var adjuster = MultiCursorSelectionAdjuster(
            ranges: [NSRange(location: 1, length: 2)]
        )

        adjuster.apply(editRange: NSRange(location: 5, length: 0), replacementLength: 1)

        XCTAssertEqual(
            adjuster.ranges,
            [NSRange(location: 1, length: 2)]
        )
    }

    func testDeletionBeforeSelectionShiftsIt() {
        var adjuster = MultiCursorSelectionAdjuster(
            ranges: [NSRange(location: 5, length: 2)]
        )

        adjuster.apply(editRange: NSRange(location: 1, length: 2), replacementLength: 0)

        XCTAssertEqual(
            adjuster.ranges,
            [NSRange(location: 3, length: 2)]
        )
    }

    func testCaretAtDeletionEndMovesToDeletionStart() {
        var adjuster = MultiCursorSelectionAdjuster(
            ranges: [NSRange(location: 3, length: 0)]
        )

        adjuster.apply(editRange: NSRange(location: 1, length: 2), replacementLength: 0)

        XCTAssertEqual(
            adjuster.ranges,
            [NSRange(location: 1, length: 0)]
        )
    }

    func testCaretAtDeletionStartStaysAtDeletionStart() {
        var adjuster = MultiCursorSelectionAdjuster(
            ranges: [NSRange(location: 2, length: 0)]
        )

        adjuster.apply(editRange: NSRange(location: 2, length: 3), replacementLength: 0)

        XCTAssertEqual(
            adjuster.ranges,
            [NSRange(location: 2, length: 0)]
        )
    }

    func testSelectionReplacedByTextBecomesCaretAfterReplacement() {
        var adjuster = MultiCursorSelectionAdjuster(
            ranges: [NSRange(location: 2, length: 3)]
        )

        adjuster.apply(editRange: NSRange(location: 2, length: 3), replacementLength: 1)

        XCTAssertEqual(
            adjuster.ranges,
            [NSRange(location: 3, length: 0)]
        )
    }

    func testClampToShorterText() {
        var adjuster = MultiCursorSelectionAdjuster(
            ranges: [
                NSRange(location: 10, length: 2),
                NSRange(location: 3, length: 9),
            ]
        )

        adjuster.clamp(to: 5)

        XCTAssertEqual(
            adjuster.ranges,
            [
                NSRange(location: 5, length: 0),
                NSRange(location: 3, length: 2),
            ]
        )
    }

    func testInvalidEditRangeLeavesSelectionsUnchanged() {
        var adjuster = MultiCursorSelectionAdjuster(
            ranges: [NSRange(location: 4, length: 1)]
        )

        adjuster.apply(
            editRange: NSRange(location: NSNotFound, length: 0),
            replacementLength: 1
        )

        XCTAssertEqual(
            adjuster.ranges,
            [NSRange(location: 4, length: 1)]
        )
    }
}
