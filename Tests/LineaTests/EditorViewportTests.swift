import AppKit
import LineaCore
import XCTest
@testable import Linea

/// 视口集成测试：粘贴/重载/多光标后文档尾部可见，不出现空白尾巴。
///
/// 断言从 TextKit 的 viewport/layout fragment 改为自建布局引擎的行几何。
@MainActor
final class EditorViewportTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        super.tearDown()
    }

    func testPaste60LinesLaysOutAndShowsTail() {
        let editor = makeEditorWindow(
            text: "",
            selections: [NSRange(location: 0, length: 0)]
        )
        let pasted = sixtyLines()

        editor.textView.insertText(
            pasted,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        waitForViewportToSettle(editor)

        XCTAssertEqual(editor.currentText, pasted)
        assertTailVisible(in: editor, expectedLineCount: 60)
    }

    func testPaste60LinesAtEndOfExistingContent() {
        let existing = (1...100).map { "Existing \($0)" }.joined(separator: "\n")
        let editor = makeEditorWindow(
            text: existing,
            selections: [NSRange(location: (existing as NSString).length, length: 0)]
        )
        editor.textView.scrollRangeToVisible(
            NSRange(location: (existing as NSString).length, length: 0)
        )
        waitForViewportToSettle(editor)

        let pasted = "\n" + sixtyLines()
        editor.textView.insertText(
            pasted,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        waitForViewportToSettle(editor)

        assertTailVisible(in: editor, expectedLineCount: 160)
    }

    func testInitialProgrammaticLoad60LinesWithBottomScrollOrigin() {
        let text = sixtyLines()
        let editor = makeEditorWindow(
            text: text,
            selections: [NSRange(location: (text as NSString).length, length: 0)],
            scrollOrigin: CGPoint(x: 0, y: 10_000)
        )
        editor.prepareForDisplay(focus: false)
        waitForViewportToSettle(editor)

        assertTailVisible(in: editor, expectedLineCount: 60)
    }

    func testReplaceTextFromDiskKeepsScrollAndLaysOutTail() {
        let oldText = (1...100).map { "Old \($0)" }.joined(separator: "\n")
        let editor = makeEditorWindow(
            text: oldText,
            selections: [NSRange(location: (oldText as NSString).length, length: 0)]
        )
        editor.textView.scrollRangeToVisible(
            NSRange(location: (oldText as NSString).length, length: 0)
        )
        waitForViewportToSettle(editor)

        let newText = sixtyLines()
        editor.replaceTextFromDisk(newText)
        waitForViewportToSettle(editor)

        assertTailVisible(in: editor, expectedLineCount: 60)
    }

    /// 空文档没有可横向滚动的内容，底部不应出现横向滚动条。
    /// 行号 ruler 覆盖在 clip view 左侧，视口宽度必须扣除这段覆盖区。
    func testEmptyEditorHasNoHorizontalScroller() {
        let editor = makeEditorWindow(
            text: "",
            selections: [NSRange(location: 0, length: 0)]
        )
        editor.prepareForDisplay(focus: false)
        waitForViewportToSettle(editor)

        let viewport = effectiveViewportWidth(of: editor)
        XCTAssertEqual(
            editor.textView.layoutEngine.viewportWidth,
            viewport,
            accuracy: 0.5
        )
        XCTAssertEqual(editor.textView.frame.width, viewport, accuracy: 0.5)
        XCTAssertNotNil(editor.scrollView.horizontalScroller)
        XCTAssertEqual(editor.scrollView.horizontalScroller?.isHidden, true)
    }

    /// 放大字号时以左上角为锚点：横向滚动到中间后，
    /// 左边缘停留的文本列应保持不变，而不是整体向右滑走。
    func testZoomKeepsLeftEdgeTextColumnAnchored() {
        let line = String(repeating: "abcdefghij", count: 200)
        let editor = makeEditorWindow(
            text: line,
            selections: [NSRange(location: 0, length: 0)]
        )
        editor.prepareForDisplay(focus: false)
        waitForViewportToSettle(editor)
        editor.applyFontSize(13)
        waitForViewportToSettle(editor)

        editor.textView.applyScrollOrigin(CGPoint(x: 600, y: 0))
        waitForViewportToSettle(editor)
        XCTAssertEqual(editor.currentScrollOrigin.x, 600, accuracy: 1)

        let before = editor.textView.layoutEngine.localOffset(
            forLine: 0,
            atX: editor.textView.horizontalScrollOffset
        )
        editor.applyFontSize(20)
        waitForViewportToSettle(editor)
        let after = editor.textView.layoutEngine.localOffset(
            forLine: 0,
            atX: editor.textView.horizontalScrollOffset
        )

        XCTAssertGreaterThan(before, 0)
        XCTAssertLessThanOrEqual(abs(after - before), 1)
    }

    func testMultiCursorCommandScrollDoesNotLeaveBlankTail() {
        let text = sixtyLines()
        let editor = makeEditorWindow(
            text: text,
            selections: [NSRange(location: 0, length: 0)]
        )

        let result = editor.selectAllOccurrences()
        guard case .updated = result else {
            return XCTFail("expected selectAllOccurrences to update selections")
        }
        waitForViewportToSettle(editor)

        XCTAssertGreaterThan(editor.currentSelections().count, 1)
        editor.collapseSelectionsIfNeeded()
        waitForViewportToSettle(editor)

        assertTailVisible(in: editor, expectedLineCount: 60)
    }

    // MARK: - Helpers

    private func makeEditorWindow(
        text: String,
        selections: [NSRange],
        scrollOrigin: CGPoint? = nil
    ) -> EditorViewController {
        let editor = EditorViewController(
            document: Document(
                fileURL: nil,
                displayName: "Untitled 1",
                isDirty: false,
                savedSignature: nil
            ),
            text: text,
            selections: selections,
            scrollOrigin: scrollOrigin
        )

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 320),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = editor
        window.setContentSize(NSSize(width: 600, height: 320))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        windows.append(window)
        return editor
    }

    private func sixtyLines() -> String {
        (1...60).map { String(format: "Line %02d: the quick brown fox", $0) }
            .joined(separator: "\n")
    }

    /// 与 LineaTextView 内部一致：可视宽度要扣除 ruler 覆盖在 clip view 上的部分。
    private func effectiveViewportWidth(of editor: EditorViewController) -> CGFloat {
        let scrollView = editor.scrollView
        guard let ruler = scrollView.verticalRulerView else {
            return scrollView.contentView.bounds.width
        }
        let clipOffset = max(0, scrollView.contentView.frame.minX - ruler.frame.minX)
        let overlap = max(0, ruler.ruleThickness - clipOffset)
        return max(0, scrollView.contentView.bounds.width - overlap)
    }

    private func waitForViewportToSettle(_ editor: EditorViewController) {
        // 只推进事件循环，让窗口布局与滚动跟随自己完成。
        for _ in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func assertTailVisible(
        in editor: EditorViewController,
        expectedLineCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let textView = editor.textView
        let layout = textView.layoutEngine

        XCTAssertEqual(
            editor.currentText.components(separatedBy: "\n").count,
            expectedLineCount,
            file: file, line: line
        )
        XCTAssertEqual(layout.lineCount, expectedLineCount, file: file, line: line)

        // 文档高度必须覆盖全部行，且超出可见区域。
        XCTAssertGreaterThanOrEqual(
            textView.frame.height + 2,
            layout.documentHeight,
            "document height \(textView.frame.height) < layout height \(layout.documentHeight)",
            file: file, line: line
        )
        XCTAssertGreaterThan(
            textView.frame.height,
            editor.scrollView.contentView.bounds.height,
            "document height did not grow beyond the visible area",
            file: file, line: line
        )

        // 最后一行必须与可见矩形相交，没有空白尾巴。
        let lastLineRect = layout.caretRect(for: editor.engine.length)
        let visibleRect = editor.scrollView.documentVisibleRect
        XCTAssertTrue(
            lastLineRect.intersects(visibleRect),
            "last line rect \(lastLineRect) does not intersect visible rect \(visibleRect)",
            file: file, line: line
        )
    }
}
