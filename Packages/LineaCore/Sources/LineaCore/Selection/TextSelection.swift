import Foundation

/// 光标在换行位置的亲和度。
///
/// 当前产品只使用 `.downstream`，保留字段是为了与 NSTextSelection 的语义对齐，
/// 并将来的双向文本/软换行不需要改公开类型。
public enum TextAffinity: Equatable, Hashable, Sendable {
    case upstream
    case downstream
}

/// 一个选区。坐标是 UTF-16 偏移，`range.length == 0` 表示光标。
public struct TextSelection: Equatable, Hashable, Sendable {
    public var range: NSRange
    public var affinity: TextAffinity

    public init(range: NSRange, affinity: TextAffinity = .downstream) {
        self.range = range
        self.affinity = affinity
    }

    public static func caret(
        at offset: Int,
        affinity: TextAffinity = .downstream
    ) -> TextSelection {
        TextSelection(range: NSRange(location: offset, length: 0), affinity: affinity)
    }

    /// 选区的活动端（插入光标位置）。
    public var insertionOffset: Int {
        range.location + range.length
    }

    public var isCaret: Bool {
        range.length == 0
    }
}
