import Foundation
import Testing
@testable import LineaCore

@Suite("LineIndex")
struct LineIndexTests {
    @Test func matchesReferenceCorpus() {
        let corpus = [
            "",
            "abc",
            "a\nb",
            "a\rb",
            "a\r\nb",
            "\r\n",
            "a\r\n\r\nb\n",
            "a\r\r\nb\r\n\nc",
            "a\u{2028}b\u{2029}c",
            "中文😀\r\nemoji👩‍👩‍👧‍👦\nend",
            "abc\n",
            "\n\n\n",
            "one\ntwo\r\nthree\rfour\u{2028}five",
        ]
        for text in corpus {
            assertIndex(text)
        }
    }

    @Test func matchesReferenceAfterEdits() {
        var rng = SeededGenerator(seed: 0x1EAF)
        let alphabet = ["a", "b", "中", "😀", " ", "\n", "\r", "\r\n", "\u{2028}", "\u{2029}"]
        let replacements = ["", "x", "中", "\n", "\r\n", "\u{2028}"]

        for round in 0..<40 {
            var text = ""
            for _ in 0..<Int(rng.next() % 50) {
                text += alphabet[Int(rng.next() % UInt64(alphabet.count))]
            }
            let buffer = PieceTreeBuffer(text: text)

            for step in 0..<15 {
                var edits: [TextEdit] = []
                var cursor = 0
                for _ in 0..<(1 + Int(rng.next() % 3)) {
                    let available = buffer.length - cursor
                    guard available > 0 else { break }
                    let location = cursor + Int(rng.next() % UInt64(available))
                    let maxLength = min(5, buffer.length - location)
                    let length = Int(rng.next() % UInt64(maxLength + 1))
                    edits.append(
                        TextEdit(
                            range: NSRange(location: location, length: length),
                            replacement: replacements[
                                Int(rng.next() % UInt64(replacements.count))
                            ]
                        )
                    )
                    cursor = location + length + 1
                }
                buffer.apply(edits: edits)
                assertIndex(buffer: buffer, context: "round \(round) step \(step)")
            }
        }
    }

    // MARK: - 工具

    private func assertIndex(_ text: String) {
        assertIndex(buffer: PieceTreeBuffer(text: text), context: "文本 \(text)")
    }

    private func assertIndex(buffer: PieceTreeBuffer, context: String) {
        let index = LineIndex(buffer: buffer)
        let units = Array(buffer.string.utf16)
        let lines = referenceLines(units)
        let breaks = referenceBreaks(units)

        #expect(index.length == units.count, "\(context)")
        #expect(index.lineCount == lines.count, "\(context)")
        #expect(index.lineCount == breaks.count + 1, "\(context)")

        for line in 1...lines.count {
            #expect(index.lineRange(at: line) == lines[line - 1], "\(context) 第 \(line) 行")
            let expectedContentEnd = line <= breaks.count ? breaks[line - 1].start : units.count
            #expect(
                index.lineContentEnd(at: line) == expectedContentEnd,
                "\(context) 第 \(line) 行内容结束"
            )
            #expect(
                index.lineContentRange(at: line)
                    == NSRange(
                        location: lines[line - 1].location,
                        length: expectedContentEnd - lines[line - 1].location
                    ),
                "\(context) 第 \(line) 行内容范围"
            )
        }

        for offset in 0...units.count {
            let prefix = breaks.filter { $0.end <= offset }
            let line = prefix.count + 1
            let start = prefix.last?.end ?? 0

            #expect(index.lineNumber(at: offset) == line, "\(context) offset \(offset) 行号")
            #expect(index.lineStart(at: offset) == start, "\(context) offset \(offset) 行首")
            #expect(
                index.lineRange(containing: offset) == lines[line - 1],
                "\(context) offset \(offset) 所在行"
            )

            let expectedContentEnd =
                breaks.first { $0.start >= start }?.start ?? units.count
            #expect(
                index.contentEnd(at: offset) == expectedContentEnd,
                "\(context) offset \(offset) 内容结束"
            )
            #expect(
                index.nextLineStart(after: offset)
                    == breaks.first { $0.start >= offset }?.end,
                "\(context) offset \(offset) 下一行"
            )

            let expectedPrevious: Int? = {
                guard offset > 0, start > 0 else { return nil }
                return breaks.last { $0.end <= start - 1 }?.end ?? 0
            }()
            #expect(
                index.previousLineStart(before: offset) == expectedPrevious,
                "\(context) offset \(offset) 上一行"
            )
        }
    }
}
