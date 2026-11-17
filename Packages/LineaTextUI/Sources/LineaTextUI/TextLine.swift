import CoreGraphics
import CoreText
import Foundation

/// 一行已排版的文本。
///
/// `lineNumber` 从 1 开始；`contentRange` 不含行终止符；
/// 空行也会生成一个空的 `CTLine`，便于统一的几何计算。
public struct TextLine {
    public let number: Int
    public let lineRange: NSRange
    public let contentRange: NSRange
    public let line: CTLine
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let leading: CGFloat

    public init(
        number: Int,
        lineRange: NSRange,
        contentRange: NSRange,
        line: CTLine,
        width: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        leading: CGFloat
    ) {
        self.number = number
        self.lineRange = lineRange
        self.contentRange = contentRange
        self.line = line
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
    }

    public var isEmpty: Bool {
        contentRange.length == 0
    }
}
