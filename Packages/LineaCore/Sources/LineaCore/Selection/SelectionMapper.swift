import Foundation

/// 把一批选区映射到「批量编辑完成后」的文本坐标。
///
/// 规则与 1.0.2 的 MultiCursorSelectionAdjuster 一致：
/// - 选区与编辑相交：折叠到替换文本末尾。
/// - 光标正好落在编辑起点（无论是插入还是删除）：折叠到替换文本末尾。
/// - 选区完全在编辑之后：按编辑的净长度变化平移。
/// - 选区完全在编辑之前：不变。
///
/// `applied` 按 base 坐标升序；选区可以是乱序的（最后一个仍是主选区），
/// 每个选区独立用二分查找定位相关编辑，避免 k×k 扫描。
enum SelectionMapper {
    static func map(
        _ selections: [TextSelection],
        through applied: [AppliedEdit]
    ) -> [TextSelection] {
        guard !applied.isEmpty else { return selections }

        // deltaBefore[i] 表示前 i 个编辑造成的净长度变化。
        var deltaBefore = [Int](repeating: 0, count: applied.count + 1)
        for (index, edit) in applied.enumerated() {
            deltaBefore[index + 1] = deltaBefore[index]
                + edit.replacementLength - edit.rangeInBase.length
        }

        return selections.map { selection in
            let start = selection.range.location
            let end = start + selection.range.length

            // A：第一个 end > start 的编辑；它之前的编辑都完全在选区左侧。
            let firstCandidate = firstIndexEndingAfter(start, in: applied)
            // B：候选编辑的上界。
            // - 非空选区：start >= end 的编辑已在选区右侧；
            // - 光标：start > caret 的编辑在光标右侧。
            let boundary: Int
            if selection.range.length == 0 {
                boundary = firstIndexStartingAfter(start, in: applied)
            } else {
                boundary = firstIndexStartingAtOrAfter(end, in: applied)
            }

            if firstCandidate < boundary {
                // 区间内所有编辑都与选区相交。1.0.2 按降序应用编辑，
                // 最终折叠位置由最靠后的那个编辑决定。
                let edit = applied[boundary - 1]
                let caret = edit.rangeInResult.location + edit.rangeInResult.length
                return TextSelection(
                    range: NSRange(location: caret, length: 0),
                    affinity: selection.affinity
                )
            }

            // 没有相交编辑：按左侧编辑的累计 delta 整体平移。
            let shift = deltaBefore[firstCandidate]
            return TextSelection(
                range: NSRange(location: start + shift, length: selection.range.length),
                affinity: selection.affinity
            )
        }
    }

    // MARK: - 二分查找

    private static func firstIndexEndingAfter(
        _ offset: Int,
        in applied: [AppliedEdit]
    ) -> Int {
        var low = 0
        var high = applied.count
        while low < high {
            let middle = (low + high) / 2
            let range = applied[middle].rangeInBase
            if range.location + range.length <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private static func firstIndexStartingAfter(
        _ offset: Int,
        in applied: [AppliedEdit]
    ) -> Int {
        var low = 0
        var high = applied.count
        while low < high {
            let middle = (low + high) / 2
            if applied[middle].rangeInBase.location <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private static func firstIndexStartingAtOrAfter(
        _ offset: Int,
        in applied: [AppliedEdit]
    ) -> Int {
        var low = 0
        var high = applied.count
        while low < high {
            let middle = (low + high) / 2
            if applied[middle].rangeInBase.location < offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
