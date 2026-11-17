import CoreGraphics
import Foundation

/// 固定行高布局的纯几何计算，便于单元测试。
public enum TextGeometry {
    /// 把行号夹取到 `1...lineCount`。
    public static func clampedLine(_ line: Int, lineCount: Int) -> Int {
        min(max(1, line), max(1, lineCount))
    }

    /// 第 line 行的顶部 y 坐标。
    public static func y(forLine line: Int, lineHeight: CGFloat) -> CGFloat {
        CGFloat(max(0, line - 1)) * lineHeight
    }

    /// y 所在行号；负坐标归入第一行。
    public static func lineNumber(
        forY y: CGFloat,
        lineHeight: CGFloat,
        lineCount: Int
    ) -> Int {
        guard lineHeight > 0 else { return 1 }
        let raw = Int(floor(max(0, y) / lineHeight)) + 1
        return clampedLine(raw, lineCount: lineCount)
    }

    /// 与 rect 相交的行号范围。空矩形返回空范围。
    public static func lines(
        in rect: CGRect,
        lineHeight: CGFloat,
        lineCount: Int
    ) -> Range<Int> {
        guard lineHeight > 0, lineCount > 0, rect.width > 0, rect.height > 0 else {
            return 1..<1
        }
        let first = lineNumber(forY: rect.minY, lineHeight: lineHeight, lineCount: lineCount)
        let last = lineNumber(
            forY: max(rect.minY, rect.maxY - 0.001),
            lineHeight: lineHeight,
            lineCount: lineCount
        )
        return first..<(last + 1)
    }
}
