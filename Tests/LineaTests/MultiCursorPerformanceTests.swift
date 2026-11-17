import AppKit
import XCTest
@testable import Linea

/// 多光标结构护栏：一次按键一个变更、不重建全文、不创建插入点子视图。
/// 时间断言只做 Debug 宽松护栏，真实目标以 Release 性能数据为准。
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

    func testOneKeypressEmitsSingleChangeAt60And500() {
        for lineCount in [60, 500] {
            let editor = makeEditor(lineCount: lineCount)
            runLoopBriefly()

            var changeCount = 0
            editor.textView.onChange = { _ in changeCount += 1 }
            let buildsBefore = editor.engine.fullTextBuildCount

            editor.textView.insertText(
                "X",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )

            XCTAssertEqual(
                changeCount,
                1,
                "\(lineCount) cursors should produce exactly one change"
            )
            // 编辑热路径不构建全文缓存。
            XCTAssertEqual(
                editor.engine.fullTextBuildCount,
                buildsBefore,
                "\(lineCount) cursors must not rebuild full text"
            )
            // 光标与选区直接绘制，不创建每个光标的子视图。
            XCTAssertTrue(editor.textView.subviews.isEmpty)
            XCTAssertEqual(editor.currentSelections().count, lineCount)
        }
    }

    func test500SelectionsSurviveInsertAndDelete() {
        let editor = makeEditor(lineCount: 500)
        let originalText = editor.currentText
        runLoopBriefly()

        editor.textView.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(editor.currentSelections().count, 500)

        editor.textView.deleteBackward(nil)

        XCTAssertEqual(editor.currentSelections().count, 500)
        XCTAssertEqual(editor.currentText, originalText)
    }

    func testSingleUndoRestores500SelectionEdit() {
        let editor = makeEditor(lineCount: 500)
        let originalText = editor.currentText
        runLoopBriefly()

        editor.textView.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(editor.currentSelections().count, 500)
        XCTAssertEqual(editor.engine.history.undoCount, 1)
        let insertedText = editor.currentText

        XCTAssertTrue(editor.engine.undo())
        XCTAssertEqual(editor.currentText, originalText)
        XCTAssertEqual(editor.currentSelections().count, 500)

        // 批量撤销应注册对应的批量重做，并恢复全部光标。
        XCTAssertTrue(editor.engine.redo())
        XCTAssertEqual(editor.currentText, insertedText)
        XCTAssertEqual(editor.currentSelections().count, 500)
    }

    func testInsertLatencyGuardrails() {
        let sixty = measureInsert(lineCount: 60)
        let fiveHundred = measureInsert(lineCount: 500)

        print("[LineaPerf] insert 60 cursors: \(sixty * 1_000) ms")
        print("[LineaPerf] insert 500 cursors: \(fiveHundred * 1_000) ms")

        // Debug 构建的宽松护栏，防止退回逐光标视图或 O(k²) 级别的卡顿。
        XCTAssertLessThan(sixty, 0.150, "60-cursor insert took \(sixty)s")
        XCTAssertLessThan(fiveHundred, 1.000, "500-cursor insert took \(fiveHundred)s")

        if sixty > 0 {
            let ratio = fiveHundred / sixty
            print("[LineaPerf] 500/60 ratio: \(ratio)")
            XCTAssertLessThan(ratio, 40, "500/60 latency ratio is \(ratio)")
        }
    }

    func testUndoLatency500() {
        let editor = makeEditor(lineCount: 500)
        runLoopBriefly()

        editor.textView.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(editor.currentSelections().count, 500)

        let start = CFAbsoluteTimeGetCurrent()
        XCTAssertTrue(editor.engine.undo())
        editor.scrollView.layoutSubtreeIfNeeded()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print("[LineaPerf] undo 500 cursors: \(elapsed * 1_000) ms")
        XCTAssertLessThan(elapsed, 1.500, "500-cursor undo took \(elapsed)s")
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
}
