import Foundation
import LineaTextUI

/// 编辑器全局偏好。
///
/// 字号用 `UserDefaults` 持久化，⌘+/⌘-/⌘0 调整后跨启动保留；
/// 所有窗口、所有标签共用同一字号。
enum EditorPreferences {
    static let fontSizeKey = "LineaEditorFontSize"
    static let defaultFontSize: CGFloat = 13
    /// 缩放范围：过小影响可读性，过大则单屏可见内容过少。
    static let fontSizeRange: ClosedRange<CGFloat> = 10...24

    static var fontSize: CGFloat {
        get { fontSize(in: .standard) }
        set { setFontSize(newValue, in: .standard) }
    }

    /// 读取指定偏好域的字号；测试可注入临时 `UserDefaults`，不污染真实配置。
    static func fontSize(in defaults: UserDefaults) -> CGFloat {
        let stored = defaults.object(forKey: fontSizeKey) as? Double
        return clamped(CGFloat(stored ?? Double(defaultFontSize)))
    }

    static func setFontSize(_ size: CGFloat, in defaults: UserDefaults) {
        defaults.set(Double(clamped(size)), forKey: fontSizeKey)
    }

    /// 字号取整，保证每次 ⌘+/⌘- 都稳定变化 1pt，并夹取到允许范围。
    static func clamped(_ size: CGFloat) -> CGFloat {
        min(max(size.rounded(), fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    static func theme(fontSize: CGFloat) -> TextTheme {
        TextTheme.standard(fontSize: clamped(fontSize))
    }

    static var theme: TextTheme {
        theme(fontSize: fontSize)
    }
}
