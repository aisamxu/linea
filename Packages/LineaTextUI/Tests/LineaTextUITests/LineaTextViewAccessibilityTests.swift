import AppKit
import Foundation
import LineaCore
import Testing
@testable import LineaTextUI

/// Phase 4：自绘文本视图的 AX 文本区契约。
@Suite("LineaTextViewAccessibility", .serialized)
@MainActor
struct LineaTextViewAccessibilityTests {
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

    // MARK: - 基础属性

    @Test func exposesTextAreaRoleAndValue() {
        let view = makeView("alpha\nbeta")

        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .textArea)
        #expect(view.accessibilityValue() as? String == "alpha\nbeta")
        #expect(view.accessibilityNumberOfCharacters() == 10)
    }

    @Test func exposesSelectionAndInsertionLine() {
        let view = makeView(
            "alpha\nbeta\ngamma",
            selections: [
                .caret(at: 1),
                TextSelection(range: NSRange(location: 6, length: 4)),
            ]
        )

        #expect(view.accessibilitySelectedText() == "beta")
        #expect(view.accessibilitySelectedTextRange() == NSRange(location: 6, length: 4))

        let ranges = view.accessibilitySelectedTextRanges()?
            .map(\.rangeValue)
        #expect(ranges == [
            NSRange(location: 1, length: 0),
            NSRange(location: 6, length: 4),
        ])
        // AX 行号从 0 开始。
        #expect(view.accessibilityInsertionPointLineNumber() == 1)

        let caretOnly = makeView("abc", selections: [.caret(at: 1)])
        #expect(caretOnly.accessibilitySelectedText() == nil)
    }

    @Test func axCanChangeSelection() {
        let view = makeView("abcdef")

        view.setAccessibilitySelectedTextRange(
            NSRange(location: 2, length: 3)
        )
        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 2, length: 3))
        ])

        // 越界范围夹取到文档末尾，不崩溃。
        view.setAccessibilitySelectedTextRange(
            NSRange(location: 100, length: 5)
        )
        #expect(view.engine.selections == [.caret(at: 6)])

        view.setAccessibilitySelectedTextRanges([
            NSValue(range: NSRange(location: 4, length: 2)),
            NSValue(range: NSRange(location: 0, length: 1)),
        ])
        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 0, length: 1)),
            TextSelection(range: NSRange(location: 4, length: 2)),
        ])
    }

    // MARK: - 行与字符范围

    @Test func lineAndIndexConversionsAreZeroBased() {
        let view = makeView("aa\nbbb\nc")

        #expect(view.accessibilityRange(forLine: 0) == NSRange(location: 0, length: 3))
        #expect(view.accessibilityRange(forLine: 1) == NSRange(location: 3, length: 4))
        #expect(view.accessibilityRange(forLine: 2) == NSRange(location: 7, length: 1))
        // 越界行夹到最后一行。
        #expect(view.accessibilityRange(forLine: 99) == NSRange(location: 7, length: 1))

        #expect(view.accessibilityLine(for: 0) == 0)
        #expect(view.accessibilityLine(for: 2) == 0)
        #expect(view.accessibilityLine(for: 3) == 1)
        #expect(view.accessibilityLine(for: 8) == 2)
    }

    @Test func stringAndAttributedStringForValidRanges() {
        let view = makeView("alpha\nbeta")

        #expect(view.accessibilityString(for: NSRange(location: 0, length: 5)) == "alpha")
        #expect(view.accessibilityString(for: NSRange(location: 6, length: 4)) == "beta")
        #expect(view.accessibilityString(for: NSRange(location: 20, length: 1)) == nil)

        let attributed = view.accessibilityAttributedString(
            for: NSRange(location: 0, length: 5)
        )
        #expect(attributed?.string == "alpha")
        #expect(attributed?.attribute(.font, at: 0, effectiveRange: nil) != nil)
    }

    @Test func composedCharacterRangesCoverGraphemes() {
        // "a👍🏽b"：拇指 + 肤色修饰符是一个 grapheme，占 4 个 UTF-16。
        let view = makeView("a👍🏽b")

        #expect(view.accessibilityRange(for: 1) == NSRange(location: 1, length: 4))
        #expect(view.accessibilityRange(for: 2) == NSRange(location: 1, length: 4))
        #expect(view.accessibilityRange(for: 5) == NSRange(location: 5, length: 1))
        // 文档末尾取最后一个 grapheme。
        #expect(view.accessibilityRange(for: 6) == NSRange(location: 5, length: 1))
    }

    @Test func visibleCharacterRangeCoversWholeDocumentWithoutScrollView() {
        let view = makeView("aa\nbb\ncc")

        let visible = view.accessibilityVisibleCharacterRange()
        #expect(visible.location == 0)
        #expect(visible.location + visible.length == view.engine.length)
    }

    // MARK: - 几何

    @Test func frameWithoutWindowIsZeroInsteadOfCrashing() {
        let view = makeView("abc")
        #expect(view.accessibilityFrame(for: NSRange(location: 0, length: 1)) == .zero)
        #expect(
            view.accessibilityRange(for: NSPoint(x: 10, y: 10))
                == NSRange(location: 0, length: 0)
        )
    }
}
