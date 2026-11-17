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
