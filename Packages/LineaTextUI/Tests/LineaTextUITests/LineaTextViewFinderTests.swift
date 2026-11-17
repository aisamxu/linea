import AppKit
import Foundation
import LineaCore
import Testing
@testable import LineaTextUI

/// Phase 4：NSTextFinder 客户端契约与 Replace All 单条撤销。
@Suite("LineaTextViewFinder", .serialized)
@MainActor
struct LineaTextViewFinderTests {
    private func makeView(
        _ text: String,
        selections: [TextSelection] = [.caret(at: 0)]
    ) -> LineaTextView {
        let view = LineaTextView(
            engine: EditorEngine(text: text, selections: selections)
        )
        view.setViewportWidth(900)
        view.updateDocumentFrame()
        return view
    }

    // MARK: - 读取

    @Test func exposesStringAndSelection() {
        let view = makeView(
            "alpha\nbeta",
            selections: [TextSelection(range: NSRange(location: 6, length: 4))]
        )

        #expect(view.string == "alpha\nbeta")
        #expect(view.stringLength() == 10)
        #expect(view.substring(with: NSRange(location: 0, length: 5)) == "alpha")
        #expect(view.substring(with: NSRange(location: 20, length: 1)).isEmpty)
        #expect(view.firstSelectedRange == NSRange(location: 6, length: 4))
        #expect(view.isSelectable)
        #expect(view.allowsMultipleSelection)
    }

    @Test func selectedRangesRoundTripThroughEngine() {
        let view = makeView("alpha\nbeta\ngamma")

        view.selectedRanges = [
            NSValue(range: NSRange(location: 11, length: 5)),
            NSValue(range: NSRange(location: 0, length: 5)),
        ]

        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 0, length: 5)),
            TextSelection(range: NSRange(location: 11, length: 5)),
        ])
        #expect(view.selectedRanges.map(\.rangeValue) == [
            NSRange(location: 0, length: 5),
            NSRange(location: 11, length: 5),
        ])
    }

    @Test func contentViewAndRectsCoverDocument() {
        let view = makeView("alpha\nbeta")
        var effective = NSRange(location: NSNotFound, length: 0)

        let content = view.contentView(at: 3, effectiveRange: &effective)

        #expect(content === view)
        #expect(effective == NSRange(location: 0, length: 10))

        let rects = view.rects(
            forCharacterRange: NSRange(location: 0, length: 5)
        )
        #expect(rects?.count == 1)
        #expect((rects?.first?.rectValue.width ?? 0) > 0)

        let caret = view.rects(forCharacterRange: NSRange(location: 3, length: 0))
        #expect(caret?.count == 1)
        #expect(caret?.first?.rectValue.height == view.layoutEngine.lineHeight)

        #expect(
            view.rects(forCharacterRange: NSRange(location: 100, length: 1)) == nil
        )
    }

    @Test func visibleCharacterRangesCoverWholeDocumentWithoutScrollView() {
        let view = makeView("aa\nbb\ncc")
        let ranges = view.visibleCharacterRanges.map(\.rangeValue)
        #expect(ranges.count == 1)
        #expect(ranges.first?.location == 0)
        #expect((ranges.first?.location ?? 0) + (ranges.first?.length ?? 0) == view.engine.length)
    }

    // MARK: - 替换

    @Test func replaceAllBatchesIntoOneUndoStep() {
        let view = makeView("foo foo foo")

        // NSTextFinder 从最后一个匹配向第一个回调。
        #expect(view.shouldReplaceCharacters(
            inRanges: [NSValue(range: NSRange(location: 8, length: 3))],
            with: ["bar"]
        ))
        view.replaceCharacters(
            in: NSRange(location: 8, length: 3),
            with: "bar"
        )
        view.replaceCharacters(
            in: NSRange(location: 4, length: 3),
            with: "baz"
        )
        view.replaceCharacters(
            in: NSRange(location: 0, length: 3),
            with: "qux"
        )

        // 收尾前不改文本，保证后续查找范围仍然有效。
        #expect(view.engine.text == "foo foo foo")

        view.didReplaceCharacters()

        #expect(view.engine.text == "qux baz bar")
        #expect(view.engine.history.undoCount == 1)

        #expect(view.engine.undo())
        #expect(view.engine.text == "foo foo foo")
        #expect(view.engine.history.canUndo == false)

        #expect(view.engine.redo())
        #expect(view.engine.text == "qux baz bar")
    }

    @Test func singleReplaceWorksWithoutTextFinderBatch() {
        let view = makeView("abc")

        view.replaceCharacters(in: NSRange(location: 1, length: 1), with: "X")
        view.didReplaceCharacters()

        #expect(view.engine.text == "aXc")
        #expect(view.engine.history.undoCount == 1)
    }

    @Test func replaceRejectedWhenFrozenOrRangesInvalid() {
        let view = makeView("abc")
        view.isEditable = false

        #expect(!view.shouldReplaceCharacters(
            inRanges: [NSValue(range: NSRange(location: 0, length: 1))],
            with: ["X"]
        ))
        view.replaceCharacters(in: NSRange(location: 0, length: 1), with: "X")
        view.didReplaceCharacters()
        #expect(view.engine.text == "abc")

        view.isEditable = true
        #expect(!view.shouldReplaceCharacters(
            inRanges: [NSValue(range: NSRange(location: 100, length: 1))],
            with: ["X"]
        ))
        // 数量不匹配也拒绝。
        #expect(!view.shouldReplaceCharacters(
            inRanges: [NSValue(range: NSRange(location: 0, length: 1))],
            with: []
        ))
    }

    @Test func replaceCommitsPendingCompositionFirst() {
        let view = makeView("ab", selections: [.caret(at: 1)])
        view.setMarkedText(
            "か",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        view.replaceCharacters(in: NSRange(location: 0, length: 1), with: "X")
        view.didReplaceCharacters()

        // 组合先提交为「aかb」，再替换原范围 0..<1。
        #expect(view.engine.text == "Xかb")
        #expect(view.engine.composition == nil)
    }
}
