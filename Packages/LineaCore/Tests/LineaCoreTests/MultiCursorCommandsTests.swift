import Foundation
import Testing
@testable import LineaCore

@Suite("MultiCursorCommands")
struct MultiCursorCommandsTests {
    // MARK: - 标识符取词

    @Test func identifierRangeInsideWord() {
        #expect(
            MultiCursorCommands.identifierRange(at: 3, in: "hello_world foo")
                == NSRange(location: 0, length: 11)
        )
    }

    @Test func identifierRangeWhenCaretSitsAfterWord() {
        #expect(
            MultiCursorCommands.identifierRange(at: 5, in: "hello world")
                == NSRange(location: 0, length: 5)
        )
    }

    @Test func identifierRangeRejectsNonIdentifierCharacters() {
        #expect(MultiCursorCommands.identifierRange(at: 2, in: "  --  ") == nil)
        #expect(MultiCursorCommands.identifierRange(at: 0, in: "") == nil)
        // CJK 不属于 ASCII 标识符，与 1.0.2 保持一致。
        #expect(MultiCursorCommands.identifierRange(at: 0, in: "中文") == nil)
    }

    // MARK: - ⌘D

    @Test func selectNextOccurrenceContinuesAfterLastSelection() {
        let result = MultiCursorCommands.selectNextOccurrence(
            in: "foo bar foo baz foo",
            selections: [selection(0, 3)]
        )

        #expect(
            result == .updated([selection(0, 3), selection(8, 3)])
        )
    }

    @Test func selectNextOccurrenceUsesLastNonEmptySelection() {
        let result = MultiCursorCommands.selectNextOccurrence(
            in: "foo bar foo baz foo",
            selections: [selection(0, 3), selection(8, 3)]
        )

        #expect(
            result == .updated([
                selection(0, 3),
                selection(8, 3),
                selection(16, 3),
            ])
        )
    }

    @Test func selectNextOccurrenceFromCaretSelectsWordOnFirstPress() {
        let first = MultiCursorCommands.selectNextOccurrence(
            in: "foo bar foo",
            selections: [.caret(at: 1)]
        )
        #expect(first == .updated([selection(0, 3)]))

        // 第二次按下才追加下一个匹配项。
        let second = MultiCursorCommands.selectNextOccurrence(
            in: "foo bar foo",
            selections: [selection(0, 3)]
        )
        #expect(second == .updated([selection(0, 3), selection(8, 3)]))
    }

    @Test func selectNextOccurrenceIsCaseSensitive() {
        // "Foo" 与 "foo" 不视为同一匹配项。
        let result = MultiCursorCommands.selectNextOccurrence(
            in: "Foo foo",
            selections: [selection(0, 3)]
        )

        #expect(result == .noChange)
    }

    @Test func selectNextOccurrenceReturnsNoChangeOnLastMatch() {
        let result = MultiCursorCommands.selectNextOccurrence(
            in: "foo bar foo",
            selections: [selection(8, 3)]
        )

        #expect(result == .noChange)
    }

    @Test func selectNextOccurrenceReturnsNoChangeWithoutWord() {
        let result = MultiCursorCommands.selectNextOccurrence(
            in: "   ",
            selections: [.caret(at: 1)]
        )

        #expect(result == .noChange)
    }

    @Test func selectNextOccurrenceClampsOutOfBoundsSelection() {
        let result = MultiCursorCommands.selectNextOccurrence(
            in: "abc abc",
            selections: [selection(-5, 3)]
        )

        #expect(result == .updated([selection(0, 3), selection(4, 3)]))
    }

    @Test func selectNextOccurrenceRejectsWhenAtSelectionLimit() {
        let text = String(repeating: "a", count: MultiCursorCommands.maximumSelections)
        let selections = (0..<MultiCursorCommands.maximumSelections).map {
            selection($0, 1)
        }

        let result = MultiCursorCommands.selectNextOccurrence(
            in: text,
            selections: selections
        )

        #expect(result == .tooMany(limit: MultiCursorCommands.maximumSelections))
    }

    // MARK: - ⌃⌘G

    @Test func selectAllOccurrencesFindsNonOverlappingMatches() {
        let result = MultiCursorCommands.selectAllOccurrences(
            in: "aaaa",
            selections: [selection(0, 2)]
        )

        #expect(result == .updated([selection(0, 2), selection(2, 2)]))
    }

    @Test func selectAllOccurrencesFindsEveryMatch() {
        let result = MultiCursorCommands.selectAllOccurrences(
            in: "foo foo foo",
            selections: [selection(4, 3)]
        )

        #expect(
            result == .updated([
                selection(0, 3),
                selection(4, 3),
                selection(8, 3),
            ])
        )
    }

    @Test func selectAllOccurrencesEnforcesLimit() {
        let text = String(repeating: "a", count: MultiCursorCommands.maximumSelections + 1)
        let result = MultiCursorCommands.selectAllOccurrences(
            in: text,
            selections: [selection(0, 1)]
        )

        #expect(result == .tooMany(limit: MultiCursorCommands.maximumSelections))
    }

    // MARK: - ⇧⌘L

    @Test func addCursorsToSingleLinePutsCaretAtLineEnd() {
        let result = addCursors(in: "one\ntwo", selections: [.caret(at: 0)])

        #expect(result == .updated([.caret(at: 3)]))
    }

    @Test func addCursorsToSelectedLines() {
        let result = addCursors(
            in: "one\ntwo\nthree",
            selections: [selection(0, 13)]
        )

        #expect(
            result == .updated([
                .caret(at: 3),
                .caret(at: 7),
                .caret(at: 13),
            ])
        )
    }

    @Test func addCursorsToCRLFLinesDoesNotSplitNewline() {
        let result = addCursors(in: "a\r\nb\r\n", selections: [selection(0, 6)])

        #expect(result == .updated([.caret(at: 1), .caret(at: 4)]))
    }

    @Test func addCursorsHandlesCRLines() {
        // 统一行模型：单独的 CR 也是行终止符。
        let result = addCursors(in: "a\rb\r", selections: [selection(0, 4)])

        #expect(result == .updated([.caret(at: 1), .caret(at: 3)]))
    }

    @Test func addCursorsHandlesUnicodeLineSeparators() {
        // U+2028 与 U+2029 在 LineIndex 中是正常行边界。
        #expect(
            addCursors(in: "a\u{2028}b", selections: [selection(0, 3)])
                == .updated([.caret(at: 1), .caret(at: 3)])
        )
        #expect(
            addCursors(in: "a\u{2029}b", selections: [selection(0, 3)])
                == .updated([.caret(at: 1), .caret(at: 3)])
        )
    }

    @Test func addCursorsDeduplicatesSelectionsOnSameLine() {
        let result = addCursors(
            in: "alpha\nbeta",
            selections: [.caret(at: 0), .caret(at: 3)]
        )

        #expect(result == .updated([.caret(at: 5)]))
    }

    @Test func addCursorsEnforcesLimit() {
        let lineCount = MultiCursorCommands.maximumSelections + 1
        let text = Array(repeating: "x", count: lineCount).joined(separator: "\n")
        let result = addCursors(
            in: text,
            selections: [selection(0, (text as NSString).length)]
        )

        #expect(result == .tooMany(limit: MultiCursorCommands.maximumSelections))
    }

    // MARK: - 工具

    private func selection(_ location: Int, _ length: Int) -> TextSelection {
        TextSelection(range: NSRange(location: location, length: length))
    }

    private func addCursors(
        in text: String,
        selections: [TextSelection]
    ) -> MultiCursorCommandResult {
        let lineIndex = LineIndex(buffer: PieceTreeBuffer(text: text))
        return MultiCursorCommands.addCursorsToSelectedLines(
            in: text,
            selections: selections,
            lineIndex: lineIndex
        )
    }
}
