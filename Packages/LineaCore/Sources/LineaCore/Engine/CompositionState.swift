import Foundation

/// 输入法组合状态。组合期间 buffer 不变，只影响视图渲染。
///
/// - `baseSelections`：开始组合时的选区快照；提交时用它构造编辑。
/// - `markedText`：当前组合文本（尚未写入 buffer）。
/// - `selectedRange`：`markedText` 内部的选区，UTF-16 偏移。
/// - `replacementRange`：输入法显式指定的替换范围（base 坐标），未知时为 `NSNotFound`。
public struct CompositionState: Equatable, Sendable {
    public var baseSelections: [TextSelection]
    public var markedText: String
    public var selectedRange: NSRange
    public var replacementRange: NSRange

    public init(
        baseSelections: [TextSelection],
        markedText: String = "",
        selectedRange: NSRange = NSRange(location: 0, length: 0),
        replacementRange: NSRange = NSRange(location: NSNotFound, length: 0)
    ) {
        self.baseSelections = baseSelections
        self.markedText = markedText
        self.selectedRange = selectedRange
        self.replacementRange = replacementRange
    }

    public var markedTextLength: Int {
        markedText.utf16.count
    }
}
