import Foundation
import XCTest
@testable import Linea

final class MultiCursorControllerTests: XCTestCase {
    func testWordRangeInsideIdentifier() {
        let text = "hello_world foo" as NSString

        XCTAssertEqual(
            MultiCursorController.wordRange(at: 3, in: text),
            NSRange(location: 0, length: 11)
        )
    }

    func testWordRangeWhenCaretSitsAfterWord() {
        let text = "hello world" as NSString

        XCTAssertEqual(
            MultiCursorController.wordRange(at: 5, in: text),
            NSRange(location: 0, length: 5)
        )
    }

    func testWordRangeRejectsNonWordCharacters() {
        let text = "  --  " as NSString

        XCTAssertNil(MultiCursorController.wordRange(at: 2, in: text))
        XCTAssertNil(MultiCursorController.wordRange(at: 0, in: "" as NSString))
    }

    func testSelectNextOccurrenceContinuesAfterLastSelection() {
        let text = "foo bar foo baz foo"
        let result = MultiCursorController.selectNextOccurrence(
            in: text,
            selections: [NSRange(location: 0, length: 3)]
        )

        XCTAssertEqual(
            result,
            .updated([
                NSRange(location: 0, length: 3),
                NSRange(location: 8, length: 3),
            ])
        )
    }

    func testSelectNextOccurrenceUsesLastNonEmptySelection() {
        let text = "foo bar foo baz foo"
        let result = MultiCursorController.selectNextOccurrence(
            in: text,
            selections: [
                NSRange(location: 0, length: 3),
                NSRange(location: 8, length: 3),
            ]
        )

        XCTAssertEqual(
            result,
            .updated([
                NSRange(location: 0, length: 3),
                NSRange(location: 8, length: 3),
                NSRange(location: 16, length: 3),
            ])
        )
    }

    func testSelectNextOccurrenceFromCaretSelectsWordOnFirstPress() {
        let text = "foo bar foo"
        let first = MultiCursorController.selectNextOccurrence(
            in: text,
            selections: [NSRange(location: 1, length: 0)]
        )
        XCTAssertEqual(
            first,
            .updated([NSRange(location: 0, length: 3)])
        )

        // 第二次按下才追加下一个匹配项。
        let second = MultiCursorController.selectNextOccurrence(
            in: text,
            selections: [NSRange(location: 0, length: 3)]
        )
        XCTAssertEqual(
            second,
            .updated([
                NSRange(location: 0, length: 3),
                NSRange(location: 8, length: 3),
            ])
        )
    }

    func testSelectNextOccurrenceIsCaseSensitive() {
        let text = "Foo foo"
        let result = MultiCursorController.selectNextOccurrence(
            in: text,
            selections: [NSRange(location: 0, length: 3)]
        )

        XCTAssertEqual(
            result,
            .updated([
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 3),
            ])
        )
    }

    func testSelectNextOccurrenceReturnsNoChangeOnLastMatch() {
        let text = "foo bar foo"
        let result = MultiCursorController.selectNextOccurrence(
            in: text,
            selections: [NSRange(location: 8, length: 3)]
        )

        XCTAssertEqual(result, .noChange)
    }

    func testSelectNextOccurrenceReturnsNoChangeWithoutWord() {
        let result = MultiCursorController.selectNextOccurrence(
            in: "   ",
            selections: [NSRange(location: 1, length: 0)]
        )

        XCTAssertEqual(result, .noChange)
    }

    func testSelectNextOccurrenceClampsOutOfBoundsSelection() {
        let text = "abc abc"
        let result = MultiCursorController.selectNextOccurrence(
            in: text,
            selections: [NSRange(location: -5, length: 3)]
        )

        XCTAssertEqual(
            result,
            .updated([
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 3),
            ])
        )
    }

    func testSelectAllOccurrencesFindsNonOverlappingMatches() {
        let result = MultiCursorController.selectAllOccurrences(
            in: "aaaa",
            selections: [NSRange(location: 0, length: 2)]
        )

        XCTAssertEqual(
            result,
            .updated([
                NSRange(location: 0, length: 2),
                NSRange(location: 2, length: 2),
            ])
        )
    }

    func testSelectAllOccurrencesFindsEveryMatch() {
        let result = MultiCursorController.selectAllOccurrences(
            in: "foo foo foo",
            selections: [NSRange(location: 4, length: 3)]
        )

        XCTAssertEqual(
            result,
            .updated([
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 3),
                NSRange(location: 8, length: 3),
            ])
        )
    }

    func testSelectAllOccurrencesEnforcesLimit() {
        let text = String(repeating: "a", count: MultiCursorController.maximumSelections + 1)
        let result = MultiCursorController.selectAllOccurrences(
            in: text,
            selections: [NSRange(location: 0, length: 1)]
        )

        XCTAssertEqual(
            result,
            .tooMany(limit: MultiCursorController.maximumSelections)
        )
    }

    func testAddCursorsToSingleLinePutsCaretAtLineEnd() {
        let result = MultiCursorController.addCursorsToSelectedLines(
            in: "one\ntwo",
            selections: [NSRange(location: 0, length: 0)]
        )

        XCTAssertEqual(
            result,
            .updated([NSRange(location: 3, length: 0)])
        )
    }

    func testAddCursorsToSelectedLines() {
        let result = MultiCursorController.addCursorsToSelectedLines(
            in: "one\ntwo\nthree",
            selections: [NSRange(location: 0, length: 13)]
        )

        XCTAssertEqual(
            result,
            .updated([
                NSRange(location: 3, length: 0),
                NSRange(location: 7, length: 0),
                NSRange(location: 13, length: 0),
            ])
        )
    }

    func testAddCursorsToCRLFLinesDoesNotSplitNewline() {
        let result = MultiCursorController.addCursorsToSelectedLines(
            in: "a\r\nb\r\n",
            selections: [NSRange(location: 0, length: 6)]
        )

        XCTAssertEqual(
            result,
            .updated([
                NSRange(location: 1, length: 0),
                NSRange(location: 4, length: 0),
            ])
        )
    }

    func testAddCursorsDeduplicatesSelectionsOnSameLine() {
        let result = MultiCursorController.addCursorsToSelectedLines(
            in: "alpha\nbeta",
            selections: [
                NSRange(location: 0, length: 0),
                NSRange(location: 3, length: 0),
            ]
        )

        XCTAssertEqual(
            result,
            .updated([NSRange(location: 5, length: 0)])
        )
    }

    func testAddCursorsEnforcesLimit() {
        let lineCount = MultiCursorController.maximumSelections + 1
        let text = Array(repeating: "x", count: lineCount).joined(separator: "\n")
        let result = MultiCursorController.addCursorsToSelectedLines(
            in: text,
            selections: [NSRange(location: 0, length: text.utf16.count)]
        )

        XCTAssertEqual(
            result,
            .tooMany(limit: MultiCursorController.maximumSelections)
        )
    }
}
