import Foundation

/// 多选区集合。
///
/// 约定：
/// - 保持用户操作产生的顺序，**最后一个选区是主选区**（输入法候选窗、滚动跟随都依赖它）。
/// - 所有选区都 clamp 到 `0...textLength`。
/// - 完全重复的选区去重，重叠的选区合并；相邻但不重叠的选区保持独立。
/// - 不限制选区数量，⇧⌘L 可以把整篇文档的每一行都变成光标。
public struct SelectionModel: Equatable, Sendable {
    public private(set) var selections: [TextSelection]

    public init(selections: [TextSelection] = [.caret(at: 0)]) {
        self.selections = selections.isEmpty ? [.caret(at: 0)] : selections
    }

    /// 主选区；模型永远至少保留一个选区。
    public var primary: TextSelection {
        selections.last ?? .caret(at: 0)
    }

    public var count: Int {
        selections.count
    }

    public var ranges: [NSRange] {
        selections.map(\.range)
    }

    public subscript(index: Int) -> TextSelection {
        selections[index]
    }

    /// 写入新的选区集合；返回是否发生了变化。
    @discardableResult
    public mutating func set(
        _ input: [TextSelection],
        textLength: Int
    ) -> Bool {
        let normalized = Self.normalized(input, textLength: textLength)
        guard normalized != selections else { return false }
        selections = normalized
        return true
    }

    /// 文本长度变化后重新夹取所有选区，不改变顺序与重叠关系。
    public mutating func clamp(to textLength: Int) {
        selections = selections.map { Self.clamped($0, to: textLength) }
    }

    /// clamp + 去重 + 合并重叠。
    public static func normalized(
        _ input: [TextSelection],
        textLength: Int
    ) -> [TextSelection] {
        let clamped = (input.isEmpty ? [.caret(at: 0)] : input).map {
            Self.clamped($0, to: textLength)
        }

        // 常见路径：⌘D/⌃⌘G/⇧⌘L 产生的选区已按位置严格升序且互不重叠，
        // 直接返回。否则下面的两两比较在整篇文档级别会退化成 O(n²)。
        if isStrictlyAscendingNonOverlapping(clamped) {
            return clamped
        }

        var result: [TextSelection] = []
        result.reserveCapacity(clamped.count)

        for selection in clamped {
            var pending: TextSelection? = selection
            var index = 0
            while index < result.count, let current = pending {
                let existing = result[index]
                if existing.range == current.range {
                    // 完全重复：丢弃后出现的那个，保留原位置。
                    pending = nil
                    break
                }
                if Self.overlaps(existing.range, current.range) {
                    // 重叠：合并为并集，合并结果放到新选区的位置，
                    // 这样主选区（通常是新追加的那个）仍然排在最后。
                    let union = Self.unionRange(existing.range, current.range)
                    pending = TextSelection(range: union, affinity: current.affinity)
                    result.remove(at: index)
                    continue
                }
                index += 1
            }
            if let pending {
                result.append(pending)
            }
        }

        return result.isEmpty ? [.caret(at: 0)] : result
    }

    public static func clamped(_ selection: TextSelection, to textLength: Int) -> TextSelection {
        let safeLength = max(0, textLength)
        let range = selection.range
        guard range.location != NSNotFound else {
            return TextSelection(
                range: NSRange(location: 0, length: 0),
                affinity: selection.affinity
            )
        }
        let location = min(max(0, range.location), safeLength)
        let length = min(max(0, range.length), safeLength - location)
        return TextSelection(
            range: NSRange(location: location, length: length),
            affinity: selection.affinity
        )
    }

    // MARK: - 范围关系

    /// 是否严格升序且互不重叠。
    ///
    /// 只用于 `normalized` 的快速路径：满足该条件时无需去重/合并，
    /// 也不能把「光标正好停在选区首尾」误判为重叠。
    private static func isStrictlyAscendingNonOverlapping(
        _ selections: [TextSelection]
    ) -> Bool {
        guard selections.count > 1 else { return true }
        for index in 1..<selections.count {
            let previous = selections[index - 1].range
            let current = selections[index].range
            guard current.location > previous.location,
                  previous.location + previous.length <= current.location
            else {
                return false
            }
        }
        return true
    }

    /// 两个选区是否重叠。零长光标落在另一个选区内部视为重叠，
    /// 光标停在选区首尾则不算（这是文本编辑器的常规行为）。
    static func overlaps(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        if lhs.length == 0, rhs.length == 0 {
            return lhs.location == rhs.location
        }
        if lhs.length == 0 {
            return rhs.location < lhs.location
                && lhs.location < rhs.location + rhs.length
        }
        if rhs.length == 0 {
            return lhs.location < rhs.location
                && rhs.location < lhs.location + lhs.length
        }
        return lhs.location < rhs.location + rhs.length
            && rhs.location < lhs.location + lhs.length
    }

    static func unionRange(_ lhs: NSRange, _ rhs: NSRange) -> NSRange {
        let start = min(lhs.location, rhs.location)
        let end = max(lhs.location + lhs.length, rhs.location + rhs.length)
        return NSRange(location: start, length: end - start)
    }
}
