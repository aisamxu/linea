import AppKit
import Foundation
import LineaCore
import Testing
@testable import LineaTextUI

/// Phase 4：输入法组合文本、候选窗定位与提交边界。
@Suite("LineaTextViewInputMethod", .serialized)
@MainActor
struct LineaTextViewInputMethodTests {
    private func makeView(
        _ text: String,
        selections: [TextSelection] = [.caret(at: 0)]
    ) -> LineaTextView {
        let view = LineaTextView(
            engine: EditorEngine(text: text, selections: selections)
        )
        view.setViewportWidth(900)
        view.updateDocumentFrame()
        view.isCaretVisible = true
        return view
    }

    private func mark(
        _ view: LineaTextView,
        _ text: String,
        selectedRange: NSRange = NSRange(location: 0, length: 0),
        replacementRange: NSRange = NSRange(location: NSNotFound, length: 0)
    ) {
        view.setMarkedText(
            text,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
    }

    // MARK: - 组合状态

    @Test func markedTextDoesNotTouchBuffer() {
        let view = makeView("ab", selections: [.caret(at: 1)])

        mark(
            view,
            "にほ",
            selectedRange: NSRange(location: 0, length: 2)
        )

        #expect(view.engine.text == "ab")
        #expect(view.engine.isComposing)
        #expect(view.hasMarkedText())
        #expect(view.engine.isDirty == false)
        #expect(view.engine.history.canUndo == false)
        #expect(view.markedRange() == NSRange(location: 1, length: 2))
        // 组合内选中整段 marked text。
        #expect(view.selectedRange() == NSRange(location: 1, length: 2))
    }

    @Test func emptyMarkedTextCancelsComposition() {
        let view = makeView("ab", selections: [.caret(at: 1)])
        mark(view, "か", selectedRange: NSRange(location: 1, length: 0))
        #expect(view.hasMarkedText())

        mark(view, "")

        #expect(view.engine.composition == nil)
        #expect(view.hasMarkedText() == false)
        #expect(view.engine.text == "ab")
        #expect(view.engine.isDirty == false)
    }

    @Test func unmarkTextLeavesBufferUntouched() {
        let view = makeView("ab", selections: [.caret(at: 1)])
        mark(view, "か", selectedRange: NSRange(location: 1, length: 0))

        view.unmarkText()

        #expect(view.engine.composition == nil)
        #expect(view.engine.text == "ab")
        #expect(view.engine.isDirty == false)
        #expect(view.engine.history.canUndo == false)
    }

    // MARK: - 提交

    @Test func commitReplacesOnlyPrimarySelectionAsOneUndoStep() {
        let view = makeView(
            "ab\ncd",
            selections: [.caret(at: 0), .caret(at: 3)]
        )
        mark(view, "に", selectedRange: NSRange(location: 1, length: 0))

        // 输入法最终提交走两参 insertText；一次事务、一条历史。
        view.insertText(
            "日本",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(view.engine.text == "ab\n日本cd")
        #expect(view.engine.selections == [.caret(at: 0), .caret(at: 5)])
        #expect(view.engine.history.canUndo)

        #expect(view.engine.undo())
        #expect(view.engine.text == "ab\ncd")
        #expect(view.engine.selections == [.caret(at: 0), .caret(at: 3)])
    }

    @Test func explicitReplacementRangeWinsOnCommit() {
        let view = makeView("abcdef", selections: [.caret(at: 0)])
        mark(
            view,
            "Z",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 2, length: 1)
        )
        #expect(view.markedRange() == NSRange(location: 2, length: 1))

        view.insertText(
            "Q",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(view.engine.text == "abQdef")
        // 原光标在 0，替换发生在 2..<3，光标不随编辑移动。
        #expect(view.engine.selections == [.caret(at: 0)])
    }

    @Test func commitPendingInputAndSnapshotCommitMarkedText() {
        let view = makeView("ab", selections: [.caret(at: 1)])
        mark(view, "中", selectedRange: NSRange(location: 1, length: 0))

        let snapshot = view.prepareForSnapshot()

        #expect(snapshot == "a中b")
        #expect(view.engine.text == "a中b")
        #expect(view.engine.composition == nil)
        #expect(view.engine.isDirty)
    }

    @Test func escapeCancelsCompositionInsteadOfCollapsingCursors() {
        let view = makeView(
            "alpha beta",
            selections: [.caret(at: 0), .caret(at: 6)]
        )
        mark(view, "か", selectedRange: NSRange(location: 1, length: 0))

        view.cancelOperation(nil)

        #expect(view.engine.composition == nil)
        #expect(view.engine.text == "alpha beta")
        // 多光标保持不变。
        #expect(view.engine.selections.count == 2)
    }

    @Test func undoAndRedoAreBlockedWhileComposing() {
        let view = makeView("abc", selections: [.caret(at: 1)])
        view.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(view.engine.text == "aXbc")

        mark(view, "か", selectedRange: NSRange(location: 1, length: 0))
        view.undo(nil)
        #expect(view.engine.text == "aXbc")
        #expect(view.hasMarkedText())

        view.unmarkText()
        view.undo(nil)
        #expect(view.engine.text == "abc")
    }

    // MARK: - 组合内移动与删除

    @Test func arrowsMoveInsideMarkedTextOnly() {
        let view = makeView("ab", selections: [.caret(at: 1)])
        mark(
            view,
            "abcd",
            selectedRange: NSRange(location: 4, length: 0)
        )

        view.moveLeft(nil)
        #expect(view.engine.composition?.selectedRange == NSRange(location: 3, length: 0))
        #expect(view.engine.text == "ab")

        view.moveToBeginningOfLine(nil)
        #expect(view.engine.composition?.selectedRange == NSRange(location: 0, length: 0))

        view.moveRightAndModifySelection(nil)
        view.moveRightAndModifySelection(nil)
        #expect(view.engine.composition?.selectedRange == NSRange(location: 0, length: 2))

        // Shift 反向移动回缩，锚点保持在 0。
        view.moveLeftAndModifySelection(nil)
        #expect(view.engine.composition?.selectedRange == NSRange(location: 0, length: 1))

        // 文档选区与文本完全不变。
        #expect(view.engine.selections == [.caret(at: 1)])
        #expect(view.engine.text == "ab")
    }

    @Test func deleteKeysEditMarkedTextNotDocument() {
        let view = makeView("ab", selections: [.caret(at: 1)])
        mark(
            view,
            "abc",
            selectedRange: NSRange(location: 3, length: 0)
        )

        view.deleteBackward(nil)
        #expect(view.engine.composition?.markedText == "ab")
        #expect(view.engine.composition?.selectedRange == NSRange(location: 2, length: 0))
        #expect(view.engine.text == "ab")

        view.deleteToBeginningOfLine(nil)
        #expect(view.engine.composition == nil)
        #expect(view.hasMarkedText() == false)
        #expect(view.engine.text == "ab")
        #expect(view.engine.isDirty == false)
    }

    @Test func forwardDeleteRemovesCharacterAfterCompositionSelection() {
        let view = makeView("ab", selections: [.caret(at: 1)])
        mark(
            view,
            "abcd",
            selectedRange: NSRange(location: 1, length: 0)
        )

        view.deleteForward(nil)

        // 删除组合选区后的一个字符（"abcd" 中的 b）。
        #expect(view.engine.composition?.markedText == "acd")
        #expect(view.engine.composition?.selectedRange == NSRange(location: 1, length: 0))
        #expect(view.engine.text == "ab")
    }

    // MARK: - 虚拟行与候选窗定位

    @Test func compositionLineSplicesMarkedTextIntoLine() {
        let view = makeView("abcdef", selections: [.caret(at: 2)])
        mark(
            view,
            "XY",
            selectedRange: NSRange(location: 0, length: 1)
        )

        guard let composition = view.engine.composition,
              let line = view.layoutEngine.compositionLine(for: composition)
        else {
            Issue.record("组合虚拟行缺失")
            return
        }

        #expect(line.lineNumber == 1)
        #expect(line.prefixLength == 2)
        #expect(line.markedLength == 2)
        #expect(line.selectedRange == NSRange(location: 0, length: 1))
        // marked 起点与原文光标位置一致，末尾向右推开后缀。
        #expect(
            abs(line.markedStartX - view.layoutEngine.x(forLine: 1, localOffset: 2)) < 0.01
        )
        #expect(line.markedEndX > line.markedStartX)
        // 组合内选中第一个字符，光标位于 marked 区间内部。
        #expect(line.caretX > line.markedStartX)
        #expect(line.caretX < line.markedEndX)
        // 虚拟行比原文宽出 marked text 的宽度。
        #expect(line.width > view.layoutEngine.layoutLine(number: 1).width)
    }

    @Test func compositionCaretFollowsInternalSelection() {
        let view = makeView("ab", selections: [.caret(at: 1)])
        mark(
            view,
            "XY",
            selectedRange: NSRange(location: 2, length: 0)
        )

        let baseCaret = view.layoutEngine.caretRect(for: 1)
        let candidateRect = view.firstRect(
            forCharacterRange: NSRange(location: NSNotFound, length: 0),
            actualRange: nil
        )
        #expect(candidateRect.width == 2)
        #expect(candidateRect.height == view.layoutEngine.lineHeight)
        // 组合光标在 marked text 末尾，应位于原文光标右侧。
        #expect(candidateRect.minX > baseCaret.minX)
    }

    @Test func compositionOverSelectionHidesOriginalSelectionGeometry() {
        let view = makeView(
            "hello",
            selections: [TextSelection(range: NSRange(location: 1, length: 3))]
        )
        mark(
            view,
            "X",
            selectedRange: NSRange(location: 1, length: 0)
        )

        guard let composition = view.engine.composition,
              let line = view.layoutEngine.compositionLine(for: composition)
        else {
            Issue.record("组合虚拟行缺失")
            return
        }
        #expect(line.prefixLength == 1)
        #expect(line.markedLength == 1)
        #expect(line.caretX == line.markedEndX)
        // 组合仍在文档原位置，buffer 未变。
        #expect(view.engine.text == "hello")
    }

    @Test func rendererDrawsCompositionWithoutTouchingBuffer() {
        let view = makeView("abcdef", selections: [.caret(at: 2)])
        mark(
            view,
            "XY",
            selectedRange: NSRange(location: 1, length: 0)
        )

        guard let context = CGContext(
            data: nil,
            width: 900,
            height: 600,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("无法创建绘制 context")
            return
        }

        let renderer = TextRenderer(theme: .standard)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            renderer.draw(
                in: context,
                dirtyRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                layout: view.layoutEngine,
                selections: view.engine.selections,
                caretVisible: true,
                composition: view.engine.composition
            )
        }

        #expect(view.engine.text == "abcdef")
        #expect(view.engine.isDirty == false)
    }
}
