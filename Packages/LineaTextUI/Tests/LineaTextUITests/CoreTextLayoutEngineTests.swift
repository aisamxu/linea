import CoreGraphics
import Foundation
import LineaCore
import Testing
@testable import LineaTextUI

@Suite("CoreTextLayoutEngine")
struct CoreTextLayoutEngineTests {
    private let theme = TextTheme.standard

    private func makeLayout(_ text: String) -> CoreTextLayoutEngine {
        let engine = EditorEngine(text: text)
        return CoreTextLayoutEngine(
            engine: engine,
            font: theme.font,
            tabInterval: theme.tabInterval,
            lineHeightMultiple: theme.lineHeightMultiple
        )
    }

    // MARK: - 文档几何

    @Test func documentHeightAndLineHeight() {
        let layout = makeLayout("alpha\nbeta\ngamma")
        #expect(layout.lineCount == 3)
        #expect(layout.lineHeight == theme.lineHeight)
        #expect(layout.documentHeight == theme.lineHeight * 3)
        #expect(layout.y(forLine: 1) == 0)
        #expect(layout.y(forLine: 2) == theme.lineHeight)
        #expect(layout.y(forLine: 3) == theme.lineHeight * 2)
    }

    @Test func documentWidthGrowsWithViewportAndMeasuredLine() {
        let layout = makeLayout("short")
        #expect(layout.documentWidth == 0)

        layout.viewportWidth = 320
        #expect(layout.documentWidth == 320)

        layout.viewportWidth = -10
        #expect(layout.viewportWidth == 0)

        let wideLayout = makeLayout("a very very very long line that exceeds viewport")
        wideLayout.viewportWidth = 20
        let width = wideLayout.layoutLine(number: 1).width
        #expect(width > 20)
        #expect(wideLayout.documentWidth == width)
    }

    @Test func emptyDocumentStillHasOneLine() {
        let layout = makeLayout("")
        #expect(layout.lineCount == 1)
        #expect(layout.documentHeight == theme.lineHeight)
        let line = layout.layoutLine(number: 1)
        #expect(line.isEmpty)
        #expect(line.width == 0)
        #expect(layout.caretRect(for: 0).origin == .zero)
        #expect(layout.index(at: CGPoint(x: 100, y: 0)) == 0)
    }

    // MARK: - 行排版与缓存

    @Test func layoutLineContainsRangesAndWidth() {
        let layout = makeLayout("alpha\nbeta\ngamma")
        let first = layout.layoutLine(number: 1)
        #expect(first.number == 1)
        #expect(first.lineRange == NSRange(location: 0, length: 6))
        #expect(first.contentRange == NSRange(location: 0, length: 5))
        #expect(first.width > 0)
        #expect(first.ascent > 0)

        let second = layout.layoutLine(number: 2)
        #expect(second.contentRange == NSRange(location: 6, length: 4))
        #expect(second.width > 0)

        // 同一行重复访问命中缓存。
        #expect(layout.layoutCount == 2)
        _ = layout.layoutLine(number: 1)
        #expect(layout.layoutCount == 2)
    }

    @Test func layoutLineClampsOutOfRange() {
        let layout = makeLayout("one\ntwo")
        #expect(layout.layoutLine(number: 0).number == 1)
        #expect(layout.layoutLine(number: 99).number == 2)
    }

    @Test func emptyLineHasZeroWidth() {
        let layout = makeLayout("a\n\nb")
        let line = layout.layoutLine(number: 2)
        #expect(line.number == 2)
        #expect(line.isEmpty)
        #expect(line.width == 0)
        #expect(line.contentRange == NSRange(location: 2, length: 0))
    }

    @Test func invalidateLayoutClearsMeasurements() {
        let layout = makeLayout("some text")
        _ = layout.layoutLine(number: 1)
        #expect(layout.layoutCount == 1)
        #expect(layout.documentWidth > 0)

        layout.invalidateLayout()
        #expect(layout.documentWidth == 0)
        _ = layout.layoutLine(number: 1)
        #expect(layout.layoutCount == 2)
    }

    // MARK: - 选区矩形

    @Test func selectionRectsWithinOneLine() {
        let layout = makeLayout("alpha\nbeta\ngamma")
        let rects = layout.rects(for: NSRange(location: 1, length: 3))
        #expect(rects.count == 1)
        #expect(rects[0].minY == 0)
        #expect(rects[0].height == layout.lineHeight)
        #expect(rects[0].width > 0)
    }

    @Test func selectionRectsAcrossLines() {
        let layout = makeLayout("alpha\nbeta\ngamma")
        let rects = layout.rects(for: NSRange(location: 3, length: 4))
        #expect(rects.count == 2)
        #expect(rects[0].minY == 0)
        #expect(rects[1].minY == layout.lineHeight)
        #expect(rects.allSatisfy { $0.width > 0 })
    }

    @Test func selectionOnlyNewlineProducesNoRect() {
        let layout = makeLayout("alpha\nbeta")
        #expect(layout.rects(for: NSRange(location: 5, length: 1)).isEmpty)
    }

    @Test func selectionRectsAreClippedToValidText() {
        let layout = makeLayout("abc")
        #expect(layout.rects(for: NSRange(location: 0, length: 0)).isEmpty)
        #expect(layout.rects(for: NSRange(location: 99, length: 5)).isEmpty)
        #expect(layout.rects(for: NSRange(location: NSNotFound, length: 2)).isEmpty)

        let clipped = layout.rects(for: NSRange(location: 1, length: 99))
        #expect(clipped.count == 1)
        #expect(clipped[0].width > 0)
    }

    // MARK: - 插入点与命中测试

    @Test func caretRectPositions() {
        let layout = makeLayout("alpha\nbeta")
        let start = layout.caretRect(for: 0)
        #expect(start.origin.x == 0)
        #expect(start.minY == 0)
        #expect(start.width == 2)
        #expect(start.height == layout.lineHeight)

        let lineEnd = layout.caretRect(for: 5)
        #expect(lineEnd.minY == 0)
        #expect(lineEnd.minX > 0)
        #expect(abs(lineEnd.minX - layout.layoutLine(number: 1).width) < 0.5)

        let secondLine = layout.caretRect(for: 6)
        #expect(secondLine.minY == layout.lineHeight)
        #expect(secondLine.minX == 0)

        // 越界偏移夹取到文档末尾。
        let end = layout.caretRect(for: 999)
        #expect(end.minY == layout.lineHeight)
        #expect(end.minX > 0)
    }

    @Test func hitTesting() {
        let layout = makeLayout("alpha\nbeta\ngamma")
        #expect(layout.index(at: CGPoint(x: 0, y: 0)) == 0)
        #expect(layout.index(at: CGPoint(x: -20, y: 0)) == 0)
        #expect(layout.index(at: CGPoint(x: 10_000, y: 0)) == 5)
        #expect(layout.index(at: CGPoint(x: 0, y: layout.lineHeight + 1)) == 6)
        #expect(layout.index(at: CGPoint(x: 10_000, y: layout.lineHeight + 1)) == 10)
        #expect(layout.index(at: CGPoint(x: 0, y: layout.lineHeight * 2)) == 11)
        #expect(layout.index(at: CGPoint(x: 0, y: 10_000)) == 11)
    }

    @Test func emptyLineHitTesting() {
        let layout = makeLayout("a\n\nb")
        #expect(layout.index(at: CGPoint(x: 0, y: layout.lineHeight)) == 2)
        #expect(layout.index(at: CGPoint(x: 500, y: layout.lineHeight)) == 2)
        #expect(layout.caretRect(for: 2).minX == 0)
    }

    @Test func verticalDestinationKeepsColumn() {
        let layout = makeLayout("alpha\nbeta\ngamma")
        #expect(
            layout.verticalDestination(
                from: 0,
                toY: layout.lineHeight * 2,
                x: 0
            ) == 11
        )
        #expect(
            layout.verticalDestination(
                from: 2,
                toY: layout.lineHeight,
                x: 10_000
            ) == 10
        )
        #expect(
            layout.verticalDestination(from: 0, toY: 0, x: 0) == 0
        )
    }

    // MARK: - 字体细节

    @Test func tabAdvancesToTabInterval() {
        let tabLayout = makeLayout("\ta")
        let plainLayout = makeLayout("a")
        let tabWidth = tabLayout.layoutLine(number: 1).width
        let plainWidth = plainLayout.layoutLine(number: 1).width
        #expect(tabWidth > plainWidth)
        #expect(tabWidth >= theme.tabInterval)
    }

    @Test func cjkAndEmojiLayout() {
        let layout = makeLayout("你好😀")
        let line = layout.layoutLine(number: 1)
        #expect(line.width > 0)
        #expect(line.contentRange.length == 4)

        let endCaret = layout.caretRect(for: 4)
        #expect(abs(endCaret.minX - line.width) < 0.5)
        #expect(layout.index(at: CGPoint(x: 10_000, y: 0)) == 4)

        let middleCaret = layout.caretRect(for: 2)
        #expect(middleCaret.minX > 0)
        #expect(middleCaret.minX < line.width)
    }

    @Test func lineRangesUseUniformLineHeight() {
        let layout = makeLayout("a\nbb\n\nccc\nd")
        #expect(layout.lineCount == 5)
        for line in 1...5 {
            #expect(layout.y(forLine: line) == CGFloat(line - 1) * layout.lineHeight)
            #expect(layout.caretRect(for: 0).height == layout.lineHeight)
        }
        #expect(layout.documentHeight == layout.lineHeight * 5)
    }
}
