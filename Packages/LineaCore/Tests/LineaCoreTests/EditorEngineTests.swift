import Foundation
import Testing
@testable import LineaCore

@Suite("EditorEngine")
struct EditorEngineTests {
    // MARK: - 初始状态

    @Test func initializesAndClampsSelections() {
        let engine = EditorEngine(
            text: "abc\ndef",
            selections: [TextSelection(range: NSRange(location: 99, length: 5))]
        )

        #expect(engine.text == "abc\ndef")
        #expect(engine.length == 7)
        #expect(engine.lineCount == 2)
        #expect(engine.version == 0)
        #expect(engine.selections == [.caret(at: 7)])
        #expect(!engine.isDirty)
        #expect(!engine.canUndo)
        #expect(!engine.canRedo)
        #expect(!engine.isComposing)
        #expect(engine.history.undoCount == 0)
        #expect(engine.fullTextBuildCount == 1)
        #expect(engine.pieceCount > 0)
    }

    @Test func emptyDocumentHasOneCaret() {
        let engine = EditorEngine()
        #expect(engine.text.isEmpty)
        #expect(engine.length == 0)
        #expect(engine.lineCount == 1)
        #expect(engine.selections == [.caret(at: 0)])
        #expect(engine.lineRange(at: 1) == NSRange(location: 0, length: 0))
    }

    // MARK: - 键入与多光标

    @Test func insertTextAtSingleCaret() {
        let engine = EditorEngine(text: "ac", selections: [.caret(at: 1)])
        var changes: [EditorChange] = []
        engine.onChange = { changes.append($0) }

        engine.insertText("b")

        #expect(engine.text == "abc")
        #expect(engine.selections == [.caret(at: 2)])
        #expect(engine.version == 1)
        #expect(engine.isDirty)
        #expect(engine.history.undoCount == 1)
        #expect(changes.count == 1)

        let change = changes.first
        #expect(change?.origin == .typing)
        #expect(change?.versionBefore == 0)
        #expect(change?.versionAfter == 1)
        #expect(change?.edits == [
            TextEdit(range: NSRange(location: 1, length: 0), replacement: "b")
        ])
        #expect(change?.applied.count == 1)
        #expect(change?.selectionBefore == [.caret(at: 1)])
        #expect(change?.selectionAfter == [.caret(at: 2)])
        #expect(change?.lineCountBefore == 1)
        #expect(change?.lineCountAfter == 1)
        #expect(change?.isDirty == true)
        #expect(change?.canUndo == true)
        #expect(change?.canRedo == false)
    }

    @Test func multiCursorInsertReplacesAllSelections() {
        let engine = EditorEngine(
            text: "abcdef",
            selections: [
                .caret(at: 1),
                TextSelection(range: NSRange(location: 2, length: 3)),
            ]
        )

        engine.insertText("X")

        #expect(engine.text == "aXbXf")
        #expect(engine.selections == [.caret(at: 2), .caret(at: 4)])
        #expect(engine.history.undoCount == 1)

        #expect(engine.undo())
        #expect(engine.text == "abcdef")
        #expect(engine.selections == [
            .caret(at: 1),
            TextSelection(range: NSRange(location: 2, length: 3)),
        ])
    }

    @Test func manyCursorsProduceSingleHistoryEntry() {
        let text = String(repeating: "abcdefghij\n", count: 500)
        let selections = (0..<500).map { TextSelection.caret(at: $0 * 11) }
        let engine = EditorEngine(text: text, selections: selections)

        engine.insertText("x")

        #expect(engine.selections.count == 500)
        #expect(engine.history.undoCount == 1)
        let edited = engine.text

        #expect(engine.undo())
        #expect(engine.text == text)
        #expect(engine.selections.count == 500)

        #expect(engine.redo())
        #expect(engine.text == edited)
        #expect(engine.selections.count == 500)
    }

    @Test func changingSelectionsDoesNotTouchText() {
        let engine = EditorEngine(text: "abc")

        #expect(engine.setSelections([.caret(at: 2)]))
        #expect(!engine.isDirty)
        #expect(engine.version == 0)
        #expect(!engine.canUndo)
        #expect(!engine.setSelections([.caret(at: 2)]))
    }

    // MARK: - 删除

    @Test func deleteSelectionsRemovesWholeSelection() {
        let engine = EditorEngine(
            text: "hello",
            selections: [TextSelection(range: NSRange(location: 1, length: 2))]
        )

        engine.delete(.backward, .character)
        #expect(engine.text == "hlo")
        #expect(engine.selections == [.caret(at: 1)])
    }

    @Test func deleteBackwardCharacterWithMultipleCarets() {
        let engine = EditorEngine(
            text: "abcd",
            selections: [.caret(at: 1), .caret(at: 3)]
        )

        engine.delete(.backward, .character)

        #expect(engine.text == "bd")
        #expect(engine.selections == [.caret(at: 0), .caret(at: 1)])
    }

    @Test func deleteBackwardCharacterMergesCRLF() {
        let engine = EditorEngine(text: "a\r\nb", selections: [.caret(at: 3)])

        engine.delete(.backward, .character)

        #expect(engine.text == "ab")
        #expect(engine.selections == [.caret(at: 1)])
    }

    @Test func deleteByWordUsesUnicodeWordBoundaries() {
        let forward = EditorEngine(text: "hello world", selections: [.caret(at: 0)])
        forward.delete(.forward, .word)
        #expect(forward.text == " world")
        #expect(forward.selections == [.caret(at: 0)])

        let backward = EditorEngine(text: "hello world", selections: [.caret(at: 8)])
        backward.delete(.backward, .word)
        #expect(backward.text == "hello rld")
        #expect(backward.selections == [.caret(at: 6)])
    }

    @Test func deleteBackwardToLineStart() {
        let engine = EditorEngine(text: "one\ntwo\nthree", selections: [.caret(at: 6)])

        // 行中间：删到行首。
        engine.delete(.backward, .line)
        #expect(engine.text == "one\no\nthree")
        #expect(engine.selections == [.caret(at: 4)])
    }

    @Test func deleteBackwardAtLineStartRemovesTerminator() {
        let engine = EditorEngine(text: "one\n\nthree", selections: [.caret(at: 4)])

        engine.delete(.backward, .line)
        #expect(engine.text == "one\nthree")
        #expect(engine.selections == [.caret(at: 3)])
    }

    @Test func deleteForwardToLineContentEnd() {
        let engine = EditorEngine(text: "one\ntwo", selections: [.caret(at: 5)])

        engine.delete(.forward, .line)
        #expect(engine.text == "one\nt")
        #expect(engine.selections == [.caret(at: 5)])
    }

    @Test func deleteForwardAtLineEndRemovesTerminator() {
        let engine = EditorEngine(text: "one\ntwo", selections: [.caret(at: 3)])

        engine.delete(.forward, .line)
        #expect(engine.text == "onetwo")
        #expect(engine.selections == [.caret(at: 3)])
    }

    @Test func deleteLineHandlesCRLFAsSingleTerminator() {
        let backward = EditorEngine(text: "one\r\ntwo", selections: [.caret(at: 5)])
        backward.delete(.backward, .line)
        #expect(backward.text == "onetwo")
        #expect(backward.selections == [.caret(at: 3)])

        let forward = EditorEngine(text: "one\r\ntwo", selections: [.caret(at: 3)])
        forward.delete(.forward, .line)
        #expect(forward.text == "onetwo")
        #expect(forward.selections == [.caret(at: 3)])
    }

    @Test func deleteAtDocumentBoundariesIsNoOp() {
        let engine = EditorEngine(text: "abc", selections: [.caret(at: 0)])
        var changes = 0
        engine.onChange = { _ in changes += 1 }

        engine.delete(.backward, .character)
        engine.delete(.backward, .word)
        engine.delete(.backward, .line)

        #expect(engine.text == "abc")
        #expect(engine.version == 0)
        #expect(!engine.isDirty)
        #expect(engine.history.undoCount == 0)
        #expect(changes == 0)

        engine.setSelections([.caret(at: 3)])
        engine.delete(.forward, .character)
        engine.delete(.forward, .word)
        engine.delete(.forward, .line)

        #expect(engine.text == "abc")
        #expect(engine.version == 0)
        #expect(engine.history.undoCount == 0)
        #expect(changes == 0)
    }

    // MARK: - 批量编辑

    @Test func batchEditsReportAppliedRanges() {
        let engine = EditorEngine(text: "abcdefgh", selections: [.caret(at: 0)])
        var changes: [EditorChange] = []
        engine.onChange = { changes.append($0) }

        let change = engine.apply(
            edits: [
                TextEdit(range: NSRange(location: 0, length: 1), replacement: "X"),
                TextEdit(range: NSRange(location: 4, length: 2), replacement: "Y"),
            ],
            selectionAfter: [.caret(at: 99)],
            origin: .paste
        )

        #expect(engine.text == "XbcdYgh")
        #expect(engine.selections == [.caret(at: 7)])
        #expect(engine.version == 1)
        #expect(engine.history.undoCount == 1)
        #expect(changes.count == 1)
        #expect(change?.origin == .paste)
        #expect(change?.applied.map(\.rangeInResult) == [
            NSRange(location: 0, length: 1),
            NSRange(location: 4, length: 1),
        ])
        #expect(change?.applied.map(\.removedText) == ["a", "ef"])
        #expect(change?.selectionAfter == [.caret(at: 7)])
    }

    @Test func invalidBatchLeavesStateUntouched() {
        let engine = EditorEngine(text: "abc", selections: [.caret(at: 1)])
        var changes = 0
        engine.onChange = { _ in changes += 1 }

        let invalidBatches: [[TextEdit]] = [
            // 越界
            [TextEdit(range: NSRange(location: 2, length: 2), replacement: "")],
            // 乱序
            [
                TextEdit(range: NSRange(location: 2, length: 0), replacement: "x"),
                TextEdit(range: NSRange(location: 1, length: 0), replacement: "y"),
            ],
            // 重叠
            [
                TextEdit(range: NSRange(location: 0, length: 2), replacement: "x"),
                TextEdit(range: NSRange(location: 1, length: 1), replacement: "y"),
            ],
            // 空操作
            [TextEdit(range: NSRange(location: 0, length: 0), replacement: "")],
        ]

        for batch in invalidBatches {
            #expect(engine.apply(edits: batch) == nil)
        }

        #expect(engine.text == "abc")
        #expect(engine.version == 0)
        #expect(engine.history.undoCount == 0)
        #expect(!engine.isDirty)
        #expect(engine.selections == [.caret(at: 1)])
        #expect(changes == 0)
    }

    @Test func zeroLengthEditAtSelectionStartStaysOrdered() {
        // 光标与以同一位置开头的选区同时存在时，零长插入必须先应用。
        let engine = EditorEngine(
            text: "abcd",
            selections: [
                .caret(at: 2),
                TextSelection(range: NSRange(location: 2, length: 1)),
            ]
        )

        engine.insertText("X")

        #expect(engine.text == "abXXd")
        // 两个选区都落在最后一个相交编辑的替换末尾，随后被去重为一个光标。
        #expect(engine.selections == [.caret(at: 4)])
    }

    // MARK: - 撤销 / 重做

    @Test func undoRedoRestoresTextAndSelections() {
        let engine = EditorEngine(text: "abc", selections: [.caret(at: 2)])

        engine.insertText("X")
        #expect(engine.text == "abXc")
        #expect(engine.selections == [.caret(at: 3)])

        #expect(engine.undo())
        #expect(engine.text == "abc")
        #expect(engine.selections == [.caret(at: 2)])
        #expect(engine.isDirty)
        #expect(engine.canRedo)
        #expect(!engine.canUndo)

        #expect(engine.redo())
        #expect(engine.text == "abXc")
        #expect(engine.selections == [.caret(at: 3)])
        #expect(engine.canUndo)
        #expect(!engine.canRedo)
        #expect(!engine.redo())
    }

    @Test func newEditClearsRedo() {
        let engine = EditorEngine(text: "abc", selections: [.caret(at: 0)])

        engine.insertText("a")
        #expect(engine.undo())
        #expect(engine.canRedo)

        engine.insertText("b")
        #expect(engine.text == "babc")
        #expect(!engine.canRedo)
        #expect(engine.canUndo)
    }

    @Test func multiCursorUndoIsOneStep() {
        let engine = EditorEngine(
            text: "abc\ndef",
            selections: [.caret(at: 0), .caret(at: 4)]
        )

        engine.insertText("X")
        #expect(engine.selections.count == 2)
        #expect(engine.history.undoCount == 1)

        #expect(engine.undo())
        #expect(engine.text == "abc\ndef")
        #expect(engine.selections == [.caret(at: 0), .caret(at: 4)])
    }

    // MARK: - 连续键入合并

    @Test func consecutiveTypingCoalescesIntoOneStep() {
        let clock = TestClock()
        let engine = EditorEngine(now: { clock.time })

        engine.insertText("a")
        clock.advance(0.1)
        engine.insertText("b")
        clock.advance(0.1)
        engine.insertText("c")

        #expect(engine.text == "abc")
        #expect(engine.history.undoCount == 1)

        #expect(engine.undo())
        #expect(engine.text == "")
        #expect(engine.selections == [.caret(at: 0)])

        #expect(engine.redo())
        #expect(engine.text == "abc")
        #expect(engine.selections == [.caret(at: 3)])
    }

    @Test func typingAfterCoalescingWindowIsSeparate() {
        let clock = TestClock()
        let engine = EditorEngine(now: { clock.time })

        engine.insertText("a")
        clock.advance(0.5)
        engine.insertText("b")

        #expect(engine.text == "ab")
        #expect(engine.history.undoCount == 2)

        #expect(engine.undo())
        #expect(engine.text == "a")
        #expect(engine.undo())
        #expect(engine.text == "")
    }

    @Test func newlineBreaksTypingCoalescing() {
        let clock = TestClock()
        let engine = EditorEngine(now: { clock.time })

        engine.insertText("a")
        clock.advance(0.1)
        engine.insertText("\n")
        clock.advance(0.1)
        engine.insertText("b")

        #expect(engine.text == "a\nb")
        #expect(engine.history.undoCount == 3)

        #expect(engine.undo())
        #expect(engine.text == "a\n")
        #expect(engine.undo())
        #expect(engine.text == "a")
        #expect(engine.undo())
        #expect(engine.text == "")
    }

    @Test func movingCaretBreaksTypingCoalescing() {
        let clock = TestClock()
        let engine = EditorEngine(now: { clock.time })

        engine.insertText("a")
        engine.setSelections([.caret(at: 0)])
        clock.advance(0.1)
        engine.insertText("b")

        #expect(engine.text == "ba")
        #expect(engine.history.undoCount == 2)

        #expect(engine.undo())
        #expect(engine.text == "a")
        #expect(engine.selections == [.caret(at: 0)])
    }

    @Test func multiCursorAndInputMethodTypingDoNotCoalesce() {
        let clock = TestClock()
        let multiCursor = EditorEngine(
            text: "ab",
            selections: [.caret(at: 0), .caret(at: 2)],
            now: { clock.time }
        )
        multiCursor.insertText("x")
        clock.advance(0.1)
        multiCursor.insertText("y")
        #expect(multiCursor.text == "xyabxy")
        #expect(multiCursor.history.undoCount == 2)

        let ime = EditorEngine(now: { clock.time })
        ime.replaceSelections(with: "a", origin: .inputMethod)
        clock.advance(0.1)
        ime.replaceSelections(with: "b", origin: .inputMethod)
        #expect(ime.text == "ab")
        #expect(ime.history.undoCount == 2)
    }

    // MARK: - 脏状态与文档生命周期

    @Test func dirtyStateIsMonotonicUntilSaveOrLoad() {
        let engine = EditorEngine(text: "abc")
        #expect(!engine.isDirty)

        engine.insertText("x")
        #expect(engine.isDirty)

        engine.undo()
        #expect(engine.isDirty)

        engine.markSaved()
        #expect(!engine.isDirty)

        engine.redo()
        #expect(engine.isDirty)

        engine.load(text: "dirty", markClean: false)
        #expect(engine.isDirty)
        #expect(!engine.canUndo)
        #expect(!engine.canRedo)

        engine.load(text: "clean", markClean: true)
        #expect(!engine.isDirty)
    }

    @Test func loadResetsHistoryCachesAndComposition() {
        let engine = EditorEngine(text: "abc")
        engine.insertText("x")
        _ = engine.text
        #expect(engine.history.undoCount == 1)
        #expect(engine.fullTextBuildCount == 1)

        engine.load(text: "one\ntwo", selections: [.caret(at: 99)], markClean: false)

        #expect(engine.text == "one\ntwo")
        #expect(engine.selections == [.caret(at: 7)])
        #expect(engine.version == 0)
        #expect(engine.history.undoCount == 0)
        #expect(engine.history.redoCount == 0)
        #expect(!engine.canUndo)
        #expect(engine.isDirty)
        #expect(engine.fullTextBuildCount == 1)
        #expect(engine.composition == nil)
    }

    @Test func frozenEngineRejectsEditingButAllowsSelection() {
        let engine = EditorEngine(text: "abc")
        engine.isEditable = false

        #expect(engine.apply(edits: [
            TextEdit(range: NSRange(location: 1, length: 0), replacement: "x")
        ]) == nil)
        engine.insertText("x")
        engine.delete(.backward, .character)
        #expect(!engine.undo())
        #expect(!engine.redo())

        #expect(engine.text == "abc")
        #expect(!engine.isDirty)
        #expect(engine.history.undoCount == 0)

        #expect(engine.setSelections([.caret(at: 2)]))
        #expect(engine.selections == [.caret(at: 2)])

        engine.isEditable = true
        engine.insertText("x")
        #expect(engine.text == "abxc")
    }

    // MARK: - 全文缓存

    @Test func fullTextCacheIsMaintainedIncrementally() {
        let engine = EditorEngine(text: "hello")
        #expect(engine.fullTextBuildCount == 0)

        #expect(engine.text == "hello")
        #expect(engine.fullTextBuildCount == 1)

        engine.insertText("!")
        engine.delete(.backward, .character)
        engine.replace(range: NSRange(location: 0, length: 1), with: "H")

        #expect(engine.text == "Hello")
        #expect(engine.fullTextBuildCount == 1)

        #expect(engine.undo())
        #expect(engine.text == "hello")
        #expect(engine.fullTextBuildCount == 1)
    }

    // MARK: - 输入法

    @Test func compositionCommitsToPrimarySelectionOnly() {
        let engine = EditorEngine(
            text: "hello",
            selections: [.caret(at: 1), .caret(at: 4)]
        )
        var changes: [EditorChange] = []
        engine.onChange = { changes.append($0) }

        engine.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        #expect(engine.isComposing)
        #expect(engine.text == "hello")
        #expect(engine.version == 0)

        engine.setMarkedText("にほ", selectedRange: NSRange(location: 0, length: 2))
        #expect(engine.composition?.baseSelections == [.caret(at: 1), .caret(at: 4)])

        engine.commitComposition("日本")

        #expect(!engine.isComposing)
        #expect(engine.text == "hell日本o")
        #expect(engine.selections == [.caret(at: 1), .caret(at: 6)])
        #expect(engine.history.undoCount == 1)
        #expect(changes.count == 1)
        #expect(changes.first?.origin == .inputMethod)

        #expect(engine.undo())
        #expect(engine.text == "hello")
        #expect(engine.selections == [.caret(at: 1), .caret(at: 4)])
    }

    @Test func cancellingCompositionLeavesTextUntouched() {
        let engine = EditorEngine(text: "abc", selections: [.caret(at: 1)])

        engine.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        engine.unmarkText()

        #expect(!engine.isComposing)
        #expect(engine.text == "abc")
        #expect(engine.version == 0)
        #expect(!engine.isDirty)
        #expect(!engine.canUndo)
    }

    @Test func pendingInputCommitsBeforeSnapshot() {
        let engine = EditorEngine(text: "ab", selections: [.caret(at: 1)])
        engine.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0))

        #expect(engine.prepareForSnapshot() == "a中b")
        #expect(!engine.isComposing)
        #expect(engine.text == "a中b")
        #expect(engine.history.undoCount == 1)
        #expect(engine.history.undoEntries.first?.origin == .inputMethod)
    }

    @Test func emptyMarkedTextIsCancelledByPendingCommit() {
        let engine = EditorEngine(text: "abc", selections: [.caret(at: 1)])
        engine.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        #expect(engine.isComposing)

        engine.commitPendingInput()
        #expect(!engine.isComposing)
        #expect(engine.text == "abc")
        #expect(engine.version == 0)
    }

    @Test func compositionHonorsExplicitReplacementRange() {
        let engine = EditorEngine(text: "abcdef", selections: [.caret(at: 2)])
        engine.setMarkedText(
            "x",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: 2, length: 3)
        )

        engine.commitComposition("XY")

        #expect(engine.text == "abXYf")
        #expect(engine.selections == [.caret(at: 4)])
        #expect(engine.history.undoCount == 1)
    }

    @Test func insertTextWhileComposingCommitsMarkedText() {
        let engine = EditorEngine(text: "ab", selections: [.caret(at: 1)])
        engine.setMarkedText("か", selectedRange: NSRange(location: 0, length: 0))

        engine.insertText("中")

        #expect(!engine.isComposing)
        #expect(engine.text == "a中b")
        #expect(engine.history.undoCount == 1)
    }

    // MARK: - 随机编辑

    @Test func randomEditsRoundTripThroughUndoAndRedo() {
        var rng = SeededGenerator(seed: 0x5EED)
        let original = "abc\ndef\r\nghi 中文 😀\u{2028}end"
        let engine = EditorEngine(text: original)
        var reference = original as NSString
        let replacements = ["", "x", "中", "😀", "\n", "\r\n", "ab\ncd"]
        var appliedCount = 0

        for _ in 0..<50 {
            let bounds = characterBoundaries(of: reference)
            let startIndex = Int(rng.next() % UInt64(bounds.count))
            let endIndex = min(
                bounds.count - 1,
                startIndex + Int(rng.next() % 4)
            )
            let range = NSRange(
                location: bounds[startIndex],
                length: bounds[endIndex] - bounds[startIndex]
            )
            let replacement = replacements[
                Int(rng.next() % UInt64(replacements.count))
            ]
            if range.length == 0 && replacement.isEmpty { continue }

            let change = engine.replace(range: range, with: replacement)
            #expect(change != nil, "编辑应成功：\(range) -> \(replacement)")

            reference = reference.replacingCharacters(
                in: range,
                with: replacement
            ) as NSString
            let expected = reference as String
            #expect(engine.text == expected)
            for selection in engine.selections {
                #expect(selection.range.location >= 0)
                #expect(selection.range.location + selection.range.length <= engine.length)
            }
            appliedCount += 1
        }

        #expect(appliedCount > 0)
        #expect(engine.fullTextBuildCount == 1)

        while engine.undo() {}
        #expect(engine.text == original)

        while engine.redo() {}
        let finalText = reference as String
        #expect(engine.text == finalText)
        #expect(engine.history.undoCount == appliedCount)
    }

    // MARK: - 工具

    /// 按 grapheme cluster 取边界，避免随机测试切开 surrogate pair。
    private func characterBoundaries(of text: NSString) -> [Int] {
        var result = [0]
        var index = 0
        while index < text.length {
            let range = text.rangeOfComposedCharacterSequence(at: index)
            guard range.length > 0 else { break }
            index = range.location + range.length
            result.append(index)
        }
        return result
    }
}

private final class TestClock {
    var time: TimeInterval = 0

    func advance(_ interval: TimeInterval) {
        time += interval
    }
}
