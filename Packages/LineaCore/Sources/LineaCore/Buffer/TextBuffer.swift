import Foundation

/// 文本缓冲协议。首版实现是 `PieceTreeBuffer`，未来可替换为 rope。
///
/// 坐标全部为 UTF-16 偏移：
/// - 行号从 1 开始。
/// - 行终止符集合为 LF、CR、CRLF（算一个）、U+2028、U+2029。
/// - 所有读取方法都要求 offset 在 `0...length` 内；调试构建会断言越界。
public protocol TextBuffer: AnyObject {
    /// 当前文本的 UTF-16 总长度。
    var length: Int { get }

    /// 行数；空文档为 1 行，尾随换行会产生一个额外的空行。
    var lineCount: Int { get }

    /// 每次成功批量编辑后递增。
    var version: UInt64 { get }

    /// 当前 piece 数，用于测试和性能护栏。
    var pieceCount: Int { get }

    /// 全文快照。热路径禁止调用；保存、查找、AX 等按需使用。
    var string: String { get }

    /// 读取区间文本；range 必须落在 `0...length` 内。
    func substring(in range: NSRange) -> String

    /// 读取单个 UTF-16 code unit。
    func character(at offset: Int) -> UInt16?

    /// 批量应用编辑（base 坐标，升序、互不重叠）。
    ///
    /// 返回按 location 升序排列的 `AppliedEdit`；输入非法时返回空数组且不修改缓冲区。
    @discardableResult
    func apply(edits: [TextEdit]) -> [AppliedEdit]

    /// offset 所在行的行号（1 起）。
    func lineNumber(at offset: Int) -> Int

    /// offset 所在行的行首偏移。
    func lineStart(at offset: Int) -> Int

    /// 第 `line` 行的完整范围（含行终止符）；line 从 1 开始。
    func lineRange(at line: Int) -> NSRange

    /// offset 所在行的内容结束位置（停在行终止符之前）。
    func contentEnd(at offset: Int) -> Int

    /// 下一个行首偏移；已经是最后一行时返回 nil。
    func nextLineStart(after offset: Int) -> Int?
}
