import CoreGraphics
import Foundation

/// 文本布局引擎协议。
///
/// 首版由 `CoreTextLayoutEngine` 实现；将来替换布局/渲染实现时，
/// 视图和输入层不需要改变。所有坐标都是视图坐标（y 向下，isFlipped）。
public protocol TextLayoutEngine: AnyObject {
    var lineHeight: CGFloat { get }
    var lineCount: Int { get }
    var documentHeight: CGFloat { get }
    var documentWidth: CGFloat { get }

    /// 视口宽度参与文档宽度计算；窄文档至少与视口同宽。
    var viewportWidth: CGFloat { get set }

    /// 第 line 行（从 1 开始）的行顶 y。
    func y(forLine line: Int) -> CGFloat
    /// y 坐标所在行号，夹取到 1...lineCount。
    func lineNumber(atY y: CGFloat) -> Int
    /// 与矩形相交的行号范围（从 1 开始，半开）。
    func lines(in rect: CGRect) -> Range<Int>
    /// 排版并缓存一行。超长行只返回度量，片段按需生成。
    func layoutLine(number: Int) -> TextLine
    /// 取与水平范围相交的可见片段；短行返回唯一片段，超长行只生成可见块。
    func fragments(forLine line: Int, intersecting xRange: ClosedRange<CGFloat>) -> [TextFragment]
    /// 行内 UTF-16 偏移对应的 x（相对行首）。
    func x(forLine line: Int, localOffset: Int) -> CGFloat
    /// x（相对行首）对应的行内 UTF-16 偏移。
    func localOffset(forLine line: Int, atX x: CGFloat) -> Int

    /// 与 range 相交的逐行矩形，用于选区绘制。
    func rects(for range: NSRange) -> [CGRect]
    /// 只计算与指定可见行范围相交的矩形，避免全选时遍历整个文档。
    func rects(for range: NSRange, intersectingLines lineRange: Range<Int>) -> [CGRect]
    /// 插入点矩形（零宽 range 也会返回一个光标矩形）。
    func caretRect(for offset: Int) -> CGRect
    /// 点所在最接近的文本偏移。
    func index(at point: CGPoint) -> Int
    /// 垂直移动的目标偏移，尽量保持 x 对应的列。
    func verticalDestination(from offset: Int, toY y: CGFloat, x: CGFloat) -> Int

    /// 文本变化或字体变化后清空布局缓存。
    func invalidateLayout()
}
