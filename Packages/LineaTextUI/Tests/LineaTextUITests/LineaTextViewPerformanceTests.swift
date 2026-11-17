import AppKit
import CoreGraphics
import Foundation
import LineaCore
import Testing
@testable import LineaTextUI

/// Phase 3：视图接线后的编辑 + 可见区域重绘性能。
///
/// Release 数据记录到 `Documentation/Performance.md`；Debug 只做数量级护栏。
/// 计时拆成三段：纯引擎 apply、视图编辑路径（含选区更新与失效）、可见区域绘制。
@Suite("LineaTextViewPerformance")
@MainActor
struct LineaTextViewPerformanceTests {
    private let theme = TextTheme.standard

    private func makeView(
        _ text: String,
        selections: [TextSelection]
    ) -> LineaTextView {
        let view = LineaTextView(
            engine: EditorEngine(text: text, selections: selections)
        )
        view.setViewportWidth(900)
        view.updateDocumentFrame()
        return view
    }

    private func makeBitmapContext() -> CGContext? {
        CGContext(
            data: nil,
            width: 900,
            height: 600,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// 模拟一帧可见区域绘制，包含文本、选区与光标。
    private func drawVisibleFrame(_ view: LineaTextView, _ context: CGContext) {
        let renderer = TextRenderer(theme: theme)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            renderer.draw(
                in: context,
                dirtyRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                layout: view.layoutEngine,
                selections: view.engine.selections,
                caretVisible: true
            )
        }
    }

    /// 纯引擎插入耗时，用于和视图编辑路径对比。
    private func coreOnlyInsert(
        _ text: String,
        selections: [TextSelection]
    ) -> Double {
        let engine = EditorEngine(text: text, selections: selections)
        let start = CFAbsoluteTimeGetCurrent()
        engine.insertText("x")
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    @Test func singleCursorEditAndDrawWithinFrameBudget() {
        let text = String(repeating: "line\n", count: 9_999) + "line"
        let carets: [TextSelection] = [.caret(at: 20_000)]
        let core = coreOnlyInsert(text, selections: carets)

        let view = makeView(text, selections: carets)
        guard let context = makeBitmapContext() else {
            Issue.record("无法创建绘制 context")
            return
        }

        // 预热布局缓存，测量稳定状态下的按键重绘。
        drawVisibleFrame(view, context)

        let editStart = CFAbsoluteTimeGetCurrent()
        view.insertText(
            "x",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let edit = (CFAbsoluteTimeGetCurrent() - editStart) * 1000

        let drawStart = CFAbsoluteTimeGetCurrent()
        drawVisibleFrame(view, context)
        let draw = (CFAbsoluteTimeGetCurrent() - drawStart) * 1000

        let total = edit + draw
        print(
            "[LineaTextUI] 单光标: core=\(core) edit=\(edit) "
                + "draw=\(draw) total=\(total) ms"
        )

        #if DEBUG
        #expect(total < 300)
        #else
        #expect(total < 16)
        #endif
    }

    @Test func sixtyCursorEditAndDrawWithinFrameBudget() {
        let text = String(repeating: "line\n", count: 999) + "line"
        let carets = (0..<60).map {
            TextSelection.caret(at: $0 * 5)
        }
        let core = coreOnlyInsert(text, selections: carets)

        let view = makeView(text, selections: carets)
        guard let context = makeBitmapContext() else {
            Issue.record("无法创建绘制 context")
            return
        }
        drawVisibleFrame(view, context)

        let editStart = CFAbsoluteTimeGetCurrent()
        view.insertText(
            "x",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let edit = (CFAbsoluteTimeGetCurrent() - editStart) * 1000

        let drawStart = CFAbsoluteTimeGetCurrent()
        drawVisibleFrame(view, context)
        let draw = (CFAbsoluteTimeGetCurrent() - drawStart) * 1000

        let total = edit + draw
        print(
            "[LineaTextUI] 60 光标: core=\(core) edit=\(edit) "
                + "draw=\(draw) total=\(total) ms"
        )
        #expect(view.engine.selections.count == 60)

        #if DEBUG
        #expect(total < 300)
        #else
        #expect(total < 16)
        #endif
    }

    @Test func fiveHundredCursorEditUndoAndDrawWithinBudget() {
        let text = String(repeating: "line\n", count: 999) + "line"
        let carets = (0..<500).map {
            TextSelection.caret(at: $0 * 10)
        }
        let core = coreOnlyInsert(text, selections: carets)

        let view = makeView(text, selections: carets)
        guard let context = makeBitmapContext() else {
            Issue.record("无法创建绘制 context")
            return
        }
        drawVisibleFrame(view, context)

        let editStart = CFAbsoluteTimeGetCurrent()
        view.insertText(
            "x",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let edit = (CFAbsoluteTimeGetCurrent() - editStart) * 1000

        let drawStart = CFAbsoluteTimeGetCurrent()
        drawVisibleFrame(view, context)
        let draw = (CFAbsoluteTimeGetCurrent() - drawStart) * 1000

        let undoStart = CFAbsoluteTimeGetCurrent()
        view.undo(nil)
        let undo = (CFAbsoluteTimeGetCurrent() - undoStart) * 1000

        print(
            "[LineaTextUI] 500 光标: core=\(core) edit=\(edit) "
                + "draw=\(draw) undo=\(undo) ms"
        )
        #expect(view.engine.selections.count == 500)

        #if DEBUG
        #expect(edit + draw < 2_000)
        #expect(undo < 2_000)
        #else
        #expect(edit + draw < 33)
        #expect(undo < 33)
        #endif
    }

    @Test func inputMethodUpdateAndDrawWithinFrameBudget() {
        let text = String(repeating: "line\n", count: 9_999) + "line"
        let view = makeView(text, selections: [.caret(at: 20_000)])
        guard let context = makeBitmapContext() else {
            Issue.record("无法创建绘制 context")
            return
        }
        drawVisibleFrame(view, context)

        // 模拟拼音逐键更新：每次 setMarkedText 后重绘一帧。
        let updates = 10
        let start = CFAbsoluteTimeGetCurrent()
        for step in 1...updates {
            let marked = String(repeating: "に", count: step)
            view.setMarkedText(
                marked,
                selectedRange: NSRange(location: step, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            drawVisibleFrame(view, context)
        }
        let perUpdate = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(updates)
        print("[LineaTextUI] 输入法逐键更新 + 重绘: \(perUpdate) ms/次")
        #expect(view.hasMarkedText())
        #expect(view.engine.text.utf16.count == text.utf16.count)

        #if DEBUG
        #expect(perUpdate < 300)
        #else
        #expect(perUpdate < 16)
        #endif
    }

    @Test func finderBuildsTenMegabyteStringAndSearchesWithinBudget() {
        // 5 万行 × 100 UTF-16 code unit = 10 MB（UTF-16 字节）。
        let line = String(repeating: "a", count: 99) + "\n"
        let text = String(repeating: line, count: 50_000)
        let view = makeView(text, selections: [.caret(at: 0)])

        let start = CFAbsoluteTimeGetCurrent()
        let full = view.string
        let searchRange = (full as NSString).range(
            of: "needle",
            options: .backwards
        )
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        print("[LineaTextUI] 10MB 查找全文构建 + 搜索: \(elapsed) ms")
        #expect(full.utf16.count == 5_000_000)
        #expect(searchRange.location == NSNotFound)

        #if DEBUG
        #expect(elapsed < 3_000)
        #else
        #expect(elapsed < 100)
        #endif
    }

    @Test func hundredThousandLinesWithFiveHundredSparseCursors() {
        let text = String(repeating: "line\n", count: 99_999) + "line"
        let carets = (0..<500).map {
            TextSelection.caret(at: $0 * 200)
        }
        let view = makeView(text, selections: carets)
        let initialLength = view.engine.length

        let start = CFAbsoluteTimeGetCurrent()
        view.insertText(
            "x",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let inserted = (CFAbsoluteTimeGetCurrent() - start) * 1000

        let undoStart = CFAbsoluteTimeGetCurrent()
        #expect(view.engine.undo())
        let undone = (CFAbsoluteTimeGetCurrent() - undoStart) * 1000

        print(
            "[LineaTextUI] 100k 行 + 500 稀疏光标: "
                + "insert=\(inserted) ms undo=\(undone) ms"
        )
        #expect(view.engine.length == initialLength)
        #expect(view.engine.history.canUndo == false)

        #if DEBUG
        #expect(inserted < 5_000)
        #expect(undone < 5_000)
        #else
        #expect(inserted < 100)
        #expect(undone < 100)
        #endif
    }
}
