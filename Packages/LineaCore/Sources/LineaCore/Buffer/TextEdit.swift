import Foundation

/// 一次文本替换。
///
/// 坐标语义：
/// - `range` 始终相对同一批 edits 的 **base 版本**（即调用 `apply(edits:)` 之前的文本）。
/// - 同一批中的 edits 必须按 location 升序、互不重叠。
/// - 缓冲区内部按降序应用，避免高位置编辑影响低位置坐标。
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    /// replacement 的 UTF-16 长度，避免热路径反复创建 NSString。
    public var replacementLength: Int {
        replacement.utf16.count
    }

    /// 空操作：不删除也不插入。
    public var isEmpty: Bool {
        range.length == 0 && replacement.isEmpty
    }
}
