import AppKit
import CoreText

/// 编辑器视觉主题与字体度量。
///
/// 字体、行高和 tab 间隔固定（当前产品无缩放、无字体面板）；
/// 颜色使用动态系统色，跟随浅色/深色外观。
public struct TextTheme {
    public var font: CTFont
    public var tabInterval: CGFloat
    public var lineHeightMultiple: CGFloat

    public var background: NSColor
    public var text: NSColor
    public var selection: NSColor
    public var caret: NSColor
    public var lineNumber: NSColor
    public var lineNumberSeparator: NSColor

    /// 行号 ruler 使用 11pt 等宽数字字体，与 1.0.2 对齐。
    public var lineNumberFont: NSFont

    public init(
        font: CTFont? = nil,
        tabInterval: CGFloat = 28,
        lineHeightMultiple: CGFloat = 1.2,
        background: NSColor = .textBackgroundColor,
        text: NSColor = .textColor,
        selection: NSColor = .selectedTextBackgroundColor,
        caret: NSColor = .textColor,
        lineNumber: NSColor = .secondaryLabelColor,
        lineNumberSeparator: NSColor = .separatorColor,
        lineNumberFont: NSFont? = nil
    ) {
        self.font = font ?? Self.defaultFont()
        self.tabInterval = tabInterval
        self.lineHeightMultiple = lineHeightMultiple
        self.background = background
        self.text = text
        self.selection = selection
        self.caret = caret
        self.lineNumber = lineNumber
        self.lineNumberSeparator = lineNumberSeparator
        self.lineNumberFont = lineNumberFont
            ?? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    }

    public static let standard = TextTheme()

    public var ascent: CGFloat { CTFontGetAscent(font) }
    public var descent: CGFloat { CTFontGetDescent(font) }
    public var leading: CGFloat { CTFontGetLeading(font) }

    /// 固定行高。取整避免滚动时行间出现亚像素缝隙。
    public var lineHeight: CGFloat {
        ceil((ascent + descent + leading) * lineHeightMultiple)
    }

    /// 基线在行内的偏移。按计划统一使用 ascent，额外行距留在基线下方。
    public var baselineOffset: CGFloat { ascent }

    private static func defaultFont() -> CTFont {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        return CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
    }
}
