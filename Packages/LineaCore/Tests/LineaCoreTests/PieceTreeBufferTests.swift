import Foundation
import Testing
@testable import LineaCore

@Suite("PieceTreeBuffer")
struct PieceTreeBufferTests {
    // MARK: - 基础读写

    @Test func emptyBuffer() {
        let buffer = PieceTreeBuffer()
        #expect(buffer.length == 0)
        #expect(buffer.lineCount == 1)
        #expect(buffer.pieceCount == 0)
        #expect(buffer.string.isEmpty)
        #expect(buffer.lineRange(at: 1) == NSRange(location: 0, length: 0))
        #expect(buffer.lineNumber(at: 0) == 1)
        #expect(buffer.lineStart(at: 0) == 0)
        #expect(buffer.contentEnd(at: 0) == 0)
        #expect(buffer.nextLineStart(after: 0) == nil)
        #expect(buffer.character(at: 0) == nil)
        #expect(buffer.substring(in: NSRange(location: 0, length: 0)).isEmpty)
    }

    @Test func roundTripAndSubstring() {
        let text = "第一行\nsecond line\r\nthird\rfour\u{2028}five\u{2029}😀"
        let buffer = PieceTreeBuffer(text: text)
        #expect(buffer.string == text)
        #expect(buffer.length == text.utf16.count)

        let full = NSRange(location: 0, length: buffer.length)
        #expect(buffer.substring(in: full) == text)
        #expect(buffer.substring(in: NSRange(location: 0, length: 3)) == "第一行")

        // 逐 code unit 读取必须与 UTF-16 视图一致。
        let units = Array(text.utf16)
        for (index, unit) in units.enumerated() {
            #expect(buffer.character(at: index) == unit, "offset \(index)")
        }
    }

    @Test func insertAtBoundaries() {
        let buffer = PieceTreeBuffer(text: "bc")
        buffer.apply(edits: [TextEdit(range: NSRange(location: 0, length: 0), replacement: "a")])
        #expect(buffer.string == "abc")
        buffer.apply(edits: [TextEdit(range: NSRange(location: 3, length: 0), replacement: "d")])
        #expect(buffer.string == "abcd")
        buffer.apply(edits: [TextEdit(range: NSRange(location: 2, length: 0), replacement: "X")])
        #expect(buffer.string == "abXcd")
    }

    @Test func deleteAndReplace() {
        let buffer = PieceTreeBuffer(text: "hello world")
        buffer.apply(edits: [TextEdit(range: NSRange(location: 0, length: 6), replacement: "")])
        #expect(buffer.string == "world")
        buffer.apply(edits: [TextEdit(range: NSRange(location: 0, length: 5), replacement: "地球")])
        #expect(buffer.string == "地球")
        buffer.apply(edits: [TextEdit(range: NSRange(location: 0, length: 2), replacement: "")])
        #expect(buffer.string.isEmpty)
        #expect(buffer.lineCount == 1)
    }

    @Test func batchEditsUseBaseCoordinates() {
        let buffer = PieceTreeBuffer(text: "0123456789")
        let applied = buffer.apply(edits: [
            TextEdit(range: NSRange(location: 0, length: 1), replacement: "A"),
            TextEdit(range: NSRange(location: 4, length: 2), replacement: "BC"),
            TextEdit(range: NSRange(location: 9, length: 0), replacement: "Z")
        ])
        #expect(buffer.string == "A123BC678Z9")
        #expect(applied.count == 3)
        #expect(applied[0].rangeInBase == NSRange(location: 0, length: 1))
        #expect(applied[0].rangeInResult == NSRange(location: 0, length: 1))
        #expect(applied[0].removedText == "0")
        #expect(applied[1].rangeInBase == NSRange(location: 4, length: 2))
        #expect(applied[1].rangeInResult == NSRange(location: 4, length: 2))
        #expect(applied[1].removedText == "45")
        #expect(applied[2].rangeInBase == NSRange(location: 9, length: 0))
        #expect(applied[2].rangeInResult == NSRange(location: 9, length: 1))
        #expect(applied[2].removedText.isEmpty)
    }

    @Test func versionIncrementsPerApply() {
        let buffer = PieceTreeBuffer(text: "abc")
        #expect(buffer.version == 0)
        buffer.apply(edits: [TextEdit(range: NSRange(location: 1, length: 0), replacement: "x")])
        #expect(buffer.version == 1)
        buffer.apply(edits: [])
        #expect(buffer.version == 1)
        buffer.apply(edits: [TextEdit(range: NSRange(location: 1, length: 0), replacement: "")])
        #expect(buffer.version == 1, "空操作不产生版本变化")
        buffer.apply(edits: [TextEdit(range: NSRange(location: 1, length: 1), replacement: "")])
        #expect(buffer.version == 2)
    }

    @Test func invalidEditsLeaveBufferUntouched() {
        let buffer = PieceTreeBuffer(text: "abc")
        let applied = buffer.apply(edits: [
            TextEdit(range: NSRange(location: 2, length: 1), replacement: "X"),
            TextEdit(range: NSRange(location: 1, length: 1), replacement: "Y")
        ])
        #expect(applied.isEmpty)
        #expect(buffer.string == "abc")
        #expect(buffer.version == 0)

        let outOfBounds = buffer.apply(edits: [
            TextEdit(range: NSRange(location: 3, length: 1), replacement: "Z")
        ])
        #expect(outOfBounds.isEmpty)
        #expect(buffer.string == "abc")
        #expect(buffer.version == 0)
    }

    // MARK: - 行模型

    @Test func lineTerminators() {
        assertLineModel("a\nb")
        assertLineModel("a\rb")
        assertLineModel("a\r\nb")
        assertLineModel("\r\n")
        assertLineModel("\r")
        assertLineModel("\n")
        assertLineModel("a\r\n\r\nb\n")
        assertLineModel("a\r\r\nb\r\n\nc")
        assertLineModel("a\u{2028}b\u{2029}c")
        assertLineModel("中文😀\r\nemoji👩‍👩‍👧‍👦\nend")
        assertLineModel("")
        assertLineModel("abc")
        assertLineModel("abc\n")
        assertLineModel("\n\n\n")
    }

    @Test func crlfAcrossChunkBoundary() {
        // 8192 是内部 chunk 大小；让 CR 落在第一个 piece 末尾、LF 落在 add 缓冲区开头。
        let crIndex = 8191
        let buffer = PieceTreeBuffer(text: String(repeating: "a", count: crIndex) + "\r")
        buffer.apply(edits: [
            TextEdit(range: NSRange(location: crIndex + 1, length: 0), replacement: "\nb")
        ])

        #expect(buffer.length == crIndex + 3)
        #expect(buffer.lineCount == 2)
        #expect(buffer.lineRange(at: 1) == NSRange(location: 0, length: crIndex + 2))
        #expect(buffer.lineRange(at: 2) == NSRange(location: crIndex + 2, length: 1))
        #expect(buffer.lineNumber(at: crIndex) == 1, "CR 仍属第 1 行")
        #expect(buffer.lineNumber(at: crIndex + 1) == 1, "停在 CRLF 中间仍属第 1 行")
        #expect(buffer.lineNumber(at: crIndex + 2) == 2)
        #expect(buffer.lineStart(at: crIndex + 1) == 0)
        #expect(buffer.lineStart(at: crIndex + 2) == crIndex + 2)
        #expect(buffer.contentEnd(at: 0) == crIndex)
        #expect(buffer.contentEnd(at: crIndex + 2) == crIndex + 3)
    }

    @Test func lineQueriesAfterEdits() {
        let buffer = PieceTreeBuffer(text: "one\ntwo\r\nthree")
        buffer.apply(edits: [
            TextEdit(range: NSRange(location: 3, length: 1), replacement: "\r\n"),
            TextEdit(range: NSRange(location: 4, length: 3), replacement: "")
        ])
        #expect(buffer.string == "one\r\n\r\nthree")
        assertLineModel(buffer.string, buffer: buffer)
    }

    // MARK: - 随机差分测试

    @Test func randomEditsAgainstReference() {
        var rng = SeededGenerator(seed: 0xC0FFEE)
        let alphabet = ["a", "b", "中", "😀", " ", "\n", "\r", "\r\n", "\u{2028}", "\u{2029}", "\t"]
        let replacements = ["", "x", "中", "😀", "\n", "\r\n", "\u{2029}", "ab\ncd"]

        for round in 0..<80 {
            var text = ""
            for _ in 0..<Int(rng.next() % 40) {
                text += alphabet[Int(rng.next() % UInt64(alphabet.count))]
            }
            var reference = ReferenceBuffer(text)
            let buffer = PieceTreeBuffer(text: text)

            for step in 0..<25 {
                var edits: [TextEdit] = []
                var cursor = 0
                let count = 1 + Int(rng.next() % 4)
                for _ in 0..<count {
                    let available = reference.units.count - cursor
                    guard available > 0 else { break }
                    let location = cursor + Int(rng.next() % UInt64(available))
                    let maxLength = min(6, reference.units.count - location)
                    let length = Int(rng.next() % UInt64(maxLength + 1))
                    let replacement = replacements[Int(rng.next() % UInt64(replacements.count))]
                    edits.append(
                        TextEdit(
                            range: NSRange(location: location, length: length),
                            replacement: replacement
                        )
                    )
                    cursor = location + length + 1
                }

                buffer.apply(edits: edits)
                reference.apply(edits)
                #expect(
                    buffer.string == reference.string,
                    "round \(round) step \(step) edits \(edits)"
                )
                assertLineModel(reference.string, buffer: buffer)
            }
        }
    }

    // MARK: - 工具

    private func assertLineModel(
        _ text: String,
        buffer suppliedBuffer: PieceTreeBuffer? = nil
    ) {
        let buffer = suppliedBuffer ?? PieceTreeBuffer(text: text)
        let reference = ReferenceBuffer(text)
        let units = reference.units
        let breaks = referenceBreaks(units)

        #expect(buffer.length == units.count, "文本 \(text)")
        #expect(buffer.lineCount == breaks.count + 1, "文本 \(text)")

        let lines = referenceLines(units)
        for (index, expected) in lines.enumerated() {
            #expect(
                buffer.lineRange(at: index + 1) == expected,
                "第 \(index + 1) 行范围，文本 \(debugText(units))"
            )
        }

        // 覆盖所有位置：普通字符、终止符内部、文档边界。
        for offset in 0...units.count {
            let prefix = breaks.filter { $0.end <= offset }
            let expectedLine = prefix.count + 1
            let expectedLineStart = prefix.last?.end ?? 0
            #expect(
                buffer.lineNumber(at: offset) == expectedLine,
                "offset \(offset) 行号，文本 \(debugText(units))"
            )
            #expect(
                buffer.lineStart(at: offset) == expectedLineStart,
                "offset \(offset) 行首，文本 \(debugText(units))"
            )

            let contentEnd = breaks.first { $0.start >= expectedLineStart }?.start ?? units.count
            #expect(
                buffer.contentEnd(at: offset) == contentEnd,
                "offset \(offset) 内容结束，文本 \(debugText(units))"
            )

            let nextStart = breaks.first { $0.start >= offset }?.end
            #expect(
                buffer.nextLineStart(after: offset) == nextStart,
                "offset \(offset) 下一行首，文本 \(debugText(units))"
            )
        }
    }

    private func debugText(_ units: [UInt16]) -> String {
        String(decoding: units, as: UTF16.self)
    }
}

// MARK: - 参考模型

/// 用最直白的数组实现同一套行模型，作为 piece tree 的差分基准。
private struct ReferenceBuffer {
    var units: [UInt16]

    init(_ text: String) {
        units = Array(text.utf16)
    }

    var string: String {
        String(decoding: units, as: UTF16.self)
    }

    mutating func apply(_ edits: [TextEdit]) {
        let sorted = edits
            .filter { !$0.isEmpty }
            .sorted { $0.range.location < $1.range.location }
        for edit in sorted.reversed() {
            let start = edit.range.location
            let end = start + edit.range.length
            units.replaceSubrange(start..<end, with: Array(edit.replacement.utf16))
        }
    }
}

private func referenceBreaks(_ units: [UInt16]) -> [(start: Int, end: Int)] {
    var result: [(start: Int, end: Int)] = []
    var index = 0
    while index < units.count {
        let unit = units[index]
        if unit == 0x0D {
            var end = index + 1
            if end < units.count, units[end] == 0x0A {
                end += 1
            }
            result.append((index, end))
            index = end
            continue
        }
        if unit == 0x0A || unit == 0x2028 || unit == 0x2029 {
            result.append((index, index + 1))
        }
        index += 1
    }
    return result
}

private func referenceLines(_ units: [UInt16]) -> [NSRange] {
    let breaks = referenceBreaks(units)
    var lines: [NSRange] = []
    var start = 0
    for item in breaks {
        lines.append(NSRange(location: start, length: item.end - start))
        start = item.end
    }
    lines.append(NSRange(location: start, length: units.count - start))
    return lines
}

/// 固定种子的线性同余生成器，保证失败可复现。
private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
