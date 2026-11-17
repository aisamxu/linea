import AppKit
import XCTest
@testable import Linea

/// 编辑器集成测试：验证控制器把引擎、视图与文档脏状态正确串起来。
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

        XCTAssertEqual(editor.currentText, "abc\ndef")
        XCTAssertEqual(
            editor.currentSelections(),
            [
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 3),
            ]
        )
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(editor.engine.isDirty)
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

    func testInsertWritesAtEverySelectionAndUndoRestoresText() {
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

        editor.textView.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertEqual(editor.currentText, "X\nX")
        XCTAssertEqual(
            editor.currentSelections(),
            [
                NSRange(location: 1, length: 0),
                NSRange(location: 3, length: 0),
            ]
        )
        XCTAssertTrue(document.isDirty)

        XCTAssertTrue(editor.engine.undo())
        XCTAssertEqual(editor.currentText, "abc\ndef")

        XCTAssertTrue(editor.engine.redo())
        XCTAssertEqual(editor.currentText, "X\nX")
        // 重做后光标必须落在两段恢复的文本之后，而不是因为撤销范围错位而重叠。
        XCTAssertEqual(
            editor.currentSelections(),
            [
                NSRange(location: 1, length: 0),
                NSRange(location: 3, length: 0),
            ]
        )
    }

    func testTypingTwiceKeepsMultipleCarets() {
        let document = makeDocument()
        let editor = EditorViewController(
            document: document,
            text: "abc\ndef",
            selections: [
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 3),
            ]
        )

        performInsertion("X", in: editor)
        XCTAssertEqual(editor.currentText, "X\nX")
        XCTAssertEqual(
            editor.currentSelections(),
            [
                NSRange(location: 1, length: 0),
                NSRange(location: 3, length: 0),
            ]
        )

        performInsertion("Y", in: editor)
        XCTAssertEqual(editor.currentText, "XY\nXY")
        XCTAssertEqual(
            editor.currentSelections(),
            [
                NSRange(location: 2, length: 0),
                NSRange(location: 5, length: 0),
            ]
        )

        XCTAssertTrue(editor.engine.undo())
        XCTAssertEqual(editor.currentText, "X\nX")
        XCTAssertEqual(editor.currentSelections().count, 2)

        XCTAssertTrue(editor.engine.undo())
        XCTAssertEqual(editor.currentText, "abc\ndef")
        XCTAssertEqual(editor.currentSelections().count, 2)
    }

    func testSixtyCursorsKeepSelectionsAcrossConsecutiveInput() {
        let lineCount = 60
        let lines = (1...lineCount).map { "Line \($0)" }
        let text = lines.joined(separator: "\n")
        var selections: [NSRange] = []
        var location = 0
        for line in lines {
            selections.append(NSRange(location: location, length: 0))
            location += (line as NSString).length + 1
        }

        let editor = EditorViewController(
            document: makeDocument(),
            text: text,
            selections: selections
        )

        performInsertion("X", in: editor)
        XCTAssertEqual(editor.currentSelections().count, lineCount)

        performInsertion("Y", in: editor)
        XCTAssertEqual(editor.currentSelections().count, lineCount)
        XCTAssertEqual(
            editor.currentText.components(separatedBy: "\n").count,
            lineCount
        )

        // 两次输入各成一个撤销步，需要撤销两次才能回到初始文本。
        XCTAssertTrue(editor.engine.undo())
        XCTAssertEqual(editor.currentSelections().count, lineCount)
        XCTAssertEqual(
            editor.currentText,
            lines.map { "X" + $0 }.joined(separator: "\n")
        )

        XCTAssertTrue(editor.engine.undo())
        XCTAssertEqual(editor.currentText, text)
        XCTAssertEqual(editor.currentSelections().count, lineCount)
    }

    func testBackspaceDeletesAtEveryCaretAndUndoRestores() {
        let editor = EditorViewController(
            document: makeDocument(),
            text: "abc\ndef",
            selections: [
                NSRange(location: 1, length: 0),
                NSRange(location: 5, length: 0),
            ]
        )

        editor.textView.deleteBackward(nil)

        XCTAssertEqual(editor.currentText, "bc\nef")
        XCTAssertEqual(
            editor.currentSelections(),
            [
                NSRange(location: 0, length: 0),
                NSRange(location: 3, length: 0),
            ]
        )

        XCTAssertTrue(editor.engine.undo())
        XCTAssertEqual(editor.currentText, "abc\ndef")
    }

    func testSingleCaretInsertAndUndo() {
        let editor = EditorViewController(
            document: makeDocument(),
            text: "abc",
            selections: [NSRange(location: 1, length: 0)]
        )

        editor.textView.insertText(
            "Z",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertEqual(editor.currentText, "aZbc")
        XCTAssertTrue(editor.engine.undo())
        XCTAssertEqual(editor.currentText, "abc")
    }

    func testReplaceTextFromDiskKeepsDocumentCleanAndClearsUndo() {
        let document = makeDocument()
        let editor = EditorViewController(
            document: document,
            text: "abc",
            selections: [NSRange(location: 1, length: 0)]
        )

        editor.textView.insertText(
            "Z",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(document.isDirty)
        XCTAssertTrue(editor.engine.history.canUndo)

        editor.replaceTextFromDisk("reloaded")
        document.markReloaded(
            from: URL(fileURLWithPath: "/tmp/reloaded.txt"),
            signature: nil
        )

        XCTAssertEqual(editor.currentText, "reloaded")
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(editor.engine.history.canUndo)
        XCTAssertEqual(
            editor.currentSelections(),
            [NSRange(location: 2, length: 0)]
        )
    }

    func testReplaceTextFromDiskOnCleanDocumentDoesNotMarkDirty() {
        let document = makeDocument()
        let editor = EditorViewController(
            document: document,
            text: "abc",
            selections: [NSRange(location: 1, length: 0)]
        )

        editor.replaceTextFromDisk("reloaded")

        XCTAssertEqual(editor.currentText, "reloaded")
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(editor.engine.history.canUndo)
        XCTAssertEqual(
            editor.currentSelections(),
            [NSRange(location: 1, length: 0)]
        )
    }

    func testEditingFreezeDuringTerminationCanBeReversed() {
        let editor = EditorViewController(
            document: makeDocument(),
            text: "",
            selections: [NSRange(location: 0, length: 0)]
        )

        performInsertion("A", in: editor)
        editor.setEditingEnabled(false)

        XCTAssertFalse(editor.isEditingEnabled)
        XCTAssertFalse(editor.engine.isEditable)
        editor.textView.insertText(
            "B",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(editor.currentText, "A")

        editor.setEditingEnabled(true)
        XCTAssertTrue(editor.engine.isEditable)
        performInsertion("C", in: editor)
        XCTAssertEqual(editor.currentText, "AC")

        XCTAssertTrue(editor.engine.undo())
        XCTAssertEqual(editor.currentText, "A")
    }

    func testSaveMarksBothDocumentAndEngineClean() {
        let document = makeDocument()
        let editor = EditorViewController(
            document: document,
            text: "abc",
            selections: [NSRange(location: 1, length: 0)]
        )

        performInsertion("Z", in: editor)
        XCTAssertTrue(editor.engine.isDirty)

        document.markSaved(
            to: URL(fileURLWithPath: "/tmp/saved.txt"),
            signature: nil
        )
        editor.markSaved()

        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(editor.engine.isDirty)
        // 保存不清空撤销历史，与 1.0.2 行为一致。
        XCTAssertTrue(editor.engine.history.canUndo)
    }

    func testLoadingOneHundredThousandLinesDoesNotCrash() {
        let text = String(repeating: "Line 0123456789\n", count: 100_000)
        let editor = EditorViewController(
            document: makeDocument(),
            text: text,
            selections: [NSRange(location: 0, length: 0)]
        )

        XCTAssertEqual(editor.currentText.utf16.count, text.utf16.count)
        XCTAssertEqual(
            editor.currentSelections(),
            [NSRange(location: 0, length: 0)]
        )
    }

    private func performInsertion(_ string: String, in editor: EditorViewController) {
        editor.textView.insertText(
            string,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
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
