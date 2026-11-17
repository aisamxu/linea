import Foundation

/// 已应用编辑的结果描述，供视图精确失效、撤销和测试使用。
///
/// - `rangeInBase`：在编辑前文本中的范围。
/// - `rangeInResult`：在整批编辑完成后的文本中的范围。
/// - `removedText`：被删除的原文；历史条目只保存它，不保存整树快照。
public struct AppliedEdit: Equatable, Sendable {
    public let rangeInBase: NSRange
    public let rangeInResult: NSRange
    public let removedText: String
    public let replacement: String

    /// 替换文本的 UTF-16 长度。
    public var replacementLength: Int {
        rangeInResult.length
    }

    public init(
        rangeInBase: NSRange,
        rangeInResult: NSRange,
        removedText: String,
        replacement: String
    ) {
        self.rangeInBase = rangeInBase
        self.rangeInResult = rangeInResult
        self.removedText = removedText
        self.replacement = replacement
    }
}
