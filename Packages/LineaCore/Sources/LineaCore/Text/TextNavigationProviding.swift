import Foundation

/// 词边界模式。
///
/// - `identifier`：仅 ASCII 字母、数字、下划线，与 1.0.2 的 ⌘D/⌃⌘G 取词一致。
/// - `word`：Foundation/ICU 的 Unicode 词边界，用于双击选词与 Option+方向键。
public enum WordBoundaryMode: Sendable {
    case identifier
    case word
}

/// 文本导航：字符（grapheme cluster）、词、行的边界计算。
///
/// 所有 offset 都是 UTF-16；越界输入会 clamp 到 `0...textLength`。
/// 光标穿越 CRLF 时按单个 grapheme 处理，永远不会停在 CR 与 LF 之间。
public protocol TextNavigationProviding: AnyObject {
    var textLength: Int { get }
    var lineIndex: LineIndex { get }

    func previousCharacterBoundary(before offset: Int) -> Int
    func nextCharacterBoundary(after offset: Int) -> Int

    func previousWordBoundary(before offset: Int, mode: WordBoundaryMode) -> Int
    func nextWordBoundary(after offset: Int, mode: WordBoundaryMode) -> Int
    func wordRange(at offset: Int, mode: WordBoundaryMode) -> NSRange?
}

/// 纯 Foundation 实现。
///
/// 字符边界只读取 offset 附近的一个窗口，窗口边界命中时指数扩张，
/// 避免为每次光标移动构造全文。Unicode 词枚举同样在窗口内进行；
/// 词本身跨出窗口时再扩张。
public final class DefaultTextNavigationProvider: TextNavigationProviding {
    private static let characterWindow = 256
    private static let wordWindow = 4_096

    private let buffer: TextBuffer
    public let lineIndex: LineIndex

    public init(buffer: TextBuffer) {
        self.buffer = buffer
        self.lineIndex = LineIndex(buffer: buffer)
    }

    public var textLength: Int {
        buffer.length
    }

    // MARK: - 字符边界

    public func nextCharacterBoundary(after offset: Int) -> Int {
        let length = buffer.length
        let clamped = clamp(offset)
        guard clamped < length else { return length }

        var windowSize = Self.characterWindow
        while true {
            let start = max(0, clamped - windowSize)
            let end = min(length, clamped + windowSize)
            let windowLength = end - start
            let ns = buffer.substring(
                in: NSRange(location: start, length: windowLength)
            ) as NSString
            let local = clamped - start
            let cluster = ns.rangeOfComposedCharacterSequence(at: local)
            let clusterEnd = cluster.location + cluster.length

            // 组合字符在窗口右边界被截断时，扩大窗口重算。
            if clusterEnd < windowLength || end == length {
                var boundary = start + clusterEnd
                // NSString 不把 CRLF 视为一个组合字符；光标移动要整体跨过，
                // 否则会停在 CR 与 LF 之间，破坏行模型。
                if boundary < length,
                   buffer.character(at: boundary - 1) == 0x0D,
                   buffer.character(at: boundary) == 0x0A
                {
                    boundary += 1
                }
                return boundary
            }
            windowSize *= 2
        }
    }

    public func previousCharacterBoundary(before offset: Int) -> Int {
        let clamped = clamp(offset)
        guard clamped > 0 else { return 0 }

        var windowSize = Self.characterWindow
        while true {
            let start = max(0, clamped - windowSize)
            let end = min(buffer.length, clamped + windowSize)
            let windowLength = end - start
            let ns = buffer.substring(
                in: NSRange(location: start, length: windowLength)
            ) as NSString
            let local = clamped - start
            let cluster = ns.rangeOfComposedCharacterSequence(at: local - 1)

            // 组合字符在窗口左边界被截断时，扩大窗口重算。
            if cluster.location > 0 || start == 0 {
                var boundary = start + cluster.location
                // 停在 LF 前时向左整体跨过 CRLF。
                if boundary > 0,
                   buffer.character(at: boundary) == 0x0A,
                   buffer.character(at: boundary - 1) == 0x0D
                {
                    boundary -= 1
                }
                return boundary
            }
            windowSize *= 2
        }
    }

    // MARK: - 词边界

    public func previousWordBoundary(before offset: Int, mode: WordBoundaryMode) -> Int {
        let clamped = clamp(offset)
        guard clamped > 0 else { return 0 }

        switch mode {
        case .identifier:
            return previousIdentifierBoundary(before: clamped)
        case .word:
            return previousUnicodeWordBoundary(before: clamped)
        }
    }

    public func nextWordBoundary(after offset: Int, mode: WordBoundaryMode) -> Int {
        let length = buffer.length
        let clamped = clamp(offset)
        guard clamped < length else { return length }

        switch mode {
        case .identifier:
            return nextIdentifierBoundary(after: clamped)
        case .word:
            return nextUnicodeWordBoundary(after: clamped)
        }
    }

    public func wordRange(at offset: Int, mode: WordBoundaryMode) -> NSRange? {
        let clamped = clamp(offset)
        switch mode {
        case .identifier:
            return identifierRange(at: clamped)
        case .word:
            return unicodeWordRange(at: clamped)
        }
    }

    // MARK: - ASCII 标识符

    private func previousIdentifierBoundary(before offset: Int) -> Int {
        var index = offset
        // 跳过左侧分隔符，再回到上一个词的词首。
        while index > 0, !Self.isIdentifier(buffer.character(at: index - 1)) {
            index -= 1
        }
        while index > 0, Self.isIdentifier(buffer.character(at: index - 1)) {
            index -= 1
        }
        return index
    }

    private func nextIdentifierBoundary(after offset: Int) -> Int {
        var index = offset
        let length = buffer.length

        if index < length, Self.isIdentifier(buffer.character(at: index)) {
            // 当前在词内或词首：先到当前词尾。
            while index < length, Self.isIdentifier(buffer.character(at: index)) {
                index += 1
            }
            return index
        }

        // 在分隔符或词尾：跳过分隔符，再到下一个词尾。
        while index < length, !Self.isIdentifier(buffer.character(at: index)) {
            index += 1
        }
        while index < length, Self.isIdentifier(buffer.character(at: index)) {
            index += 1
        }
        return index
    }

    /// 与 1.0.2 MultiCursorController.wordRange 完全一致的取词逻辑。
    private func identifierRange(at offset: Int) -> NSRange? {
        let length = buffer.length
        guard length > 0 else { return nil }

        var start = offset
        var end = offset

        if offset < length, Self.isIdentifier(buffer.character(at: offset)) {
            while start > 0, Self.isIdentifier(buffer.character(at: start - 1)) {
                start -= 1
            }
            while end < length, Self.isIdentifier(buffer.character(at: end)) {
                end += 1
            }
        } else if offset > 0, Self.isIdentifier(buffer.character(at: offset - 1)) {
            // 光标停在词尾：仍然选中前一个词。
            while start > 0, Self.isIdentifier(buffer.character(at: start - 1)) {
                start -= 1
            }
        } else {
            return nil
        }

        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    private static func isIdentifier(_ character: UInt16?) -> Bool {
        guard let character else { return false }
        return (character >= 48 && character <= 57)       // 0-9
            || (character >= 65 && character <= 90)       // A-Z
            || (character >= 97 && character <= 122)      // a-z
            || character == 95                            // _
    }

    // MARK: - Unicode 词

    private func previousUnicodeWordBoundary(before offset: Int) -> Int {
        var windowSize = Self.wordWindow
        while true {
            let start = max(0, offset - windowSize)
            let end = min(buffer.length, offset + windowSize)
            let words = unicodeWords(in: start..<end)

            // 光标在词内或词尾：回到当前词首。
            let current = words.last {
                $0.location < offset && $0.location + $0.length >= offset
            }
            // 否则跳过中间的分隔符，回到上一个词首。
            let candidate = current ?? words.last {
                $0.location + $0.length <= offset
            }

            if let candidate {
                let clippedAtWindowStart = candidate.location == start && start > 0
                if !clippedAtWindowStart {
                    return candidate.location
                }
            } else if start == 0 {
                return 0
            }

            if start == 0 && end == buffer.length {
                return 0
            }
            windowSize *= 2
        }
    }

    private func nextUnicodeWordBoundary(after offset: Int) -> Int {
        var windowSize = Self.wordWindow
        while true {
            let start = max(0, offset - windowSize)
            let end = min(buffer.length, offset + windowSize)
            let words = unicodeWords(in: start..<end)

            // 光标在词内：到当前词尾；在分隔符/词尾：到下一个词尾。
            let current = words.first {
                $0.location < offset && $0.location + $0.length > offset
            }
            let candidate = current ?? words.first {
                $0.location + $0.length > offset
            }

            if let candidate {
                let candidateEnd = candidate.location + candidate.length
                let clippedAtWindowEnd = candidateEnd == end && end < buffer.length
                if !clippedAtWindowEnd {
                    return candidateEnd
                }
            } else if end == buffer.length {
                return buffer.length
            }

            if start == 0 && end == buffer.length {
                return buffer.length
            }
            windowSize *= 2
        }
    }

    private func unicodeWordRange(at offset: Int) -> NSRange? {
        var windowSize = Self.wordWindow
        while true {
            let start = max(0, offset - windowSize)
            let end = min(buffer.length, offset + windowSize)
            let words = unicodeWords(in: start..<end)

            let containing = words.first {
                $0.location <= offset && offset < $0.location + $0.length
            }
            // 双击词尾/空白时选中前面刚结束的词。
            let endingHere = words.last {
                $0.location < offset && $0.location + $0.length == offset
            }
            let candidate = containing ?? endingHere

            if let candidate {
                let clippedAtStart = candidate.location == start && start > 0
                let candidateEnd = candidate.location + candidate.length
                let clippedAtEnd = candidateEnd == end && end < buffer.length
                if !clippedAtStart && !clippedAtEnd {
                    return candidate
                }
            } else if start == 0 && end == buffer.length {
                return nil
            }

            windowSize *= 2
        }
    }

    /// 在窗口内枚举 Unicode 词，返回全局坐标。
    private func unicodeWords(in range: Range<Int>) -> [NSRange] {
        guard range.lowerBound < range.upperBound else { return [] }
        let ns = buffer.substring(
            in: NSRange(location: range.lowerBound, length: range.count)
        ) as NSString
        var result: [NSRange] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byWords, .substringNotRequired]
        ) { _, substringRange, _, _ in
            result.append(
                NSRange(
                    location: range.lowerBound + substringRange.location,
                    length: substringRange.length
                )
            )
        }
        return result
    }

    // MARK: - 工具

    private func clamp(_ offset: Int) -> Int {
        min(max(0, offset), buffer.length)
    }
}
