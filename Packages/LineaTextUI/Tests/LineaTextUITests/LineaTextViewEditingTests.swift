import AppKit
import Foundation
import LineaCore
import Testing
@testable import LineaTextUI

/// Phase 3：视图与引擎接线的编辑行为。
///
/// 串行执行，避免剪贴板等全局状态互相干扰。
@Suite("LineaTextViewEditing", .serialized)
@MainActor
struct LineaTextViewEditingTests {
    private func makeView(
        _ text: String,
        selections: [TextSelection] = [.caret(at: 0)]
    ) -> LineaTextView {
        LineaTextView(engine: EditorEngine(text: text, selections: selections))
    }

    private func point(at offset: Int, in view: LineaTextView) -> CGPoint {
        let rect = view.layoutEngine.caretRect(for: offset)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: - 插入

    @Test func insertingTextReplacesCaretsAndSelections() {
        let view = makeView("abc\ndef", selections: [.caret(at: 4)])
        view.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(view.engine.text == "abc\nXdef")
        #expect(view.engine.selections == [.caret(at: 5)])

        let selected = makeView(
            "abc",
            selections: [TextSelection(range: NSRange(location: 0, length: 2))]
        )
        selected.insertText(
            "Z",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(selected.engine.text == "Zc")
        #expect(selected.engine.selections == [.caret(at: 1)])
    }

    @Test func typingUpdatesDocumentHeightAndCallback() {
        let view = makeView("one", selections: [.caret(at: 3)])
        var changes: [EditorChange] = []
        view.onChange = { changes.append($0) }

        view.insertNewline(nil)

        #expect(view.engine.text == "one\n")
        #expect(view.engine.lineCount == 2)
        #expect(view.frame.height == view.layoutEngine.lineHeight * 2)
        #expect(changes.count == 1)
        #expect(changes[0].origin == .typing)
        #expect(view.engine.isDirty)
    }

    @Test func specialInsertionsUseDocumentedCharacters() {
        let view = makeView("")

        view.insertLineBreak(nil)
        #expect(view.engine.text == "\u{2028}")

        view.insertParagraphSeparator(nil)
        #expect(view.engine.text == "\u{2028}\u{2029}")

        view.insertTab(nil)
        #expect(view.engine.text == "\u{2028}\u{2029}\t")

        view.insertBacktab(nil)
        #expect(view.engine.text == "\u{2028}\u{2029}\t\u{0019}")
    }

    @Test func multiCursorTypingIsOneUndoStep() {
        let view = makeView(
            "ab\ncd",
            selections: [.caret(at: 0), .caret(at: 3)]
        )
        view.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(view.engine.text == "Xab\nXcd")
        #expect(view.engine.selections == [.caret(at: 1), .caret(at: 5)])

        // 一次按键无论多少光标，只产生一个历史条目。
        #expect(view.engine.history.canUndo)
        #expect(view.engine.undo())
        #expect(view.engine.text == "ab\ncd")
        #expect(!view.engine.history.canUndo)
    }

    // MARK: - 删除

    @Test func deletionsCoverCharacterWordAndLine() {
        let backward = makeView("abcd", selections: [.caret(at: 2)])
        backward.deleteBackward(nil)
        #expect(backward.engine.text == "acd")
        #expect(backward.engine.selections == [.caret(at: 1)])

        let forward = makeView("abcd", selections: [.caret(at: 2)])
        forward.deleteForward(nil)
        #expect(forward.engine.text == "abd")
        #expect(forward.engine.selections == [.caret(at: 2)])

        let word = makeView("foo bar", selections: [.caret(at: 7)])
        word.deleteWordBackward(nil)
        #expect(word.engine.text == "foo ")
        #expect(word.engine.selections == [.caret(at: 4)])

        let line = makeView("abc\ndef", selections: [.caret(at: 6)])
        line.deleteToBeginningOfLine(nil)
        #expect(line.engine.text == "abc\nf")
        #expect(line.engine.selections == [.caret(at: 4)])

        let lineEnd = makeView("abc\ndef", selections: [.caret(at: 1)])
        lineEnd.deleteToEndOfLine(nil)
        #expect(lineEnd.engine.text == "a\ndef")
        #expect(lineEnd.engine.selections == [.caret(at: 1)])
    }

    @Test func deleteRemovesSelectionsAndBackspaceAtLineStartJoinsLines() {
        let selection = makeView(
            "abcdef",
            selections: [TextSelection(range: NSRange(location: 1, length: 3))]
        )
        selection.delete(nil)
        #expect(selection.engine.text == "aef")
        #expect(selection.engine.selections == [.caret(at: 1)])

        // 行首退格吃掉上一行终止符，CRLF 作为整体删除。
        let joined = makeView("ab\r\ncd", selections: [.caret(at: 4)])
        joined.deleteBackward(nil)
        #expect(joined.engine.text == "abcd")
        #expect(joined.engine.selections == [.caret(at: 2)])
    }

    // MARK: - 移动与选择

    @Test func characterWordAndLineMovements() {
        let view = makeView("abc def\nghi", selections: [.caret(at: 0)])
        view.moveRight(nil)
        #expect(view.engine.selections == [.caret(at: 1)])

        view.moveWordRight(nil)
        #expect(view.engine.selections == [.caret(at: 3)])
        view.moveWordRight(nil)
        #expect(view.engine.selections == [.caret(at: 7)])
        view.moveWordLeft(nil)
        #expect(view.engine.selections == [.caret(at: 4)])

        view.moveToEndOfLine(nil)
        #expect(view.engine.selections == [.caret(at: 7)])
        view.moveToBeginningOfLine(nil)
        #expect(view.engine.selections == [.caret(at: 0)])
        view.moveToEndOfDocument(nil)
        #expect(view.engine.selections == [.caret(at: 11)])
        view.moveToBeginningOfDocument(nil)
        #expect(view.engine.selections == [.caret(at: 0)])
    }

    @Test func movementCollapsesSelectionInsteadOfMovingFurther() {
        let view = makeView(
            "hello world",
            selections: [TextSelection(range: NSRange(location: 2, length: 4))]
        )
        view.moveLeft(nil)
        #expect(view.engine.selections == [.caret(at: 2)])

        let right = makeView(
            "hello",
            selections: [TextSelection(range: NSRange(location: 1, length: 2))]
        )
        right.moveRight(nil)
        #expect(right.engine.selections == [.caret(at: 3)])
    }

    @Test func shiftMovementExtendsFromExistingSelection() {
        let view = makeView("hello", selections: [.caret(at: 2)])
        view.moveLeftAndModifySelection(nil)
        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 1, length: 1))
        ])
        view.moveLeftAndModifySelection(nil)
        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 0, length: 2))
        ])
        view.moveRightAndModifySelection(nil)
        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 1, length: 1))
        ])
    }

    @Test func verticalMovementKeepsOriginalColumn() {
        let view = makeView(
            "abcdef\nxy\nabcdef",
            selections: [.caret(at: 3)]
        )
        view.moveDown(nil)
        // 第二行更短，光标夹到行尾。
        #expect(view.engine.selections == [.caret(at: 9)])
        view.moveDown(nil)
        // 继续使用第一次的 x 锚点（3 列），而不是被短行压到 2 列。
        #expect(view.engine.selections == [.caret(at: 13)])

        view.moveUp(nil)
        #expect(view.engine.selections == [.caret(at: 9)])
    }

    @Test func selectAllWordAndLine() {
        let view = makeView("alpha beta\ngamma", selections: [.caret(at: 1)])

        view.selectWord(nil)
        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 0, length: 5))
        ])

        view.selectLine(nil)
        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 0, length: 10))
        ])

        view.selectAll(nil)
        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 0, length: 16))
        ])

        view.moveRight(nil)
        // 有选区时方向键只折叠。
        #expect(view.engine.selections == [.caret(at: 16)])
    }

    // MARK: - 鼠标

    @Test func clickAndDragSelectText() {
        let view = makeView("alpha\nbeta\ngamma")

        view.select(at: point(at: 2, in: view))
        #expect(view.engine.selections == [.caret(at: 2)])

        view.select(at: point(at: 2, in: view), clickCount: 2)
        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 0, length: 5))
        ])

        view.select(at: point(at: 7, in: view), clickCount: 3)
        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 6, length: 4))
        ])

        view.select(at: point(at: 1, in: view))
        view.select(
            at: point(at: 4, in: view),
            modifiers: .shift
        )
        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 1, length: 3))
        ])
    }

    @Test func commandClickAddsAndRemovesCursors() {
        let view = makeView("alpha beta")
        view.select(at: point(at: 0, in: view))
        view.select(at: point(at: 3, in: view), modifiers: .command)
        #expect(view.engine.selections == [.caret(at: 0), .caret(at: 3)])

        view.select(at: point(at: 3, in: view), modifiers: .command)
        #expect(view.engine.selections == [.caret(at: 0)])

        // 最后一个光标不能被移除。
        view.select(at: point(at: 0, in: view), modifiers: .command)
        #expect(view.engine.selections == [.caret(at: 0)])
    }

    @Test func shiftControlClickAppendsCursor() {
        let view = makeView("alpha beta")
        view.select(
            at: point(at: 6, in: view),
            modifiers: [.shift, .control]
        )
        #expect(view.engine.selections == [.caret(at: 0), .caret(at: 6)])
    }

    @Test func optionClickAddsAndRemovesCursors() {
        let view = makeView("alpha beta")
        view.select(at: point(at: 0, in: view))
        view.select(at: point(at: 3, in: view), modifiers: .option)
        #expect(view.engine.selections == [.caret(at: 0), .caret(at: 3)])

        view.select(at: point(at: 3, in: view), modifiers: .option)
        #expect(view.engine.selections == [.caret(at: 0)])
    }

    @Test func shiftOptionClickAppendsCursorWithoutToggling() {
        let view = makeView("alpha beta")
        view.select(
            at: point(at: 6, in: view),
            modifiers: [.shift, .option]
        )
        #expect(view.engine.selections == [.caret(at: 0), .caret(at: 6)])

        // Shift+Option 只追加：再次点击同一位置不会移除光标。
        view.select(
            at: point(at: 6, in: view),
            modifiers: [.shift, .option]
        )
        #expect(view.engine.selections == [.caret(at: 0), .caret(at: 6)])
    }

    @Test func escapeCollapsesSelectionsToPrimary() {
        let view = makeView("alpha beta alpha")
        view.select(at: point(at: 1, in: view), clickCount: 2)
        view.selectNextOccurrence()
        #expect(view.engine.selections.count == 2)

        view.cancelOperation(nil)
        #expect(view.engine.selections.count == 1)
        #expect(view.engine.selections.last?.range.length ?? 0 > 0)
    }

    // MARK: - 剪贴板

    @Test func copyCutAndPasteUsePlainText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let view = makeView(
            "abcdef",
            selections: [TextSelection(range: NSRange(location: 1, length: 3))]
        )
        view.copy(nil)
        #expect(pasteboard.string(forType: .string) == "bcd")

        view.cut(nil)
        #expect(view.engine.text == "aef")
        #expect(pasteboard.string(forType: .string) == "bcd")

        view.select(at: point(at: 3, in: view))
        view.paste(nil)
        #expect(view.engine.text == "aefbcd")

        pasteboard.clearContents()
    }

    @Test func multiSelectionCopyJoinsWithNewlines() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let view = makeView(
            "abc\ndef",
            selections: [
                TextSelection(range: NSRange(location: 2, length: 1)),
                TextSelection(range: NSRange(location: 4, length: 3)),
            ]
        )
        #expect(view.selectedText == "c\ndef")
        view.copy(nil)
        #expect(pasteboard.string(forType: .string) == "c\ndef")

        pasteboard.clearContents()
    }

    // MARK: - 多光标命令

    @Test func selectNextAndAllOccurrences() {
        let view = makeView("foo foo foo", selections: [.caret(at: 0)])

        let first = view.selectNextOccurrence()
        #expect(first == .updated([
            TextSelection(range: NSRange(location: 0, length: 3))
        ]))
        #expect(view.engine.selections.count == 1)

        view.selectNextOccurrence()
        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 0, length: 3)),
            TextSelection(range: NSRange(location: 4, length: 3)),
        ])

        view.selectAllOccurrences()
        #expect(view.engine.selections.count == 3)

        view.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(view.engine.text == "X X X")
        #expect(view.engine.selections == [
            .caret(at: 1), .caret(at: 3), .caret(at: 5),
        ])
    }

    @Test func addCursorsToSelectedLinesUsesUnifiedLineIndex() {
        let view = makeView(
            "a\nb\nc",
            selections: [TextSelection(range: NSRange(location: 0, length: 3))]
        )
        let result = view.addCursorsToSelectedLines()
        #expect(result == .updated([.caret(at: 1), .caret(at: 3)]))
        #expect(view.engine.selections == [.caret(at: 1), .caret(at: 3)])
    }

    // MARK: - 撤销与冻结

    @Test func undoAndRedoRestoreTextAndSelections() {
        let view = makeView("abc", selections: [.caret(at: 1)])
        view.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(view.engine.text == "aXbc")

        view.undo(nil)
        #expect(view.engine.text == "abc")
        #expect(view.engine.selections == [.caret(at: 1)])

        view.redo(nil)
        #expect(view.engine.text == "aXbc")
        #expect(view.engine.selections == [.caret(at: 2)])
    }

    @Test func editingFrozenRejectsTextChangesButAllowsMovement() {
        let view = makeView("abc", selections: [.caret(at: 0)])
        view.isEditable = false

        view.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        view.deleteBackward(nil)
        #expect(view.engine.text == "abc")

        view.moveRight(nil)
        #expect(view.engine.selections == [.caret(at: 1)])

        view.isEditable = true
        view.insertText(
            "Y",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(view.engine.text == "aYbc")
    }

    @Test func validateMenuItemReflectsSelectionAndHistory() {
        let view = makeView("abc", selections: [.caret(at: 0)])

        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(LineaTextView.copy(_:)),
            keyEquivalent: ""
        )
        #expect(!view.validateUserInterfaceItem(copyItem))

        view.selectAll(nil)
        #expect(view.validateUserInterfaceItem(copyItem))

        let undoItem = NSMenuItem(
            title: "Undo",
            action: #selector(LineaTextView.undo(_:)),
            keyEquivalent: ""
        )
        #expect(!view.validateUserInterfaceItem(undoItem))
        view.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(view.validateUserInterfaceItem(undoItem))
    }

    // MARK: - 超长行

    @Test func editingAtEndOfMillionCharacterLine() {
        let text = String(repeating: "a", count: 1_000_000)
        let view = makeView(text, selections: [.caret(at: text.utf16.count)])

        view.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(view.engine.length == 1_000_001)
        #expect(view.engine.lineCount == 1)
        #expect(view.engine.selections == [.caret(at: 1_000_001)])
        #expect(view.frame.height == view.layoutEngine.lineHeight)
    }

    // MARK: - 选区同步

    @Test func selectionsFlowThroughEngine() {
        let view = makeView("alpha\nbeta")
        view.setSelections([
            .caret(at: 2),
            TextSelection(range: NSRange(location: 6, length: 4)),
        ])
        #expect(view.engine.selections == view.selections)
        #expect(view.selections.last?.range.length == 4)
    }

    // 键位事件经 NSTextInputContext 分发，无法在无 App 事件循环的 SPM 测试中稳定模拟；
    // 命令层与插入层分别由上面的直接调用覆盖，真实键入在 Phase 5 App 集成时人工验收。
}
