import AppKit
import STTextView
import XCTest
@testable import Linea

@MainActor
final class EditorIntegrationTests: XCTestCase {
    func testInitialLoadRestoresSelectionsWithoutMarkingDirty() {
        let document = makeDocument()
        let editor = EditorViewController(
            document: document,
            text: "abc\ndef",
            selections: [
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 3),
            ]
        )

        XCTAssertEqual(editor.textView.text, "abc\ndef")
        XCTAssertEqual(
            editor.currentSelections(),
            [
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 3),
            ]
        )
        XCTAssertFalse(document.isDirty)
    }

    func testOutOfBoundsSelectionIsClamped() {
        let editor = EditorViewController(
            document: makeDocument(),
            text: "abc",
            selections: [NSRange(location: 99, length: 5)]
        )

        XCTAssertEqual(
            editor.currentSelections(),
            [NSRange(location: 3, length: 0)]
        )
    }

    func testInsertWritesAtEverySelectionAndUndoRestoresText() throws {
        let document = makeDocument()
        let editor = EditorViewController(
            document: document,
            text: "abc\ndef",
            selections: [
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 3),
            ]
        )

        XCTAssertEqual(editor.currentSelections().count, 2)
        let undo = try XCTUnwrap(editor.textView.undoManager)

        // 测试里没有 run loop 自动事件分组，手动包一层模拟一次用户输入。
        undo.beginUndoGrouping()
        editor.textView.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        undo.endUndoGrouping()

        XCTAssertEqual(editor.textView.text, "X\nX")
        XCTAssertEqual(
            editor.currentSelections(),
            [
                NSRange(location: 1, length: 0),
                NSRange(location: 3, length: 0),
            ]
        )
        XCTAssertTrue(document.isDirty)

        undo.undo()
        spinMainRunLoop()
        XCTAssertEqual(editor.textView.text, "abc\ndef")

        undo.redo()
        spinMainRunLoop()
        XCTAssertEqual(editor.textView.text, "X\nX")
        XCTAssertEqual(editor.currentSelections().count, 2)
    }

    func testTypingTwiceKeepsMultipleCarets() throws {
        let document = makeDocument()
        let editor = EditorViewController(
            document: document,
            text: "abc\ndef",
            selections: [
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 3),
            ]
        )
        let undo = try XCTUnwrap(editor.textView.undoManager)
        // XCTest 在测试方法外维持自动事件撤销组，手动 begin/end 的两次输入会被合并。
        // 测试中关闭按事件分组，显式验证每次输入各自成为一步撤销；真实 App 仍由事件分组。
        undo.groupsByEvent = false

        performInsertion("X", in: editor, undo: undo)
        XCTAssertEqual(editor.textView.text, "X\nX")
        XCTAssertEqual(
            editor.currentSelections(),
            [
                NSRange(location: 1, length: 0),
                NSRange(location: 3, length: 0),
            ]
        )

        performInsertion("Y", in: editor, undo: undo)
        XCTAssertEqual(editor.textView.text, "XY\nXY")
        XCTAssertEqual(
            editor.currentSelections(),
            [
                NSRange(location: 2, length: 0),
                NSRange(location: 5, length: 0),
            ]
        )

        undo.undo()
        spinMainRunLoop()
        XCTAssertEqual(editor.textView.text, "X\nX")
        XCTAssertEqual(editor.currentSelections().count, 2)

        undo.undo()
        spinMainRunLoop()
        XCTAssertEqual(editor.textView.text, "abc\ndef")
        XCTAssertEqual(editor.currentSelections().count, 2)
    }

    func testBackspaceDeletesAtEveryCaretAndUndoRestores() throws {
        let editor = EditorViewController(
            document: makeDocument(),
            text: "abc\ndef",
            selections: [
                NSRange(location: 1, length: 0),
                NSRange(location: 5, length: 0),
            ]
        )
        let undo = try XCTUnwrap(editor.textView.undoManager)

        undo.beginUndoGrouping()
        editor.textView.deleteBackward(nil)
        undo.endUndoGrouping()
        spinMainRunLoop()

        XCTAssertEqual(editor.textView.text, "bc\nef")
        XCTAssertEqual(
            editor.currentSelections(),
            [
                NSRange(location: 0, length: 0),
                NSRange(location: 3, length: 0),
            ]
        )

        undo.undo()
        spinMainRunLoop()
        XCTAssertEqual(editor.textView.text, "abc\ndef")
    }

    func testSingleCaretInsertAndUndo() throws {
        let editor = EditorViewController(
            document: makeDocument(),
            text: "abc",
            selections: [NSRange(location: 1, length: 0)]
        )
        let undo = try XCTUnwrap(editor.textView.undoManager)

        undo.beginUndoGrouping()
        editor.textView.insertText(
            "Z",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        undo.endUndoGrouping()

        XCTAssertEqual(editor.textView.text, "aZbc")
        undo.undo()
        XCTAssertEqual(editor.textView.text, "abc")
    }

    func testReplaceTextFromDiskKeepsDocumentCleanAndClearsUndo() throws {
        let document = makeDocument()
        let editor = EditorViewController(
            document: document,
            text: "abc",
            selections: [NSRange(location: 1, length: 0)]
        )
        let undo = try XCTUnwrap(editor.textView.undoManager)

        undo.beginUndoGrouping()
        editor.textView.insertText(
            "Z",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        undo.endUndoGrouping()
        XCTAssertTrue(document.isDirty)
        XCTAssertTrue(undo.canUndo)

        editor.replaceTextFromDisk("reloaded")
        document.markReloaded(
            from: URL(fileURLWithPath: "/tmp/reloaded.txt"),
            signature: nil
        )

        XCTAssertEqual(editor.textView.text, "reloaded")
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(undo.canUndo)
        XCTAssertEqual(
            editor.currentSelections(),
            [NSRange(location: 2, length: 0)]
        )
    }

    func testReplaceTextFromDiskOnCleanDocumentDoesNotMarkDirty() throws {
        let document = makeDocument()
        let editor = EditorViewController(
            document: document,
            text: "abc",
            selections: [NSRange(location: 1, length: 0)]
        )
        let undo = try XCTUnwrap(editor.textView.undoManager)

        editor.replaceTextFromDisk("reloaded")

        XCTAssertEqual(editor.textView.text, "reloaded")
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(undo.canUndo)
        XCTAssertEqual(
            editor.currentSelections(),
            [NSRange(location: 1, length: 0)]
        )
    }

    func testEditingFreezeDuringTerminationCanBeReversed() throws {
        let editor = EditorViewController(
            document: makeDocument(),
            text: "",
            selections: [NSRange(location: 0, length: 0)]
        )
        let undo = try XCTUnwrap(editor.textView.undoManager)
        // 与 testTypingTwiceKeepsMultipleCarets 相同：测试环境没有真实事件边界，
        // 改为手动分组，确保冻结前后的两次输入是两步撤销。
        undo.groupsByEvent = false

        performInsertion("A", in: editor, undo: undo)
        editor.setEditingEnabled(false)

        XCTAssertFalse(editor.isEditingEnabled)
        XCTAssertNil(editor.textView.undoManager)
        editor.textView.insertText(
            "B",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(editor.textView.text, "A")

        editor.setEditingEnabled(true)
        performInsertion("C", in: editor, undo: undo)
        XCTAssertEqual(editor.textView.text, "AC")

        undo.undo()
        spinMainRunLoop()
        XCTAssertEqual(editor.textView.text, "A")
    }

    func testLoadingOneHundredThousandLinesDoesNotCrash() {
        let text = String(repeating: "Line 0123456789\n", count: 100_000)
        let editor = EditorViewController(
            document: makeDocument(),
            text: text,
            selections: [NSRange(location: 0, length: 0)]
        )

        XCTAssertEqual(editor.textView.text?.utf16.count, text.utf16.count)
        XCTAssertEqual(
            editor.currentSelections(),
            [NSRange(location: 0, length: 0)]
        )
    }

    private func performInsertion(
        _ string: String,
        in editor: EditorViewController,
        undo: UndoManager
    ) {
        undo.beginUndoGrouping()
        editor.textView.insertText(
            string,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        undo.endUndoGrouping()
        spinMainRunLoop()
    }

    /// 模拟真实事件循环，让延迟的选区恢复和撤销分组收尾。
    private func spinMainRunLoop() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    private func makeDocument() -> Document {
        Document(
            fileURL: nil,
            displayName: "Untitled 1",
            isDirty: false,
            savedSignature: nil
        )
    }
}
