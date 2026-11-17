import Foundation
import Testing
@testable import LineaCore

@Suite("EditHistory")
struct EditHistoryTests {
    @Test func recordClearsRedo() {
        let history = EditHistory()
        history.record(transaction(location: 0, text: "a"))
        let undone = history.popUndo()
        #expect(undone != nil)
        #expect(history.canRedo)

        history.record(transaction(location: 0, text: "b", timestamp: 10))
        #expect(!history.canRedo)
        #expect(history.undoCount == 1)
    }

    @Test func entryLimitDropsOldest() {
        let history = EditHistory(
            limits: .init(maximumEntries: 2, maximumBytes: 1_000_000)
        )
        history.record(transaction(location: 0, text: "a", timestamp: 0))
        history.record(transaction(location: 1, text: "b", timestamp: 10))
        history.record(transaction(location: 2, text: "c", timestamp: 20))

        #expect(history.undoCount == 2)
        #expect(
            history.undoEntries.map { $0.edits[0].replacement } == ["b", "c"]
        )
    }

    @Test func byteLimitDropsOldest() {
        let history = EditHistory(
            limits: .init(maximumEntries: 10, maximumBytes: 9)
        )
        history.record(transaction(location: 0, text: "abcde"))

        // 一个 5 字符插入的内存估算为 10 字节，超过 9 字节上限。
        #expect(history.undoCount == 0)
        #expect(history.totalBytes == 0)

        history.record(transaction(location: 0, text: "ab"))
        #expect(history.undoCount == 1)
        #expect(history.totalBytes == 4)
    }

    @Test func typingCoalescesWithinWindow() {
        let history = EditHistory()
        history.record(transaction(location: 0, text: "a", origin: .typing))
        history.record(
            transaction(location: 1, text: "b", timestamp: 0.2, origin: .typing)
        )

        #expect(history.undoCount == 1)
        let merged = history.undoEntries[0]
        #expect(merged.edits == [
            TextEdit(range: NSRange(location: 0, length: 0), replacement: "ab")
        ])
        #expect(merged.inverseEdits == [
            TextEdit(range: NSRange(location: 0, length: 2), replacement: "")
        ])
        #expect(merged.selectionBefore == [.caret(at: 0)])
        #expect(merged.selectionAfter == [.caret(at: 2)])
        #expect(merged.timestamp == 0.2)
    }

    @Test func breakCoalescingSplitsNextTypingStep() {
        let history = EditHistory()
        history.record(transaction(location: 0, text: "a", origin: .typing))
        history.breakCoalescing()
        history.record(
            transaction(location: 1, text: "b", timestamp: 0.1, origin: .typing)
        )

        #expect(history.undoCount == 2)
        #expect(history.undoEntries.map { $0.edits[0].replacement } == ["a", "b"])
    }

    @Test func coalescingResumesAfterBarrierIsConsumed() {
        let history = EditHistory()
        history.record(transaction(location: 0, text: "a", origin: .typing))
        history.breakCoalescing()
        history.record(
            transaction(location: 1, text: "b", timestamp: 0.1, origin: .typing)
        )
        // 屏障只影响紧接着的一次记录，之后重新按时间窗口合并。
        history.record(
            transaction(location: 2, text: "c", timestamp: 0.2, origin: .typing)
        )

        #expect(history.undoCount == 2)
        #expect(history.undoEntries[1].edits[0].replacement == "bc")
    }

    @Test func clearResetsCoalescingBarrier() {
        let history = EditHistory()
        history.record(transaction(location: 0, text: "a", origin: .typing))
        history.breakCoalescing()
        history.clear()

        history.record(transaction(location: 0, text: "b", origin: .typing))
        history.record(
            transaction(location: 1, text: "c", timestamp: 0.1, origin: .typing)
        )

        #expect(history.undoCount == 1)
    }

    @Test func coalescingStopsAtWindowBoundary() {
        let history = EditHistory()
        history.record(transaction(location: 0, text: "a", origin: .typing))
        history.record(
            transaction(location: 1, text: "b", timestamp: 0.5, origin: .typing)
        )

        #expect(history.undoCount == 2)
    }

    @Test func coalescingRejectsLineTerminators() {
        let history = EditHistory()
        history.record(transaction(location: 0, text: "a", origin: .typing))
        history.record(
            transaction(location: 1, text: "\n", timestamp: 0.1, origin: .typing)
        )
        history.record(
            transaction(location: 2, text: "b", timestamp: 0.2, origin: .typing)
        )

        #expect(history.undoCount == 3)
    }

    @Test func coalescingRejectsMultiCursorAndOtherOrigins() {
        let multiCursor = EditHistory()
        multiCursor.record(transaction(location: 0, text: "a", origin: .typing))
        multiCursor.record(
            EditTransaction(
                edits: [
                    TextEdit(range: NSRange(location: 1, length: 0), replacement: "b")
                ],
                inverseEdits: [
                    TextEdit(range: NSRange(location: 1, length: 1), replacement: "")
                ],
                selectionBefore: [.caret(at: 1), .caret(at: 5)],
                selectionAfter: [.caret(at: 2), .caret(at: 6)],
                origin: .typing,
                timestamp: 0.1
            )
        )
        #expect(multiCursor.undoCount == 2)

        let ime = EditHistory()
        ime.record(transaction(location: 0, text: "a", origin: .inputMethod))
        ime.record(
            transaction(
                location: 1,
                text: "b",
                timestamp: 0.1,
                origin: .inputMethod
            )
        )
        #expect(ime.undoCount == 2)

        let deletion = EditHistory()
        deletion.record(transaction(location: 0, text: "a", origin: .deletion))
        deletion.record(
            transaction(location: 1, text: "b", timestamp: 0.1, origin: .deletion)
        )
        #expect(deletion.undoCount == 2)
    }

    @Test func popUndoRedoMovesEntriesBetweenStacks() {
        let history = EditHistory()
        let first = transaction(location: 0, text: "a")
        history.record(first)

        #expect(history.canUndo)
        #expect(!history.canRedo)

        #expect(history.popUndo() == first)
        #expect(!history.canUndo)
        #expect(history.canRedo)

        #expect(history.popRedo() == first)
        #expect(history.canUndo)
        #expect(!history.canRedo)
    }

    @Test func restoresHistoryWhenReplayFails() {
        let history = EditHistory()
        let tx = transaction(location: 0, text: "a")
        history.record(tx)

        let undone = history.popUndo()
        #expect(undone == tx)
        history.restoreAfterFailedUndo(undone!)
        #expect(history.undoCount == 1)
        #expect(history.redoCount == 0)

        _ = history.popUndo()
        let redone = history.popRedo()
        #expect(redone == tx)
        history.restoreAfterFailedRedo(redone!)
        #expect(history.undoCount == 0)
        #expect(history.redoCount == 1)
    }

    @Test func clearEmptiesEverything() {
        let history = EditHistory()
        history.record(transaction(location: 0, text: "a"))
        _ = history.popUndo()
        #expect(history.totalBytes > 0)

        history.clear()

        #expect(!history.canUndo)
        #expect(!history.canRedo)
        #expect(history.undoCount == 0)
        #expect(history.redoCount == 0)
        #expect(history.totalBytes == 0)
    }

    // MARK: - 工具

    private func transaction(
        location: Int,
        text: String,
        timestamp: TimeInterval = 0,
        origin: EditOrigin = .programmatic
    ) -> EditTransaction {
        let length = text.utf16.count
        return EditTransaction(
            edits: [
                TextEdit(
                    range: NSRange(location: location, length: 0),
                    replacement: text
                )
            ],
            inverseEdits: [
                TextEdit(
                    range: NSRange(location: location, length: length),
                    replacement: ""
                )
            ],
            selectionBefore: [.caret(at: location)],
            selectionAfter: [.caret(at: location + length)],
            origin: origin,
            timestamp: timestamp
        )
    }
}
