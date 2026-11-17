import Foundation

/// `TextBuffer` 的只读行视图。
///
/// gutter、⇧⌘L、垂直移动、查找栏和视图层都通过它取行边界，
/// 保证整个产品只有一套行终止符语义（LF/CR/CRLF/U+2028/U+2029）。
/// 行号从 1 开始；偏移全部是 UTF-16。
public struct LineIndex {
    private let buffer: TextBuffer

    public init(buffer: TextBuffer) {
        self.buffer = buffer
    }

    public var length: Int {
        buffer.length
    }

    public var lineCount: Int {
        buffer.lineCount
    }

    public func lineNumber(at offset: Int) -> Int {
        buffer.lineNumber(at: offset)
    }

    /// offset 所在行的行首；停在 CRLF 中间时仍属于前一行。
    public func lineStart(at offset: Int) -> Int {
        buffer.lineStart(at: offset)
    }

    /// 第 line 行的完整范围（含行终止符）。
    public func lineRange(at line: Int) -> NSRange {
        buffer.lineRange(at: line)
    }

    /// 第 line 行去掉行终止符后的范围。
    public func lineContentRange(at line: Int) -> NSRange {
        let range = buffer.lineRange(at: line)
        let end = contentEnd(at: range.location)
        return NSRange(location: range.location, length: max(0, end - range.location))
    }

    /// 第 line 行内容的结束位置（行终止符起点）。
    public func lineContentEnd(at line: Int) -> Int {
        let range = buffer.lineRange(at: line)
        return contentEnd(at: range.location)
    }

    /// offset 所在行的完整范围。
    public func lineRange(containing offset: Int) -> NSRange {
        buffer.lineRange(at: buffer.lineNumber(at: offset))
    }

    /// offset 所在行的内容结束位置。
    public func contentEnd(at offset: Int) -> Int {
        buffer.contentEnd(at: offset)
    }

    /// 下一行行首；已在最后一行时返回 nil。
    public func nextLineStart(after offset: Int) -> Int? {
        buffer.nextLineStart(after: offset)
    }

    /// offset 所在行的上一行行首；已在第一行时返回 nil。
    public func previousLineStart(before offset: Int) -> Int? {
        guard offset > 0 else { return nil }
        let currentStart = buffer.lineStart(at: offset)
        guard currentStart > 0 else { return nil }
        return buffer.lineStart(at: currentStart - 1)
    }

    /// 把任意行号夹取到 `1...lineCount`。
    public func clampedLine(_ line: Int) -> Int {
        min(max(1, line), lineCount)
    }
}
