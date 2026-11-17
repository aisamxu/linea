import CoreGraphics
import CoreText
import Foundation

/// 超长行的分块布局。
///
/// 不构造整行 `CTLine`：
/// - 每块 4K UTF-16，切分点避开组合字符序列；
/// - 宽度先用等宽字体估算并建立前缀和，只有真正可见/命中的块才创建 `CTLine`；
/// - 实测宽度替换估算后，同步修正后续块的前缀和。
/// 这样百万字符单行也能在常数级块索引下绘制、命中与定位行尾。
final class LongLineLayout {
    static let chunkSize = 4 * 1024
    static let threshold = 32 * 1024

    struct Chunk {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let leading: CGFloat
    }

    let contentRange: NSRange
    /// 每块相对行内容起点的 UTF-16 范围。
    let chunkRanges: [NSRange]

    private let units: [UInt16]
    private let attributes: [NSAttributedString.Key: Any]
    private let onWidthChange: ((CGFloat) -> Void)?

    private var chunkCache: [Int: Chunk] = [:]
    /// 当前宽度（初始为估算值，测量后替换为精确值）。
    private var widths: [CGFloat]
    private var measured: [Bool]
    /// 前缀和，`prefix[i]` 是第 i 块之前的总宽。
    private var prefix: [CGFloat]

    /// 已创建 `CTLine` 的块数，供性能测试确认没有整行排版。
    private(set) var measuredCount = 0

    init?(
        units: [UInt16],
        contentRange: NSRange,
        font: CTFont,
        attributes: [NSAttributedString.Key: Any],
        tabInterval: CGFloat,
        baseAdvance: CGFloat,
        onWidthChange: ((CGFloat) -> Void)? = nil
    ) {
        guard contentRange.length > Self.threshold,
              units.count == contentRange.length
        else {
            return nil
        }

        let resolvedBaseAdvance = max(baseAdvance, 0.1)
        let resolvedTabInterval = max(tabInterval, 0.1)
        let resolvedWideAdvance = max(resolvedBaseAdvance, CTFontGetSize(font))
        self.contentRange = contentRange
        self.units = units
        self.attributes = attributes
        self.onWidthChange = onWidthChange

        // 1. 按 UTF-16 边界切块，并避开 surrogate pair / 组合符号。
        var ranges: [NSRange] = []
        ranges.reserveCapacity(units.count / Self.chunkSize + 1)
        var start = 0
        while start < units.count {
            var end = min(start + Self.chunkSize, units.count)
            if end < units.count {
                end = Self.adjustedChunkEnd(
                    end,
                    units: units,
                    start: start
                )
            }
            if end <= start {
                end = min(start + Self.chunkSize, units.count)
            }
            ranges.append(NSRange(location: start, length: end - start))
            start = end
        }
        self.chunkRanges = ranges

        // 2. 用等宽字体的字符宽度快速估算每块宽度，建立前缀和。
        var estimatedWidths = [CGFloat]()
        estimatedWidths.reserveCapacity(ranges.count)
        var cursor: CGFloat = 0
        for range in ranges {
            let estimate = Self.estimateWidth(
                units: units,
                range: range,
                startingX: cursor,
                baseAdvance: resolvedBaseAdvance,
                wideAdvance: resolvedWideAdvance,
                tabInterval: resolvedTabInterval
            )
            estimatedWidths.append(estimate)
            cursor += estimate
        }
        self.widths = estimatedWidths
        self.measured = Array(repeating: false, count: ranges.count)

        var prefix: [CGFloat] = [0]
        prefix.reserveCapacity(ranges.count + 1)
        for width in estimatedWidths {
            prefix.append(prefix[prefix.count - 1] + width)
        }
        self.prefix = prefix
    }

    var totalWidth: CGFloat {
        prefix[prefix.count - 1]
    }

    var localLength: Int {
        units.count
    }

    // MARK: - 几何

    /// 返回与水平范围相交的可见块；估算误差允许向两侧多取几块。
    func fragments(intersecting xRange: ClosedRange<CGFloat>) -> [TextFragment] {
        guard !chunkRanges.isEmpty else { return [] }
        let lower = max(0, xRange.lowerBound)
        let upper = max(lower, xRange.upperBound)
        var index = max(0, chunkIndex(atX: lower) - 4)
        var result: [TextFragment] = []
        result.reserveCapacity(8)

        while index < chunkRanges.count {
            let chunk = self.chunk(at: index)
            // 每次测量后 prefix 可能变化，因此循环内重新取起点。
            let start = prefix[index]
            let end = start + chunk.width
            if start > upper { break }
            if end >= lower {
                result.append(fragment(at: index, chunk: chunk))
            }
            index += 1
        }
        return result
    }

    /// 行内偏移对应的 x；不测量目标块之前的块。
    func x(forLocalOffset offset: Int) -> CGFloat {
        let local = min(max(0, offset), localLength)
        guard local > 0 else { return 0 }
        guard local < localLength else {
            // 行尾只需测量最后一块，之前块宽度继续使用估算前缀。
            _ = chunk(at: chunkRanges.count - 1)
            return totalWidth
        }

        let index = chunkIndex(forLocalOffset: local)
        let range = chunkRanges[index]
        let chunkEnd = range.location + range.length

        // 正好在块边界：归入下一块起点，并测量当前块以精确化前缀。
        if local == chunkEnd {
            _ = chunk(at: index)
            return prefix[index + 1]
        }

        let chunk = chunk(at: index)
        let intra = local - range.location
        var secondary: CGFloat = 0
        let x = CTLineGetOffsetForStringIndex(chunk.line, intra, &secondary)
        return prefix[index] + min(max(0, x), chunk.width)
    }

    /// x 对应的行内偏移；只测量命中块及修正估算误差所需的相邻块。
    func localOffset(atX x: CGFloat) -> Int {
        guard localLength > 0 else { return 0 }
        if x <= 0 { return 0 }
        if x >= totalWidth {
            // 先测量最后一块，再判断是否真的越过行尾。
            _ = chunk(at: chunkRanges.count - 1)
            if x >= totalWidth { return localLength }
        }

        var index = chunkIndex(atX: x)
        _ = chunk(at: index)

        // 估算前缀可能让目标块偏移，用实测宽度向两侧修正。
        while index > 0, x < prefix[index] {
            index -= 1
            _ = chunk(at: index)
        }
        while index < chunkRanges.count - 1, x > prefix[index + 1] {
            index += 1
            _ = chunk(at: index)
        }

        if x >= totalWidth {
            return localLength
        }

        let chunk = chunk(at: index)
        let origin = prefix[index]
        let localX = min(max(0, x - origin), chunk.width)
        let ctIndex = CTLineGetStringIndexForPosition(
            chunk.line,
            CGPoint(x: localX, y: 0)
        )
        let range = chunkRanges[index]
        let local: Int
        if ctIndex == kCFNotFound {
            local = localX >= chunk.width ? range.length : 0
        } else {
            local = min(max(0, ctIndex), range.length)
        }
        return range.location + local
    }

    // MARK: - 块

    private func chunk(at index: Int) -> Chunk {
        if let cached = chunkCache[index] {
            return cached
        }

        let range = chunkRanges[index]
        let lower = range.location
        let upper = lower + range.length
        // 只解码当前块；整行百万字符不会在这里一次性构造 String。
        let chunkText = String(decoding: units[lower..<upper], as: UTF16.self)
        let attributed = NSAttributedString(
            string: chunkText,
            attributes: attributes
        )
        let ctLine = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(
            CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
        )
        let result = Chunk(
            line: ctLine,
            width: width,
            ascent: ascent,
            descent: descent,
            leading: leading
        )
        chunkCache[index] = result
        measuredCount += 1

        if !measured[index] {
            measured[index] = true
            let delta = width - widths[index]
            widths[index] = width
            if abs(delta) > 0.001 {
                for i in (index + 1)..<prefix.count {
                    prefix[i] += delta
                }
                onWidthChange?(totalWidth)
            }
        }
        return result
    }

    private func fragment(at index: Int, chunk: Chunk) -> TextFragment {
        let local = chunkRanges[index]
        return TextFragment(
            contentRange: NSRange(
                location: contentRange.location + local.location,
                length: local.length
            ),
            line: chunk.line,
            x: prefix[index],
            width: chunk.width,
            ascent: chunk.ascent,
            descent: chunk.descent,
            leading: chunk.leading
        )
    }

    private func chunkIndex(atX x: CGFloat) -> Int {
        guard chunkRanges.count > 1 else { return 0 }
        if x <= 0 { return 0 }
        if x >= totalWidth { return chunkRanges.count - 1 }

        var low = 0
        var high = chunkRanges.count - 1
        while low < high {
            let mid = (low + high) / 2
            if prefix[mid + 1] <= x {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func chunkIndex(forLocalOffset offset: Int) -> Int {
        guard chunkRanges.count > 1 else { return 0 }
        if offset <= 0 { return 0 }
        if offset >= localLength { return chunkRanges.count - 1 }

        var low = 0
        var high = chunkRanges.count - 1
        while low < high {
            let mid = (low + high) / 2
            let range = chunkRanges[mid]
            if range.location + range.length <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    // MARK: - 估算

    /// 调整块边界：避免拆开 surrogate pair，并让组合符号跟随前一块的基字符。
    private static func adjustedChunkEnd(
        _ end: Int,
        units: [UInt16],
        start: Int
    ) -> Int {
        let limit = units.count
        var adjusted = end
        if adjusted > start,
           adjusted < limit,
           isHighSurrogate(units[adjusted - 1]),
           isLowSurrogate(units[adjusted])
        {
            adjusted += 1
        }
        while adjusted < limit, isZeroWidthMark(units[adjusted]) {
            adjusted += 1
        }
        return min(adjusted, limit)
    }

    /// 估算一块文本的宽度：ASCII/等宽字符精确，CJK/emoji 按宽字符近似。
    private static func estimateWidth(
        units: [UInt16],
        range: NSRange,
        startingX: CGFloat,
        baseAdvance: CGFloat,
        wideAdvance: CGFloat,
        tabInterval: CGFloat
    ) -> CGFloat {
        let end = range.location + range.length
        var width: CGFloat = 0
        var index = range.location
        while index < end {
            let code = units[index]

            // Tab 停靠点以整行原点为基准，不能按块重置。
            if code == 0x09 {
                let absolute = startingX + width
                let remainder = absolute.truncatingRemainder(dividingBy: tabInterval)
                width += remainder == 0 ? tabInterval : tabInterval - remainder
                index += 1
                continue
            }

            // surrogate pair（emoji 等）按一个宽字符估算。
            if isHighSurrogate(code), index + 1 < end, isLowSurrogate(units[index + 1]) {
                width += wideAdvance
                index += 2
                continue
            }

            if isZeroWidthMark(code) {
                index += 1
                continue
            }

            width += isWide(code) ? wideAdvance : baseAdvance
            index += 1
        }
        return width
    }

    private static func isHighSurrogate(_ code: UniChar) -> Bool {
        code >= 0xD800 && code <= 0xDBFF
    }

    private static func isLowSurrogate(_ code: UniChar) -> Bool {
        code >= 0xDC00 && code <= 0xDFFF
    }

    private static func isWide(_ code: UniChar) -> Bool {
        switch code {
        case 0x1100...0x115F,
             0x2E80...0xA4CF,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE10...0xFE19,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6:
            return true
        default:
            return false
        }
    }

    private static func isZeroWidthMark(_ code: UniChar) -> Bool {
        switch code {
        case 0x0300...0x036F,
             0x1AB0...0x1AFF,
             0x1DC0...0x1DFF,
             0x20D0...0x20FF,
             0xFE20...0xFE2F:
            return true
        default:
            return false
        }
    }
}
