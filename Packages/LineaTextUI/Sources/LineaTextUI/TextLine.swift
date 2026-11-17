import CoreGraphics
import CoreText
import Foundation

/// 一行中可直接绘制的一段文本。
///
/// 短行只有一个片段；超长行按 4K UTF-16 分块，每个可见块对应一个片段。
/// `x` 是片段在逻辑行内的起点，`contentRange` 是文档中的 UTF-16 范围。
public struct TextFragment {
    public let contentRange: NSRange
    public let line: CTLine
    public let x: CGFloat
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let leading: CGFloat

    public init(
        contentRange: NSRange,
        line: CTLine,
        x: CGFloat,
        width: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        leading: CGFloat
    ) {
        self.contentRange = contentRange
        self.line = line
        self.x = x
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
    }
}

/// 一行已排版的文本。
///
/// `lineNumber` 从 1 开始；`contentRange` 不含行终止符；
/// 空行也会生成一个空的 `CTLine`，便于统一的几何计算。
/// 超长行不会构造整行 `CTLine`，`fragment` 为 nil，按需通过布局引擎取可见块。
public struct TextLine {
    public let number: Int
    public let lineRange: NSRange
    public let contentRange: NSRange
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let leading: CGFloat

    /// 短行的唯一文本片段；超长行按需生成片段，这里为 nil。
    public let fragment: TextFragment?
    /// 超长行分块布局；与 `TextLine` 一起缓存/释放。
    let chunkLayout: LongLineLayout?

    init(
        number: Int,
        lineRange: NSRange,
        contentRange: NSRange,
        width: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        leading: CGFloat,
        fragment: TextFragment?,
        chunkLayout: LongLineLayout?
    ) {
        self.number = number
        self.lineRange = lineRange
        self.contentRange = contentRange
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        self.fragment = fragment
        self.chunkLayout = chunkLayout
    }

    public var isEmpty: Bool {
        contentRange.length == 0
    }
}
