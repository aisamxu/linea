import AppKit
import CoreText

/// 编辑器视觉主题与字体度量。
///
/// 默认 13pt 等宽字体；App 层可通过 `standard(fontSize:)` 调整字号并持久化。
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

    /// 按字号生成主题。
    ///
    /// 行号字号随正文等比缩放（13pt 正文对应 11pt 行号），
    /// 避免放大后行号显得过小；最小 9pt 保证可读性。
    public static func standard(fontSize: CGFloat) -> TextTheme {
        let size = max(1, fontSize)
        let lineNumberSize = max(9, (size * 11 / 13).rounded())
        return TextTheme(
            font: font(ofSize: size),
            lineNumberFont: .monospacedDigitSystemFont(
                ofSize: lineNumberSize,
                weight: .regular
            )
        )
    }

    public var fontSize: CGFloat { CTFontGetSize(font) }

    public var ascent: CGFloat { CTFontGetAscent(font) }
    public var descent: CGFloat { CTFontGetDescent(font) }
    public var leading: CGFloat { CTFontGetLeading(font) }

    /// 固定行高。取整避免滚动时行间出现亚像素缝隙。
    public var lineHeight: CGFloat {
        ceil((ascent + descent + leading) * lineHeightMultiple)
    }

    private static func defaultFont() -> CTFont {
        font(ofSize: 13)
    }

    private static func font(ofSize size: CGFloat) -> CTFont {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
    }
}
