import AppKit
import CoreGraphics
import Foundation
import LineaCore
import Testing
@testable import LineaTextUI

@Suite("LineaTextView")
@MainActor
struct LineaTextViewTests {
    private let theme = TextTheme.standard

    private func makeScrollView(
        text: String,
        size: NSSize = NSSize(width: 400, height: 300)
    ) -> (NSScrollView, LineaTextView, LineNumberRulerView) {
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        let textView = LineaTextView(engine: EditorEngine(text: text))
        scrollView.documentView = textView
        textView.setViewportWidth(scrollView.contentView.bounds.width)
        textView.updateDocumentFrame()

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        return (scrollView, textView, ruler)
    }

    private func makeBitmapContext(
        width: Int = 400,
        height: Int = 300
    ) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    // MARK: - 文档尺寸与视图状态

    @Test func documentFrameUsesLayoutHeightAndViewportWidth() {
        let engine = EditorEngine(text: "a\nb\nc")
        let textView = LineaTextView(engine: engine)
        textView.setViewportWidth(320)
        textView.updateDocumentFrame()

        #expect(textView.isFlipped)
        #expect(textView.acceptsFirstResponder)
        #expect(textView.documentWidth == 320)
        #expect(textView.documentHeight == textView.layoutEngine.lineHeight * 3)
        #expect(textView.frame.width == 320)
        #expect(textView.frame.height == textView.layoutEngine.lineHeight * 3)
    }

    @Test func viewportWidthNeverShrinksBelowDocumentWidth() {
        let textView = LineaTextView(engine: EditorEngine(text: "wide text"))
        _ = textView.layoutEngine.layoutLine(number: 1)
        let measured = textView.layoutEngine.documentWidth
        #expect(measured > 0)

        textView.setViewportWidth(10)
        textView.updateDocumentFrame()
        #expect(textView.frame.width == measured)

        textView.setViewportWidth(measured + 100)
        textView.updateDocumentFrame()
        #expect(textView.frame.width == measured + 100)
    }

    @Test func reloadDataUpdatesFrameAfterEngineEdit() {
        let engine = EditorEngine(text: "one")
        let textView = LineaTextView(engine: engine)
        textView.setViewportWidth(200)
        textView.updateDocumentFrame()
        #expect(textView.frame.height == textView.layoutEngine.lineHeight)

        engine.replace(range: NSRange(location: 3, length: 0), with: "\ntwo")
        textView.reloadData()

        #expect(textView.layoutEngine.lineCount == 2)
        #expect(textView.frame.height == textView.layoutEngine.lineHeight * 2)
    }

    @Test func themeChangeUpdatesRendererAndRuler() {
        let (_, textView, ruler) = makeScrollView(text: "one\ntwo")
        var custom = theme
        custom.tabInterval = 40
        custom.selection = .systemPink

        textView.theme = custom
        #expect(textView.theme.tabInterval == 40)
        // ruler 仍引用同一视图主题，宽度不小于最小值。
        #expect(ruler.ruleThickness >= 35)
    }

    @Test func selectionsAndCaretStateAreStored() {
        let (_, textView, _) = makeScrollView(text: "alpha\nbeta")
        textView.selections = [
            .caret(at: 0),
            TextSelection(range: NSRange(location: 0, length: 5)),
        ]
        #expect(textView.selections.count == 2)
        #expect(textView.selections.last?.range.length == 5)

        textView.isCaretVisible = true
        #expect(textView.isCaretVisible)
    }

    @Test func emptyDocumentCreatesOneLineRuler() {
        let (_, textView, ruler) = makeScrollView(text: "")
        #expect(textView.layoutEngine.lineCount == 1)
        #expect(textView.frame.height == textView.layoutEngine.lineHeight)
        #expect(ruler.ruleThickness >= 35)
    }

    // MARK: - 行号 ruler

    @Test func rulerKeepsMinimumWidthForSmallDocuments() {
        let (_, _, ruler) = makeScrollView(text: "a\nb")
        #expect(ruler.ruleThickness == 35)
    }

    @Test func rulerGrowsWithDigitCount() {
        let text = String(repeating: "x\n", count: 9_999) + "x"
        let (_, textView, ruler) = makeScrollView(text: text)
        #expect(textView.layoutEngine.lineCount == 10_000)
        #expect(ruler.ruleThickness > 35)
    }

    @Test func rulerDrawsOnlyVisibleLines() {
        let text = String(repeating: "line\n", count: 999) + "line"
        let (_, textView, ruler) = makeScrollView(text: text)
        #expect(textView.layoutEngine.layoutCount == 0)

        guard let context = makeBitmapContext() else {
            Issue.record("无法创建位图 context")
            return
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        ruler.drawHashMarksAndLabels(in: ruler.bounds)

        // 300pt 高的视口只应绘制少量行号，不遍历 1000 行。
        #expect(ruler.lastVisibleLineRange.lowerBound == 1)
        #expect(ruler.lastVisibleLineRange.count > 0)
        #expect(ruler.lastVisibleLineRange.count <= 20)
        // 行号只需要固定行高几何，不应为了画数字创建 CTLine。
        #expect(textView.layoutEngine.layoutCount == 0)
    }

    @Test func rulerClipsOversizedDirtyRectToItsBounds() {
        let (_, _, ruler) = makeScrollView(text: "a\nb")
        guard let context = makeBitmapContext(width: 900, height: 600) else {
            Issue.record("无法创建位图 context")
            return
        }

        // 先用黑色填满整块画布作为哨兵，再让 ruler 绘制。
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        // macOS 26 的 banner 式 NSRulerView 会把整个滚动视图当作脏矩形传入，
        // 例如 (0, -64, 900, 600)。ruler 必须把绘制裁剪到自身 bounds，
        // 否则背景和分隔线会盖住窗口上方的标签栏。
        ruler.drawHashMarksAndLabels(in: NSRect(x: 0, y: -64, width: 900, height: 600))

        guard let data = context.data else {
            Issue.record("位图 context 没有数据")
            return
        }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var leaked = 0
        for y in stride(from: 0, to: 600, by: 10) {
            for x in stride(from: 100, to: 900, by: 10) {
                let offset = y * context.bytesPerRow + x * 4
                if pixels[offset] != 0 || pixels[offset + 1] != 0 || pixels[offset + 2] != 0 {
                    leaked += 1
                }
            }
        }
        #expect(leaked == 0, "ruler 绘制越界，污染了自身范围外的像素")
    }

    @Test func rulerClipsItsLayerToItsOwnBounds() {
        let (_, _, ruler) = makeScrollView(text: "a")
        #expect(ruler.layer?.masksToBounds == true)
    }

    // MARK: - 绘制 smoke

    @Test func rendererDrawsOnlyVisibleLines() {
        let text = String(repeating: "visible\n", count: 999) + "visible"
        let layout = CoreTextLayoutEngine(
            engine: EditorEngine(text: text),
            font: theme.font,
            tabInterval: theme.tabInterval,
            lineHeightMultiple: theme.lineHeightMultiple
        )
        let renderer = TextRenderer(theme: theme)
        guard let context = makeBitmapContext() else {
            Issue.record("无法创建位图 context")
            return
        }

        let visibleRect = CGRect(
            x: 0,
            y: 0,
            width: 400,
            height: layout.lineHeight * 3
        )
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            renderer.draw(
                in: context,
                dirtyRect: visibleRect,
                layout: layout,
                selections: [
                    TextSelection(range: NSRange(location: 0, length: 7))
                ],
                caretVisible: true
            )
        }

        #expect(layout.layoutCount == 3)
    }

    @Test func viewDrawSmokeWithSelections() {
        let (_, textView, _) = makeScrollView(text: "alpha\nbeta\ngamma")
        textView.selections = [
            TextSelection(range: NSRange(location: 1, length: 8))
        ]
        textView.isCaretVisible = true

        guard let context = makeBitmapContext() else {
            Issue.record("无法创建位图 context")
            return
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            textView.draw(textView.visibleRect)
        }

        #expect(textView.layoutEngine.layoutCount > 0)
        #expect(textView.layoutEngine.layoutCount <= 4)
    }

    @Test func scrollRangeToVisibleSmoke() {
        let (scrollView, textView, _) = makeScrollView(
            text: String(repeating: "line\n", count: 999) + "line",
            size: NSSize(width: 400, height: 100)
        )
        let farOffset = textView.engine.contentEnd(at: textView.engine.length)
        textView.scrollRangeToVisible(NSRange(location: farOffset, length: 0))

        // 无窗口时滚动几何可能不完全生效，只要求不崩溃并保持文档尺寸。
        #expect(scrollView.documentView === textView)
        #expect(textView.frame.height == textView.layoutEngine.documentHeight)
    }
}
