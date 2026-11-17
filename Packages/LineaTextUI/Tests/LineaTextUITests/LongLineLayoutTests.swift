import AppKit
import CoreGraphics
import Foundation
import LineaCore
import Testing
@testable import LineaTextUI

@Suite("LongLineLayout")
struct LongLineLayoutTests {
    private let theme = TextTheme.standard

    private func makeLayout(_ text: String) -> (CoreTextLayoutEngine, EditorEngine) {
        let engine = EditorEngine(text: text)
        let layout = CoreTextLayoutEngine(
            engine: engine,
            font: theme.font,
            tabInterval: theme.tabInterval,
            lineHeightMultiple: theme.lineHeightMultiple
        )
        return (layout, engine)
    }

    private func makeBitmapContext(
        width: Int = 900,
        height: Int = 600
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

    // MARK: - 分块与惰性布局

    @Test func millionCharacterLineIsChunkedLazily() {
        let (layout, engine) = makeLayout(String(repeating: "a", count: 1_000_000))
        let line = layout.layoutLine(number: 1)

        #expect(line.fragment == nil)
        #expect(line.chunkLayout != nil)
        #expect(line.chunkLayout?.chunkRanges.count == 245)
        #expect(line.chunkLayout?.measuredCount == 0)
        #expect(line.contentRange.length == engine.length)
        #expect(line.width > 8_000_000)
    }

    @Test func visibleFragmentsOnlyMaterializeNearbyChunks() {
        let (layout, _) = makeLayout(String(repeating: "a", count: 1_000_000))
        let line = layout.layoutLine(number: 1)
        guard let chunked = line.chunkLayout else {
            Issue.record("超长行应启用分块布局")
            return
        }

        let fragments = layout.fragments(
            forLine: 1,
            intersecting: 0...400
        )
        #expect(!fragments.isEmpty)
        #expect(fragments[0].contentRange.location == 0)
        #expect(fragments[0].x == 0)
        #expect(chunked.measuredCount <= 2)

        // 再绘制一个远离行首的窗口，只应测量该窗口附近的块。
        let middle = chunked.totalWidth / 2
        let previous = chunked.measuredCount
        let middleFragments = layout.fragments(
            forLine: 1,
            intersecting: middle...(middle + 400)
        )
        #expect(!middleFragments.isEmpty)
        #expect(chunked.measuredCount - previous <= 8)
    }

    @Test func caretAtEndAndHitTestingUseChunkPrefix() {
        let (layout, engine) = makeLayout(String(repeating: "a", count: 1_000_000))
        let line = layout.layoutLine(number: 1)

        let endCaret = layout.caretRect(for: engine.length)
        #expect(abs(endCaret.minX - line.width) < 0.5)
        #expect(endCaret.minY == 0)

        let middleX = line.width / 2
        #expect(layout.index(at: CGPoint(x: middleX, y: 0)) == 500_000)
        #expect(layout.caretRect(for: 500_000).minX == middleX)

        let start = layout.index(at: CGPoint(x: 0, y: 0))
        #expect(start == 0)
        let end = layout.index(at: CGPoint(x: line.width + 100, y: 0))
        #expect(end == engine.length)
    }

    @Test func chunkBoundaryMapsBackToSameOffset() {
        let (layout, _) = makeLayout(String(repeating: "a", count: 1_000_000))
        let line = layout.layoutLine(number: 1)
        guard let chunked = line.chunkLayout else {
            Issue.record("超长行应启用分块布局")
            return
        }

        let boundary = chunked.chunkRanges[1].location
        let x = layout.x(forLine: 1, localOffset: boundary)
        let nextX = layout.x(forLine: 1, localOffset: boundary + 1)
        #expect(x > 0)
        #expect(nextX > x)
        #expect(nextX - x < 100)
        #expect(layout.localOffset(forLine: 1, atX: x) == boundary)
        // 命中测试选择最近的插入点，越过半个字符后才进入下一偏移。
        #expect(layout.localOffset(forLine: 1, atX: x + 6) == boundary + 1)
    }

    @Test func selectionNearStartOnlyMeasuresOneChunk() {
        let (layout, _) = makeLayout(String(repeating: "a", count: 1_000_000))
        let line = layout.layoutLine(number: 1)
        guard let chunked = line.chunkLayout else {
            Issue.record("超长行应启用分块布局")
            return
        }

        let rects = layout.rects(for: NSRange(location: 1, length: 1_000))
        #expect(rects.count == 1)
        #expect(rects[0].width > 0)
        #expect(chunked.measuredCount <= 2)
    }

    @Test func chunkBoundaryAvoidsSplittingSurrogatePair() {
        // 第一块理论边界落在 emoji 中间，应把 surrogate pair 并入前一块。
        let prefix = String(repeating: "a", count: LongLineLayout.chunkSize - 1)
        let text = prefix + "😀" + String(repeating: "b", count: 40_000)
        let (layout, _) = makeLayout(text)
        let line = layout.layoutLine(number: 1)
        guard let chunked = line.chunkLayout else {
            Issue.record("超长行应启用分块布局")
            return
        }

        let firstEnd = chunked.chunkRanges[0].location + chunked.chunkRanges[0].length
        #expect(firstEnd == LongLineLayout.chunkSize + 1)
        #expect(layout.localOffset(forLine: 1, atX: 1) == 0)
    }

    @Test func cjkAndEmojiLongLineIsUsable() {
        let text = String(repeating: "你好😀line", count: 50_000)
        let (layout, engine) = makeLayout(text)
        #expect(engine.lineCount == 1)
        let line = layout.layoutLine(number: 1)
        #expect(line.fragment == nil)
        #expect(line.width > 0)

        let fragments = layout.fragments(forLine: 1, intersecting: 0...400)
        #expect(!fragments.isEmpty)

        let caret = layout.caretRect(for: engine.lineContentRange(at: 1).length)
        #expect(caret.minX > 0)
        let hit = layout.index(at: CGPoint(x: caret.minX, y: 0))
        #expect(hit > 0)
    }

    // MARK: - 绘制

    @Test func rendererSelectAllOnlyLaysOutVisibleLines() {
        let text = String(repeating: "line\n", count: 99_999) + "line"
        let (layout, engine) = makeLayout(text)
        guard let context = makeBitmapContext() else {
            Issue.record("无法创建绘制 context")
            return
        }
        let renderer = TextRenderer(theme: theme)
        let dirty = CGRect(x: 0, y: 0, width: 900, height: 600)
        let selection = TextSelection(
            range: NSRange(location: 0, length: engine.length)
        )

        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            renderer.draw(
                in: context,
                dirtyRect: dirty,
                layout: layout,
                selections: [selection],
                caretVisible: false
            )
        }

        // 100k 行的全选，只应排版当前可见的几十行。
        #expect(layout.layoutCount > 0)
        #expect(layout.layoutCount <= 45)
    }

    @Test func rendererOnlyMaterializesVisibleChunksOfLongLine() {
        let (layout, _) = makeLayout(String(repeating: "a", count: 1_000_000))
        let line = layout.layoutLine(number: 1)
        guard let chunked = line.chunkLayout,
              let context = makeBitmapContext() else {
            Issue.record("无法准备长行绘制")
            return
        }

        let renderer = TextRenderer(theme: theme)
        let dirty = CGRect(
            x: 0,
            y: 0,
            width: 900,
            height: layout.lineHeight * 2
        )
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            renderer.draw(
                in: context,
                dirtyRect: dirty,
                layout: layout,
                selections: [],
                caretVisible: false
            )
        }

        #expect(layout.layoutCount == 1)
        #expect(chunked.measuredCount <= 2)
    }

    // MARK: - 性能 gate（Release 为结论，Debug 只做宽松护栏）

    @Test func millionCharacterLineFirstLayoutWithinBudget() {
        let text = String(repeating: "a", count: 1_000_000)
        let start = CFAbsoluteTimeGetCurrent()
        let (layout, engine) = makeLayout(text)
        _ = layout.layoutLine(number: 1)
        _ = layout.caretRect(for: engine.length)
        _ = layout.index(at: CGPoint(x: 4_000_000, y: 0))
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[LineaTextUI] 1M line first layout: \(elapsed) ms")

        #if DEBUG
        #expect(elapsed < 500)
        #else
        #expect(elapsed < 16)
        #endif
    }

    @Test func hundredThousandLinesFirstFrameWithinBudget() {
        let text = String(repeating: "line\n", count: 99_999) + "line"
        let start = CFAbsoluteTimeGetCurrent()
        let (layout, _) = makeLayout(text)
        let visible = CGRect(
            x: 0,
            y: 0,
            width: 900,
            height: 600
        )
        _ = layout.lines(in: visible)
        for line in 1...40 {
            _ = layout.layoutLine(number: line)
            _ = layout.fragments(forLine: line, intersecting: 0...900)
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[LineaTextUI] 100k lines first frame: \(elapsed) ms")

        #if DEBUG
        #expect(elapsed < 2_000)
        #else
        #expect(elapsed < 100)
        #endif
    }

    @Test func scrollingHundredThousandLinesFrameBudget() {
        let text = String(repeating: "line\n", count: 99_999) + "line"
        let (layout, _) = makeLayout(text)
        guard let context = makeBitmapContext(width: 900, height: 600) else {
            Issue.record("无法创建绘制 context")
            return
        }
        let renderer = TextRenderer(theme: theme)
        let visibleHeight = 600.0
        let lineHeight = layout.lineHeight

        // 预热首帧后，测量连续滚动 60 帧。
        var frameTimes: [Double] = []
        frameTimes.reserveCapacity(60)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            for index in 0..<60 {
                let y = CGFloat(index) * lineHeight * 20
                let rect = CGRect(x: 0, y: y, width: 900, height: visibleHeight)
                let start = CFAbsoluteTimeGetCurrent()
                renderer.draw(
                    in: context,
                    dirtyRect: rect,
                    layout: layout,
                    selections: [],
                    caretVisible: false
                )
                frameTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
        }
        let average = frameTimes.reduce(0, +) / Double(frameTimes.count)
        let maximum = frameTimes.max() ?? 0
        print(
            "[LineaTextUI] 100k lines scroll frame avg=\(average) ms "
                + "max=\(maximum) ms"
        )

        #if DEBUG
        #expect(average < 100)
        #else
        #expect(average < 8)
        #endif
    }
}
