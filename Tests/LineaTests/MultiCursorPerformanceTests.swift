import AppKit
import XCTest
@testable import Linea

@MainActor
final class MultiCursorPerformanceTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        super.tearDown()
    }

    func testOneKeypressWritesSelectionsOnceAt60And500() {
        for lineCount in [60, 500] {
            let editor = makeEditor(lineCount: lineCount)
            runLoopBriefly()

            TextSelectionBridge.setRangesCallCount = 0
            editor.textView.insertText(
                "X",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            _ = editor.currentSelections()

            XCTAssertEqual(
                TextSelectionBridge.setRangesCallCount,
                1,
                "\(lineCount) cursors should restore selections exactly once"
            )
            XCTAssertEqual(editor.currentSelections().count, lineCount)
        }
    }

    func test500SelectionsSurviveInsertAndDelete() {
        let editor = makeEditor(lineCount: 500)
        let originalText = editor.textView.text ?? ""
        runLoopBriefly()

        editor.textView.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(editor.currentSelections().count, 500)

        editor.textView.deleteBackward(nil)
        spinMainRunLoop()

        XCTAssertEqual(editor.currentSelections().count, 500)
        XCTAssertEqual(editor.textView.text, originalText)
    }

    func testSingleUndoRestores500SelectionEdit() throws {
        let editor = makeEditor(lineCount: 500)
        let originalText = editor.textView.text ?? ""
        let undo = try XCTUnwrap(editor.textView.undoManager)
        runLoopBriefly()

        undo.beginUndoGrouping()
        editor.textView.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        undo.endUndoGrouping()
        XCTAssertEqual(editor.currentSelections().count, 500)

        undo.undo()
        spinMainRunLoop()

        XCTAssertEqual(editor.textView.text, originalText)
        XCTAssertEqual(editor.currentSelections().count, 500)
    }

    func testInsertLatencyGuardrails() {
        let sixty = measureInsert(lineCount: 60)
        let fiveHundred = measureInsert(lineCount: 500)

        print("[LineaPerf] insert 60 cursors: \(sixty * 1_000) ms")
        print("[LineaPerf] insert 500 cursors: \(fiveHundred * 1_000) ms")

        // Debug 构建的宽松护栏，防止退回 O(k²) 级别的卡顿。
        XCTAssertLessThan(sixty, 0.100, "60-cursor insert took \(sixty)s")
        XCTAssertLessThan(fiveHundred, 0.500, "500-cursor insert took \(fiveHundred)s")

        if sixty > 0 {
            let ratio = fiveHundred / sixty
            print("[LineaPerf] 500/60 ratio: \(ratio)")
            XCTAssertLessThan(ratio, 40, "500/60 latency ratio is \(ratio)")
        }
    }

    func testUndoLatency500() throws {
        let editor = makeEditor(lineCount: 500)
        let undo = try XCTUnwrap(editor.textView.undoManager)
        runLoopBriefly()

        undo.beginUndoGrouping()
        editor.textView.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        undo.endUndoGrouping()
        _ = editor.currentSelections()

        let start = CFAbsoluteTimeGetCurrent()
        undo.undo()
        spinMainRunLoop()
        _ = editor.currentSelections()
        editor.scrollView.layoutSubtreeIfNeeded()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print("[LineaPerf] undo 500 cursors: \(elapsed * 1_000) ms")
        XCTAssertLessThan(elapsed, 0.800, "500-cursor undo took \(elapsed)s")
        XCTAssertEqual(editor.currentSelections().count, 500)
    }

    // MARK: - Helpers

    private func measureInsert(lineCount: Int) -> TimeInterval {
        var best = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<3 {
            let editor = makeEditor(lineCount: lineCount)
            runLoopBriefly()

            let start = CFAbsoluteTimeGetCurrent()
            editor.textView.insertText(
                "X",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            _ = editor.currentSelections()
            editor.scrollView.layoutSubtreeIfNeeded()
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            best = min(best, elapsed)

            XCTAssertEqual(editor.currentSelections().count, lineCount)
            closeLastWindow()
        }
        return best
    }

    private func makeEditor(lineCount: Int) -> EditorViewController {
        let lines = (1...lineCount).map { "Line \($0): some content here" }
        let text = lines.joined(separator: "\n")
        var selections: [NSRange] = []
        var location = 0
        for line in lines {
            selections.append(NSRange(location: location, length: 0))
            location += (line as NSString).length + 1
        }

        let editor = EditorViewController(
            document: Document(
                fileURL: nil,
                displayName: "Untitled 1",
                isDirty: false,
                savedSignature: nil
            ),
            text: text,
            selections: selections
        )
        XCTAssertEqual(selections.count, lineCount)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = editor
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor.textView)
        window.contentView?.layoutSubtreeIfNeeded()
        windows.append(window)
        return editor
    }

    private func closeLastWindow() {
        guard let window = windows.popLast() else { return }
        window.orderOut(nil)
        window.close()
    }

    private func runLoopBriefly() {
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func spinMainRunLoop() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}
