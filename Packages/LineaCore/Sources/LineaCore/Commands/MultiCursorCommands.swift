import Foundation

/// 多光标命令结果。
///
/// 命令本身不修改选区，只返回目标选区集合，由调用方写回引擎；
/// 这样命令可以脱离 UI 单独测试，也避免在选择过程中产生编辑事务。
public enum MultiCursorCommandResult: Equatable, Sendable {
    case updated([TextSelection])
    case noChange
}

/// Sublime 风格多光标命令的纯逻辑实现。
///
/// - ⌘D：选中下一个相同词；只有光标时第一次按下先选中当前标识符。
/// - ⌃⌘G：选中全部相同词。
/// - ⇧⌘L：为选区覆盖的每一行在行尾内容处加光标。
///
/// 匹配使用大小写敏感的字面量搜索，结果不重叠、不循环；
/// 行边界统一走 `LineIndex`，因此 LF/CR/CRLF/U+2028/U+2029 都正确。
public enum MultiCursorCommands {
    // MARK: - ⌘D

    /// 选择下一个相同词。
    ///
    /// 首次按下且有光标无选区时，先选中主光标所在的 ASCII 标识符；
    /// 之后从最后一个选区的末尾继续字面量搜索，不循环回文档开头。
    public static func selectNextOccurrence(
        in text: String,
        selections: [TextSelection]
    ) -> MultiCursorCommandResult {
        let string = text as NSString
        let currentSelections = sanitizedSelections(selections, textLength: string.length)
        guard let searchTarget = searchTarget(in: string, selections: currentSelections) else {
            return .noChange
        }

        // 只有光标时，第一次 ⌘D 先选中当前单词，结果会丢弃其他光标。
        if !currentSelections.contains(where: { !$0.isCaret }) {
            return .updated(searchTarget.selections)
        }

        let searchStart = searchTarget.selections
            .map(\.insertionOffset)
            .max() ?? 0
        guard searchStart < string.length else { return .noChange }

        let searchRange = NSRange(
            location: searchStart,
            length: string.length - searchStart
        )
        let match = string.range(
            of: searchTarget.text,
            options: [.literal],
            range: searchRange
        )
        guard match.location != NSNotFound else { return .noChange }

        return .updated(searchTarget.selections + [TextSelection(range: match)])
    }

    // MARK: - ⌃⌘G

    /// 选中文档内全部相同词，不限制匹配数量。
    public static func selectAllOccurrences(
        in text: String,
        selections: [TextSelection]
    ) -> MultiCursorCommandResult {
        let string = text as NSString
        let currentSelections = sanitizedSelections(selections, textLength: string.length)
        guard let searchTarget = searchTarget(in: string, selections: currentSelections) else {
            return .noChange
        }

        let matches = allMatches(of: searchTarget.text, in: string)
        guard !matches.isEmpty else { return .noChange }

        return .updated(matches.map { TextSelection(range: $0) })
    }

    // MARK: - ⇧⌘L

    /// 为每个选区覆盖的每一行在行尾内容处添加光标。
    ///
    /// 行尾停在行终止符之前；CRLF 不会把光标拆到 `\r` 与 `\n` 之间。
    /// 结果按偏移升序排列并去重，最后一项仍然是主选区。
    public static func addCursorsToSelectedLines(
        in text: String,
        selections: [TextSelection],
        lineIndex: LineIndex
    ) -> MultiCursorCommandResult {
        // LineIndex 必须与 text 同源；长度不一致说明调用方传错了索引。
        guard lineIndex.length == (text as NSString).length else {
            assertionFailure("addCursorsToSelectedLines 的 text 与 lineIndex 不同源")
            return .noChange
        }

        let currentSelections = sanitizedSelections(
            selections,
            textLength: lineIndex.length
        )
        var caretLocations = Set<Int>()

        for selection in currentSelections {
            let range = selection.range
            let startLine = lineIndex.lineStart(at: range.location)
            let endProbe: Int
            if range.length > 0 {
                endProbe = range.location + range.length - 1
            } else {
                endProbe = range.location
            }

            var lineStartOffset = startLine
            while true {
                caretLocations.insert(lineIndex.contentEnd(at: lineStartOffset))

                guard let nextLine = lineIndex.nextLineStart(after: lineStartOffset),
                      nextLine <= endProbe
                else {
                    break
                }
                lineStartOffset = nextLine
            }
        }

        let carets = caretLocations
            .sorted()
            .map { TextSelection.caret(at: $0) }

        return carets.isEmpty ? .noChange : .updated(carets)
    }

    // MARK: - 取词与匹配

    /// 选择光标所在的 ASCII 标识符（字母、数字、下划线）。
    ///
    /// 与 1.0.2 的 ⌘D/⌃⌘G 一致：光标在词内选中整词，光标在词尾仍选中前一个词，
    /// 词外返回 nil。CJK、emoji 等非 ASCII 字符不作为标识符。
    public static func identifierRange(at offset: Int, in text: String) -> NSRange? {
        identifierRange(at: offset, in: text as NSString)
    }

    private static func identifierRange(at offset: Int, in string: NSString) -> NSRange? {
        let length = string.length
        guard length > 0 else { return nil }

        let caret = min(max(0, offset), length)
        var start = caret
        var end = caret

        if caret < length, isIdentifier(string.character(at: caret)) {
            while start > 0, isIdentifier(string.character(at: start - 1)) {
                start -= 1
            }
            while end < length, isIdentifier(string.character(at: end)) {
                end += 1
            }
        } else if caret > 0, isIdentifier(string.character(at: caret - 1)) {
            // 光标停在词尾：向前取整个词。
            while start > 0, isIdentifier(string.character(at: start - 1)) {
                start -= 1
            }
        } else {
            return nil
        }

        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// 解析本次命令的搜索目标。
    ///
    /// 优先使用最后一个非空选区（主选区）的内容；全是光标时取主光标所在单词，
    /// 并用这个单词选区替换其他光标。
    private static func searchTarget(
        in string: NSString,
        selections: [TextSelection]
    ) -> (text: String, selections: [TextSelection])? {
        if let lastNonEmpty = selections.last(where: { !$0.isCaret }) {
            let selectedText = string.substring(with: lastNonEmpty.range)
            guard !selectedText.isEmpty else { return nil }
            return (selectedText, selections)
        }

        guard let caret = selections.last,
              let word = identifierRange(at: caret.range.location, in: string)
        else {
            return nil
        }

        let wordText = string.substring(with: word)
        guard !wordText.isEmpty else { return nil }
        return (wordText, [TextSelection(range: word)])
    }

    /// 查找全部不重叠的匹配项。
    private static func allMatches(
        of needle: String,
        in string: NSString
    ) -> [NSRange] {
        var matches: [NSRange] = []
        var searchLocation = 0

        while searchLocation < string.length {
            let remaining = NSRange(
                location: searchLocation,
                length: string.length - searchLocation
            )
            let match = string.range(of: needle, options: [.literal], range: remaining)
            guard match.location != NSNotFound else { break }

            matches.append(match)

            // 不重叠：从本次匹配末尾继续。
            searchLocation = match.location + match.length
        }

        return matches
    }

    // MARK: - 工具

    private static func isIdentifier(_ character: unichar) -> Bool {
        (character >= 48 && character <= 57)       // 0-9
            || (character >= 65 && character <= 90)  // A-Z
            || (character >= 97 && character <= 122) // a-z
            || character == 95                       // _
    }

    /// 把外部传入的选区夹到文档范围内；空数组按文档开头的光标处理。
    private static func sanitizedSelections(
        _ selections: [TextSelection],
        textLength: Int
    ) -> [TextSelection] {
        let source = selections.isEmpty ? [TextSelection.caret(at: 0)] : selections
        return source.map { selection in
            guard selection.range.location != NSNotFound else {
                return TextSelection.caret(at: 0, affinity: selection.affinity)
            }
            let location = min(max(0, selection.range.location), textLength)
            let length = min(
                max(0, selection.range.length),
                textLength - location
            )
            return TextSelection(
                range: NSRange(location: location, length: length),
                affinity: selection.affinity
            )
        }
    }
}
