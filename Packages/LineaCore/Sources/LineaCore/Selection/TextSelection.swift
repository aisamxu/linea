import Foundation

/// 一个选区。坐标是 UTF-16 偏移，`range.length == 0` 表示光标。
public struct TextSelection: Equatable, Hashable, Sendable {
    public var range: NSRange

    public init(range: NSRange) {
        self.range = range
    }

    public static func caret(at offset: Int) -> TextSelection {
        TextSelection(range: NSRange(location: offset, length: 0))
    }

    /// 选区的活动端（插入光标位置）。
    public var insertionOffset: Int {
        range.location + range.length
    }

    public var isCaret: Bool {
        range.length == 0
    }
}
