import Foundation
import Testing
@testable import LineaCore

@Suite("SelectionModel")
struct SelectionModelTests {
    @Test func defaultSelectionIsSingleCaret() {
        let model = SelectionModel()
        #expect(model.selections == [.caret(at: 0)])
        #expect(model.primary == .caret(at: 0))
    }

    @Test func emptyInputFallsBackToCaretZero() {
        #expect(SelectionModel.normalized([], textLength: 10) == [.caret(at: 0)])
    }

    @Test func clampingMatchesLegacySelectionBridge() {
        let model = SelectionModel.normalized(
            [
                TextSelection(range: NSRange(location: -5, length: 3)),
                TextSelection(range: NSRange(location: 8, length: 5)),
                TextSelection(range: NSRange(location: NSNotFound, length: 2)),
            ],
            textLength: 10
        )
        #expect(model.count == 3)
        #expect(model[0].range == NSRange(location: 0, length: 3))
        #expect(model[1].range == NSRange(location: 8, length: 2))
        #expect(model[2].range == NSRange(location: 0, length: 0))
    }

    @Test func duplicateSelectionsAreDeduplicated() {
        let model = SelectionModel.normalized(
            [.caret(at: 5), .caret(at: 2), .caret(at: 5)],
            textLength: 10
        )
        #expect(model == [.caret(at: 5), .caret(at: 2)])
    }

    @Test func overlappingSelectionsAreMerged() {
        let model = SelectionModel.normalized(
            [
                TextSelection(range: NSRange(location: 0, length: 5)),
                TextSelection(range: NSRange(location: 3, length: 5)),
            ],
            textLength: 20
        )
        #expect(model == [TextSelection(range: NSRange(location: 0, length: 8))])
    }

    @Test func caretInsideSelectionMergesButCaretAtBoundaryDoesNot() {
        let inside = SelectionModel.normalized(
            [TextSelection(range: NSRange(location: 0, length: 10)), .caret(at: 5)],
            textLength: 20
        )
        #expect(inside == [TextSelection(range: NSRange(location: 0, length: 10))])

        let atStart = SelectionModel.normalized(
            [TextSelection(range: NSRange(location: 3, length: 4)), .caret(at: 3)],
            textLength: 20
        )
        #expect(atStart.count == 2)

        let atEnd = SelectionModel.normalized(
            [TextSelection(range: NSRange(location: 3, length: 4)), .caret(at: 7)],
            textLength: 20
        )
        #expect(atEnd.count == 2)
    }

    @Test func adjacentSelectionsStayIndependent() {
        let model = SelectionModel.normalized(
            [
                TextSelection(range: NSRange(location: 0, length: 2)),
                TextSelection(range: NSRange(location: 2, length: 3)),
            ],
            textLength: 10
        )
        #expect(model.count == 2)
    }

    @Test func primarySelectionRemainsLast() {
        let model = SelectionModel.normalized(
            [.caret(at: 10), .caret(at: 2)],
            textLength: 20
        )
        #expect(model == [.caret(at: 10), .caret(at: 2)])
        #expect(model.last == .caret(at: 2))
    }

    @Test func maximumCountKeepsPrimary() {
        let input = (0..<5).map { TextSelection.caret(at: $0 * 2) }
        let model = SelectionModel.normalized(input, textLength: 20, maximumCount: 3)
        #expect(model.count == 3)
        #expect(model.last == input.last)
        #expect(model[0] == input[0])
        #expect(model[1] == input[1])
    }

    @Test func setReportsChangeAndClamps() {
        var model = SelectionModel()
        #expect(model.set([.caret(at: 0)], textLength: 5) == false)
        #expect(model.set([.caret(at: 8)], textLength: 5) == true)
        #expect(model.selections == [.caret(at: 5)])
        model.clamp(to: 2)
        #expect(model.selections == [.caret(at: 2)])
    }
}

@Suite("SelectionMapper")
struct SelectionMapperTests {
    // 1:1 移植 1.0.2 的 MultiCursorSelectionAdjusterTests 场景。

    @Test func typingAcrossTwoSelections() {
        let applied = applyEdits(to: "abcdefghij", [
            TextEdit(range: NSRange(location: 0, length: 3), replacement: "X"),
            TextEdit(range: NSRange(location: 4, length: 3), replacement: "Y"),
        ])
        let mapped = SelectionMapper.map(
            [
                TextSelection(range: NSRange(location: 0, length: 3)),
                TextSelection(range: NSRange(location: 4, length: 3)),
            ],
            through: applied
        )
        #expect(
            mapped.map(\.range) == [
                NSRange(location: 1, length: 0),
                NSRange(location: 3, length: 0),
            ]
        )
    }

    @Test func insertionBeforeSelectionShiftsIt() {
        let applied = applyEdits(to: "abcdefgh", [
            TextEdit(range: NSRange(location: 2, length: 0), replacement: "XY")
        ])
        let mapped = SelectionMapper.map(
            [TextSelection(range: NSRange(location: 5, length: 2))],
            through: applied
        )
        #expect(mapped.map(\.range) == [NSRange(location: 7, length: 2)])
    }

    @Test func insertionAtCaretMovesAfterInsertedText() {
        let applied = applyEdits(to: "abc", [
            TextEdit(range: NSRange(location: 3, length: 0), replacement: "XY")
        ])
        let mapped = SelectionMapper.map([.caret(at: 3)], through: applied)
        #expect(mapped.map(\.range) == [NSRange(location: 5, length: 0)])
    }

    @Test func insertionAfterSelectionLeavesItUnchanged() {
        let applied = applyEdits(to: "abcdef", [
            TextEdit(range: NSRange(location: 5, length: 0), replacement: "X")
        ])
        let mapped = SelectionMapper.map(
            [TextSelection(range: NSRange(location: 1, length: 2))],
            through: applied
        )
        #expect(mapped.map(\.range) == [NSRange(location: 1, length: 2)])
    }

    @Test func deletionBeforeSelectionShiftsIt() {
        let applied = applyEdits(to: "abcdefgh", [
            TextEdit(range: NSRange(location: 1, length: 2), replacement: "")
        ])
        let mapped = SelectionMapper.map(
            [TextSelection(range: NSRange(location: 5, length: 2))],
            through: applied
        )
        #expect(mapped.map(\.range) == [NSRange(location: 3, length: 2)])
    }

    @Test func caretAtDeletionEndMovesToDeletionStart() {
        let applied = applyEdits(to: "abcdef", [
            TextEdit(range: NSRange(location: 1, length: 2), replacement: "")
        ])
        let mapped = SelectionMapper.map([.caret(at: 3)], through: applied)
        #expect(mapped.map(\.range) == [NSRange(location: 1, length: 0)])
    }

    @Test func caretAtDeletionStartStaysAtDeletionStart() {
        let applied = applyEdits(to: "abcdef", [
            TextEdit(range: NSRange(location: 2, length: 3), replacement: "")
        ])
        let mapped = SelectionMapper.map([.caret(at: 2)], through: applied)
        #expect(mapped.map(\.range) == [NSRange(location: 2, length: 0)])
    }

    @Test func selectionReplacedByTextBecomesCaretAfterReplacement() {
        let applied = applyEdits(to: "abcdef", [
            TextEdit(range: NSRange(location: 2, length: 3), replacement: "X")
        ])
        let mapped = SelectionMapper.map(
            [TextSelection(range: NSRange(location: 2, length: 3))],
            through: applied
        )
        #expect(mapped.map(\.range) == [NSRange(location: 3, length: 0)])
    }

    @Test func emptyBatchLeavesSelectionsUnchanged() {
        let selections = [TextSelection(range: NSRange(location: 4, length: 1))]
        #expect(SelectionMapper.map(selections, through: []) == selections)
    }

    @Test func mapperPreservesOrderAndPrimary() {
        let applied = applyEdits(to: "abcdef", [
            TextEdit(range: NSRange(location: 0, length: 1), replacement: "XX")
        ])
        // 乱序选区：主选区（最后一个）在文档前部。
        let mapped = SelectionMapper.map(
            [.caret(at: 5), .caret(at: 0)],
            through: applied
        )
        #expect(
            mapped.map(\.range) == [
                NSRange(location: 6, length: 0),
                NSRange(location: 2, length: 0),
            ]
        )
        #expect(mapped.last == .caret(at: 2))
    }

    @Test func collapsedSelectionsCanBeNormalized() {
        let applied = applyEdits(to: "abcdef", [
            TextEdit(range: NSRange(location: 1, length: 2), replacement: ""),
            TextEdit(range: NSRange(location: 4, length: 1), replacement: ""),
        ])
        let mapped = SelectionMapper.map(
            [TextSelection(range: NSRange(location: 1, length: 2)), .caret(at: 4)],
            through: applied
        )
        #expect(mapped.map(\.range) == [
            NSRange(location: 1, length: 0),
            NSRange(location: 2, length: 0),
        ])
        #expect(SelectionModel.normalized(mapped, textLength: 3).count == 2)
    }

    private func applyEdits(to text: String, _ edits: [TextEdit]) -> [AppliedEdit] {
        PieceTreeBuffer(text: text).apply(edits: edits)
    }
}
