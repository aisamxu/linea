import Foundation

enum MultiCursorResult: Equatable {
    case updated([NSRange])
    case noChange
    case tooMany(limit: Int)
}

/// Sublime 风格多光标命令的纯逻辑实现。
///
/// 这里不依赖 AppKit，便于单元测试；真正的选区写回由 EditorViewController 完成。
enum MultiCursorController {
    static let maximumSelections = 10_000

    // MARK: - ⌘D

    static func selectNextOccurrence(in text: String, selections: [NSRange]) -> MultiCursorResult {
        let string = text as NSString
        let currentRanges = sanitizedSelections(selections, textLength: string.length)
        guard let searchTarget = searchTarget(in: string, selections: currentRanges) else {
            return .noChange
        }

        // Sublime 风格：只有光标时，第一次 ⌘D 先选中当前单词，
        // 之后再次按下才逐个追加匹配项。
        if !currentRanges.contains(where: { $0.length > 0 }) {
            return .updated(searchTarget.selections)
        }

        let searchStart = searchTarget.selections.map { $0.location + $0.length }.max() ?? 0
        guard searchStart < string.length else { return .noChange }

        let searchRange = NSRange(location: searchStart, length: string.length - searchStart)
        let match = string.range(of: searchTarget.text, options: [.literal], range: searchRange)
        guard match.location != NSNotFound else { return .noChange }

        return .updated(searchTarget.selections + [match])
    }

    // MARK: - ⌃⌘G

    static func selectAllOccurrences(in text: String, selections: [NSRange]) -> MultiCursorResult {
        let string = text as NSString
        let currentRanges = sanitizedSelections(selections, textLength: string.length)
        guard let searchTarget = searchTarget(in: string, selections: currentRanges) else {
            return .noChange
        }

        let matches = allMatches(
            of: searchTarget.text,
            in: string,
            limit: maximumSelections
        )

        if matches.count > maximumSelections {
            return .tooMany(limit: maximumSelections)
        }

        guard !matches.isEmpty else { return .noChange }
        return .updated(matches)
    }

    // MARK: - ⇧⌘L

    static func addCursorsToSelectedLines(in text: String, selections: [NSRange]) -> MultiCursorResult {
        let string = text as NSString
        let currentRanges = sanitizedSelections(selections, textLength: string.length)
        var caretLocations = Set<Int>()

        for range in currentRanges {
            let startLine = lineStart(containing: range.location, in: string)
            let endProbe: Int
            if range.length > 0 {
                endProbe = range.location + range.length - 1
            } else {
                endProbe = range.location
            }

            var lineStartOffset = startLine
            while true {
                caretLocations.insert(contentEnd(forLineStartingAt: lineStartOffset, in: string))
                if caretLocations.count > maximumSelections {
                    return .tooMany(limit: maximumSelections)
                }

                guard let nextLine = nextLineStart(after: lineStartOffset, in: string),
                      nextLine <= endProbe
                else {
                    break
                }
                lineStartOffset = nextLine
            }
        }

        // 固定为升序，最后一项继续作为主光标
        let ranges = caretLocations
            .sorted()
            .map { NSRange(location: $0, length: 0) }

        return ranges.isEmpty ? .noChange : .updated(ranges)
    }

    // MARK: - 取词与匹配

    /// 选择光标所在的 ASCII 标识符字符（字母、数字、下划线）。
    static func wordRange(at location: Int, in string: NSString) -> NSRange? {
        let length = string.length
        guard length > 0 else { return nil }

        let caret = min(max(0, location), length)
        var start = caret
        var end = caret

        if caret < length, isWordCharacter(string.character(at: caret)) {
            while start > 0, isWordCharacter(string.character(at: start - 1)) {
                start -= 1
            }
            while end < length, isWordCharacter(string.character(at: end)) {
                end += 1
            }
        } else if caret > 0, isWordCharacter(string.character(at: caret - 1)) {
            start = caret
            end = caret
            while start > 0, isWordCharacter(string.character(at: start - 1)) {
                start -= 1
            }
        } else {
            return nil
        }

        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    private static func searchTarget(
        in string: NSString,
        selections: [NSRange]
    ) -> (text: String, selections: [NSRange])? {
        // 优先使用最后一个非空选区的内容
        if let lastNonEmpty = selections.last(where: { $0.length > 0 }) {
            let selectedText = string.substring(with: lastNonEmpty)
            guard !selectedText.isEmpty else { return nil }
            return (selectedText, selections)
        }

        // 全是光标时，取主光标所在的单词；其他光标会被这个单词选区替换
        guard let caret = selections.last,
              let word = wordRange(at: caret.location, in: string)
        else {
            return nil
        }

        let wordText = string.substring(with: word)
        guard !wordText.isEmpty else { return nil }
        return (wordText, [word])
    }

    private static func allMatches(
        of needle: String,
        in string: NSString,
        limit: Int
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
            if matches.count > limit {
                break
            }

            // 不重叠：从本次匹配末尾继续
            searchLocation = match.location + match.length
        }

        return matches
    }

    // MARK: - 行工具

    private static func lineStart(containing location: Int, in string: NSString) -> Int {
        let clampedLocation = min(max(0, location), string.length)
        guard clampedLocation > 0 else { return 0 }

        let prefix = NSRange(location: 0, length: clampedLocation)
        let newline = string.range(of: "\n", options: [.backwards], range: prefix)
        return newline.location == NSNotFound ? 0 : newline.location + 1
    }

    private static func nextLineStart(after lineStart: Int, in string: NSString) -> Int? {
        guard lineStart < string.length else { return nil }
        let remaining = NSRange(location: lineStart, length: string.length - lineStart)
        let newline = string.range(of: "\n", options: [], range: remaining)
        guard newline.location != NSNotFound else { return nil }
        return newline.location + 1
    }

    private static func contentEnd(forLineStartingAt lineStart: Int, in string: NSString) -> Int {
        guard lineStart < string.length else { return string.length }
        let remaining = NSRange(location: lineStart, length: string.length - lineStart)
        let newline = string.range(of: "\n", options: [], range: remaining)
        guard newline.location != NSNotFound else { return string.length }

        // CRLF 时把光标放在 \r 之前，避免拆开换行符
        if newline.location > lineStart,
           string.character(at: newline.location - 1) == 13 {
            return newline.location - 1
        }
        return newline.location
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        (character >= 48 && character <= 57)       // 0-9
            || (character >= 65 && character <= 90)  // A-Z
            || (character >= 97 && character <= 122) // a-z
            || character == 95                       // _
    }

    private static func sanitizedSelections(
        _ selections: [NSRange],
        textLength: Int
    ) -> [NSRange] {
        let source = selections.isEmpty ? [NSRange(location: 0, length: 0)] : selections
        return source.map {
            guard $0.location != NSNotFound else { return NSRange(location: 0, length: 0) }
            let location = min(max(0, $0.location), textLength)
            let length = min(max(0, $0.length), textLength - location)
            return NSRange(location: location, length: length)
        }
    }
}
