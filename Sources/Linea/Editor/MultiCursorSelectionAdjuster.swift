import Foundation

/// 根据一次文本替换，把多光标选区映射到替换后的文本坐标。
///
/// STTextView 能一次替换多个选区，但 TextKit 在替换后会把多选区折叠成一个，
/// 导致下一次按键只写入一个光标。这里在每次替换前后维护一份期望选区，
/// 替换完成后写回，保持 Sublime 风格的连续多光标输入。
struct MultiCursorSelectionAdjuster: Equatable {
    private(set) var ranges: [NSRange]

    init(ranges: [NSRange]) {
        self.ranges = ranges
    }

    /// 在文本真正替换前调用，更新所有期望选区。
    mutating func apply(editRange: NSRange, replacementLength: Int) {
        ranges = ranges.map {
            Self.adjustedSelection(
                $0,
                editRange: editRange,
                replacementLength: replacementLength
            )
        }
    }

    /// 替换完成后把期望选区限制在新的文本长度内。
    mutating func clamp(to textLength: Int) {
        ranges = ranges.map {
            guard $0.location != NSNotFound else {
                return NSRange(location: 0, length: 0)
            }
            let safeLength = max(0, textLength)
            let location = min(max(0, $0.location), safeLength)
            let length = min(max(0, $0.length), safeLength - location)
            return NSRange(location: location, length: length)
        }
    }

    static func adjustedSelection(
        _ selection: NSRange,
        editRange: NSRange,
        replacementLength: Int
    ) -> NSRange {
        guard editRange.location != NSNotFound else { return selection }

        let editStart = max(0, editRange.location)
        let editEnd = editStart + max(0, editRange.length)
        let replacementEnd = editStart + max(0, replacementLength)
        let selectionStart = selection.location
        let selectionEnd = selectionStart + max(0, selection.length)

        let intersects = selectionStart < editEnd && selectionEnd > editStart
        let caretAtEditStart = selection.length == 0 && selectionStart == editStart

        if intersects || caretAtEditStart {
            // 选区被替换、光标位于插入点：落到替换文本末尾。
            return NSRange(location: replacementEnd, length: 0)
        }

        if selectionStart >= editEnd {
            // 选区完全在编辑之后，整体平移。
            return NSRange(
                location: max(0, selectionStart + replacementLength - editRange.length),
                length: selection.length
            )
        }

        return selection
    }
}
