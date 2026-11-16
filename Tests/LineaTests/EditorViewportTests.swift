import AppKit
import STTextKitPlus
import STTextView
import XCTest
@testable import Linea

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
        let editor = makeEditorWindow(text: "", selections: [NSRange(location: 0, length: 0)])
        let pasted = sixtyLines()

        editor.textView.insertText(
            pasted,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        waitForViewportToSettle(editor)

        XCTAssertEqual(editor.textView.text, pasted)
        assertTailVisible(in: editor, expectedLineCount: 60)
    }

    func testPaste60LinesAtEndOfExistingContent() {
        let existing = (1...100).map { "Existing \($0)" }.joined(separator: "\n")
        let editor = makeEditorWindow(
            text: existing,
            selections: [NSRange(location: (existing as NSString).length, length: 0)]
        )
        editor.textView.scrollRangeToVisible(NSRange(location: (existing as NSString).length, length: 0))
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
        editor.textView.scrollRangeToVisible(NSRange(location: (oldText as NSString).length, length: 0))
        waitForViewportToSettle(editor)

        let newText = sixtyLines()
        editor.replaceTextFromDisk(newText)
        waitForViewportToSettle(editor)

        assertTailVisible(in: editor, expectedLineCount: 60)
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

    private func waitForViewportToSettle(_ editor: EditorViewController) {
        // 只推进事件循环，让 STTextView 和 App 侧的异步 viewport 修复自己完成布局；
        // 测试不能在这里主动强制 layout，否则会掩盖用户报告的空白问题。
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
        let layoutManager = textView.textLayoutManager
        guard let contentManager = layoutManager.textContentManager else {
            return XCTFail("missing text content manager", file: file, line: line)
        }

        let text = textView.text ?? ""
        XCTAssertEqual(
            text.components(separatedBy: "\n").count,
            expectedLineCount,
            file: file, line: line
        )

        let documentEnd = contentManager.documentRange.endLocation
        let documentLength = contentManager.offset(
            from: contentManager.documentRange.location,
            to: documentEnd
        )

        let usageHeight = layoutManager.usageBoundsForTextContainer.height
        XCTAssertGreaterThanOrEqual(
            textView.frame.height + 2,
            usageHeight,
            "document height \(textView.frame.height) < usage bounds \(usageHeight)",
            file: file, line: line
        )
        XCTAssertGreaterThan(
            textView.frame.height,
            editor.scrollView.contentView.bounds.height,
            "document height did not grow beyond the visible area",
            file: file, line: line
        )

        guard let viewportRange = layoutManager.textViewportLayoutController.viewportRange else {
            return XCTFail("missing viewport range", file: file, line: line)
        }
        let viewportEnd = contentManager.offset(
            from: contentManager.documentRange.location,
            to: viewportRange.endLocation
        )
        XCTAssertGreaterThanOrEqual(
            viewportEnd,
            documentLength,
            "viewportRange \(viewportRange) does not cover document end",
            file: file, line: line
        )

        // 取最后一行文本的 range，避免空文档尾部 extra line fragment 的零高问题。
        let nsText = text as NSString
        let lastNewline = nsText.range(of: "\n", options: .backwards)
        let lastLineStart = lastNewline.location == NSNotFound ? 0 : lastNewline.location + 1
        let lastLineRange = NSRange(
            location: lastLineStart,
            length: max(0, nsText.length - lastLineStart)
        )
        guard let lastTextRange = NSTextRange(lastLineRange, in: contentManager),
              let lastFrame = layoutManager.textSegmentFrame(in: lastTextRange, type: .standard)
        else {
            return XCTFail("missing last line segment frame", file: file, line: line)
        }

        let visibleRect = editor.scrollView.documentVisibleRect
        XCTAssertFalse(lastFrame.isNull, file: file, line: line)
        XCTAssertTrue(
            lastFrame.intersects(visibleRect),
            "last line frame \(lastFrame) does not intersect visible rect \(visibleRect)",
            file: file, line: line
        )
    }
}
