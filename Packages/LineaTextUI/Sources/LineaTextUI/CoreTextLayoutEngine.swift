import CoreGraphics
import CoreText
import Foundation
import LineaCore

/// 固定行高 + 视口虚拟化的 CoreText 布局实现。
///
/// - 只为实际访问的行创建 `CTLine`，打开 10 万行文档不会排版全文。
/// - 行高固定，y 坐标可直接由行号算出。
/// - 缓存按行号索引；文本变化时整体清空，下一帧只重排可见行。
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

        var defaultTabInterval = tabInterval
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
        let text = engine.substring(in: contentRange)
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let ctLine = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(
            CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
        )

        let result = TextLine(
            number: line,
            lineRange: lineRange,
            contentRange: contentRange,
            line: ctLine,
            width: width,
            ascent: ascent,
            descent: descent,
            leading: leading
        )
        lineCache[line] = result
        layoutCount += 1
        if width > measuredMaxWidth {
            measuredMaxWidth = width
        }
        if lineCache.count > cacheLimit {
            // 简单策略：长距离滚动后整体丢弃，下一次只重排可见行。
            lineCache.removeAll(keepingCapacity: true)
            lineCache[line] = result
        }
        return result
    }

    public func invalidateLayout() {
        lineCache.removeAll(keepingCapacity: true)
        measuredMaxWidth = 0
    }

    // MARK: - 范围几何

    public func rects(for range: NSRange) -> [CGRect] {
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        let length = engine.length
        guard range.location >= 0, range.location <= length else { return [] }
        let end = min(length, range.location + range.length)
        guard end > range.location else { return [] }

        let firstLine = lineNumber(atY: y(forLine: engine.lineNumber(at: range.location)))
        let lastOffset = end - 1
        let lastLine = engine.lineNumber(at: lastOffset)

        var rects: [CGRect] = []
        rects.reserveCapacity(lastLine - firstLine + 1)
        for lineNumber in firstLine...lastLine {
            let textLine = layoutLine(number: lineNumber)
            let contentStart = textLine.contentRange.location
            let contentEnd = contentStart + textLine.contentRange.length
            let start = max(range.location, contentStart)
            let lineEnd = min(end, contentEnd)
            guard lineEnd > start else { continue }

            let x1 = xOffset(forLocalOffset: start - contentStart, in: textLine)
            let x2 = xOffset(forLocalOffset: lineEnd - contentStart, in: textLine)
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
        let x = xOffset(forLocalOffset: local, in: textLine)
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
        let contentStart = textLine.contentRange.location
        let length = textLine.contentRange.length
        guard length > 0 else { return contentStart }

        let x = max(0, point.x)
        let index = CTLineGetStringIndexForPosition(
            textLine.line,
            CGPoint(x: x, y: 0)
        )
        guard index != kCFNotFound else {
            return x >= textLine.width ? contentStart + length : contentStart
        }
        return contentStart + min(max(0, index), length)
    }

    public func verticalDestination(from offset: Int, toY y: CGFloat, x: CGFloat) -> Int {
        let clamped = min(max(0, offset), engine.length)
        let targetY = clamped == engine.length && y > documentHeight
            ? documentHeight - 1
            : y
        let lineNumber = lineNumber(atY: targetY)
        let textLine = layoutLine(number: lineNumber)
        let contentStart = textLine.contentRange.location
        let contentEnd = contentStart + textLine.contentRange.length
        guard contentEnd > contentStart else { return contentStart }

        let index = CTLineGetStringIndexForPosition(
            textLine.line,
            CGPoint(x: max(0, x), y: 0)
        )
        guard index != kCFNotFound else {
            return max(0, x) >= textLine.width ? contentEnd : contentStart
        }
        return contentStart + min(max(0, index), contentEnd - contentStart)
    }

    // MARK: - 工具

    private func xOffset(forLocalOffset localOffset: Int, in line: TextLine) -> CGFloat {
        let length = line.contentRange.length
        let index = min(max(0, localOffset), length)
        var secondary: CGFloat = 0
        return CTLineGetOffsetForStringIndex(line.line, index, &secondary)
    }
}
