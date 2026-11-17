import CoreGraphics
import CoreText
import Foundation
import LineaCore

/// 固定行高 + 视口虚拟化的 CoreText 布局实现。
///
/// - 只为实际访问的行创建 `CTLine`，打开 10 万行文档不会排版全文。
/// - 行高固定，y 坐标可直接由行号算出。
/// - 缓存按行号索引；文本变化时整体清空，下一帧只重排可见行。
/// - 超长行按 4K 分块，只创建可见块，避免百万字符单行拖垮整帧。
/// - 选区/光标矩形按行相交计算，不在视图层创建逐光标子视图。
public final class CoreTextLayoutEngine: TextLayoutEngine {
    public let lineHeight: CGFloat
    public let baselineOffset: CGFloat

    public var documentHeight: CGFloat {
        CGFloat(lineCount) * lineHeight
    }
    public var documentWidth: CGFloat {
        max(viewportWidth, measuredMaxWidth)
    }

    public var viewportWidth: CGFloat = 0 {
        didSet {
            if viewportWidth < 0 { viewportWidth = 0 }
        }
    }

    public var lineCount: Int {
        engine.lineCount
    }

    /// 布局缓存上限；长距离滚动时清空重建，避免缓存无限增长。
    private let cacheLimit = 2_048

    private let engine: EditorEngine
    private let font: CTFont
    private let attributes: [NSAttributedString.Key: Any]
    private let tabInterval: CGFloat
    /// 等宽字体单字符 advance，用于超长行宽度估算。
    private let baseAdvance: CGFloat
    private var lineCache: [Int: TextLine] = [:]
    private var measuredMaxWidth: CGFloat = 0

    /// 布局/缓存统计，供性能测试使用。
    public private(set) var layoutCount = 0

    public init(
        engine: EditorEngine,
        font: CTFont,
        tabInterval: CGFloat = 28,
        lineHeightMultiple: CGFloat = 1.2
    ) {
        self.engine = engine
        self.font = font
        self.lineHeight = ceil(
            (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
                * lineHeightMultiple
        )
        self.baselineOffset = CTFontGetAscent(font)
        let interval = max(tabInterval, 0.1)
        self.tabInterval = interval
        self.baseAdvance = Self.monospaceAdvance(font: font)

        var defaultTabInterval = interval
        // CTParagraphStyleSetting 只保存指针直到 CTParagraphStyleCreate 返回，
        // 用 withUnsafeBytes 把值的生命周期显式限制在本次调用内。
        let paragraphStyle = withUnsafeBytes(of: &defaultTabInterval) { bytes in
            var setting = CTParagraphStyleSetting(
                spec: .defaultTabInterval,
                valueSize: MemoryLayout<CGFloat>.size,
                value: bytes.baseAddress!
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        self.attributes = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
            // 颜色由绘制时的 context 填充色决定，主题切换不需要重建 CTLine。
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
    }

    // MARK: - 行几何

    public func y(forLine line: Int) -> CGFloat {
        TextGeometry.y(
            forLine: TextGeometry.clampedLine(line, lineCount: lineCount),
            lineHeight: lineHeight
        )
    }

    public func lineNumber(atY y: CGFloat) -> Int {
        TextGeometry.lineNumber(
            forY: y,
            lineHeight: lineHeight,
            lineCount: lineCount
        )
    }

    public func lines(in rect: CGRect) -> Range<Int> {
        TextGeometry.lines(
            in: rect,
            lineHeight: lineHeight,
            lineCount: lineCount
        )
    }

    // MARK: - 行排版

    public func layoutLine(number: Int) -> TextLine {
        let line = TextGeometry.clampedLine(number, lineCount: lineCount)
        if let cached = lineCache[line] {
            return cached
        }

        let lineRange = engine.lineRange(at: line)
        let contentRange = engine.lineContentRange(at: line)
        let fontAscent = CTFontGetAscent(font)
        let fontDescent = CTFontGetDescent(font)
        let fontLeading = CTFontGetLeading(font)

        let result: TextLine
        if contentRange.length > LongLineLayout.threshold,
           let chunked = LongLineLayout(
               units: engine.utf16Units(in: contentRange),
               contentRange: contentRange,
               font: font,
               attributes: attributes,
               tabInterval: tabInterval,
               baseAdvance: baseAdvance,
               onWidthChange: { [weak self] width in
                   guard let self, width > self.measuredMaxWidth else { return }
                   self.measuredMaxWidth = width
               }
           ) {
            result = TextLine(
                number: line,
                lineRange: lineRange,
                contentRange: contentRange,
                width: chunked.totalWidth,
                ascent: fontAscent,
                descent: fontDescent,
                leading: fontLeading,
                fragment: nil,
                chunkLayout: chunked
            )
        } else {
            let text = engine.substring(in: contentRange)
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attributed)

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(
                CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
            )
            let fragment = TextFragment(
                contentRange: contentRange,
                line: ctLine,
                x: 0,
                width: width,
                ascent: ascent,
                descent: descent,
                leading: leading
            )
            result = TextLine(
                number: line,
                lineRange: lineRange,
                contentRange: contentRange,
                width: width,
                ascent: ascent,
                descent: descent,
                leading: leading,
                fragment: fragment,
                chunkLayout: nil
            )
        }

        lineCache[line] = result
        layoutCount += 1
        if result.width > measuredMaxWidth {
            measuredMaxWidth = result.width
        }
        if lineCache.count > cacheLimit {
            // 简单策略：长距离滚动后整体丢弃，下一次只重排可见行。
            lineCache.removeAll(keepingCapacity: true)
            lineCache[line] = result
        }
        return result
    }

    public func fragments(
        forLine line: Int,
        intersecting xRange: ClosedRange<CGFloat>
    ) -> [TextFragment] {
        let textLine = layoutLine(number: line)
        if let fragment = textLine.fragment {
            guard !textLine.isEmpty else { return [] }
            let end = fragment.x + fragment.width
            guard end >= xRange.lowerBound, fragment.x <= xRange.upperBound else {
                return []
            }
            return [fragment]
        }
        return textLine.chunkLayout?.fragments(intersecting: xRange) ?? []
    }

    public func invalidateLayout() {
        lineCache.removeAll(keepingCapacity: true)
        measuredMaxWidth = 0
    }

    // MARK: - 偏移与 x 互转

    public func x(forLine line: Int, localOffset: Int) -> CGFloat {
        let textLine = layoutLine(number: line)
        let local = min(max(0, localOffset), textLine.contentRange.length)
        if let fragment = textLine.fragment {
            var secondary: CGFloat = 0
            return CTLineGetOffsetForStringIndex(
                fragment.line,
                local,
                &secondary
            )
        }
        if let chunkLayout = textLine.chunkLayout {
            return chunkLayout.x(forLocalOffset: local)
        }
        return 0
    }

    public func localOffset(forLine line: Int, atX x: CGFloat) -> Int {
        let textLine = layoutLine(number: line)
        let length = textLine.contentRange.length
        if let fragment = textLine.fragment {
            guard length > 0 else { return 0 }
            let clampedX = max(0, x)
            let index = CTLineGetStringIndexForPosition(
                fragment.line,
                CGPoint(x: clampedX, y: 0)
            )
            guard index != kCFNotFound else {
                return clampedX >= fragment.width ? length : 0
            }
            return min(max(0, index), length)
        }
        if let chunkLayout = textLine.chunkLayout {
            return chunkLayout.localOffset(atX: x)
        }
        return 0
    }

    // MARK: - 范围几何

    public func rects(for range: NSRange) -> [CGRect] {
        rects(
            for: range,
            intersectingLines: 1..<(lineCount + 1)
        )
    }

    public func rects(
        for range: NSRange,
        intersectingLines lineRange: Range<Int>
    ) -> [CGRect] {
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        let length = engine.length
        guard range.location >= 0, range.location <= length else { return [] }
        let end = min(length, range.location + range.length)
        guard end > range.location else { return [] }
        guard !lineRange.isEmpty else { return [] }

        let firstLine = max(
            engine.lineNumber(at: range.location),
            lineRange.lowerBound
        )
        let lastLine = min(
            engine.lineNumber(at: end - 1),
            lineRange.upperBound - 1
        )
        guard firstLine <= lastLine else { return [] }

        var rects: [CGRect] = []
        rects.reserveCapacity(lastLine - firstLine + 1)
        for lineNumber in firstLine...lastLine {
            let textLine = layoutLine(number: lineNumber)
            let contentStart = textLine.contentRange.location
            let contentEnd = contentStart + textLine.contentRange.length
            let start = max(range.location, contentStart)
            let lineEnd = min(end, contentEnd)
            guard lineEnd > start else { continue }

            let x1 = x(forLine: lineNumber, localOffset: start - contentStart)
            let x2 = x(forLine: lineNumber, localOffset: lineEnd - contentStart)
            guard x2 >= x1 else { continue }
            rects.append(
                CGRect(
                    x: x1,
                    y: y(forLine: lineNumber),
                    width: x2 - x1,
                    height: lineHeight
                )
            )
        }
        return rects
    }

    public func caretRect(for offset: Int) -> CGRect {
        let clamped = min(max(0, offset), engine.length)
        let lineNumber = engine.lineNumber(at: clamped)
        let textLine = layoutLine(number: lineNumber)
        let local = min(
            max(0, clamped - textLine.contentRange.location),
            textLine.contentRange.length
        )
        let x = x(forLine: lineNumber, localOffset: local)
        return CGRect(
            x: x,
            y: y(forLine: lineNumber),
            width: 2,
            height: lineHeight
        )
    }

    public func index(at point: CGPoint) -> Int {
        let lineNumber = lineNumber(atY: point.y)
        let textLine = layoutLine(number: lineNumber)
        let local = localOffset(forLine: lineNumber, atX: max(0, point.x))
        return textLine.contentRange.location + local
    }

    public func verticalDestination(from offset: Int, toY y: CGFloat, x: CGFloat) -> Int {
        let clamped = min(max(0, offset), engine.length)
        let targetY = clamped == engine.length && y > documentHeight
            ? documentHeight - 1
            : y
        let lineNumber = lineNumber(atY: targetY)
        let textLine = layoutLine(number: lineNumber)
        let local = localOffset(forLine: lineNumber, atX: max(0, x))
        return textLine.contentRange.location + local
    }

    // MARK: - 工具

    /// 取等宽字体 'a' 的 advance；失败时退回字号的大致宽度。
    private static func monospaceAdvance(font: CTFont) -> CGFloat {
        var character: UniChar = 0x61
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else {
            return CTFontGetSize(font) * 0.6
        }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return max(advance.width, 0.1)
    }
}
