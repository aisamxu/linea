import Foundation
import Testing
@testable import LineaCore

/// LineaCore 性能与结构护栏。
///
/// 真实性能结论以 Release 本机数据为准（`swift test -c release`）；
/// Debug 只做宽松 smoke，防止出现全文拷贝、逐字符节点等数量级退化。
@Suite("LineaCorePerformance")
struct LineaCorePerformanceTests {
    /// Release 预算来自计划；Debug 放宽约一个数量级，避免 CI 波动误报。
    private var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    @Test func bufferAppliesFiveHundredEditsWithinBudget() {
        let text = makeDocument(repeating: "abcdefghijklmnopqrstuvwxyz0123456789\n", size: 2 * 1024 * 1024)
        let length = text.utf16.count
        let step = length / (500 + 1)
        let edits = (1...500).map { index in
            TextEdit(
                range: NSRange(location: index * step, length: 0),
                replacement: "X"
            )
        }

        var resultLength = 0
        let elapsed = bestOf(
            3,
            setup: { PieceTreeBuffer(text: text) },
            { buffer in
                buffer.apply(edits: edits)
                resultLength = buffer.length
            }
        )
        print("[LineaCorePerf] 2MB + 500 edits: \(milliseconds(elapsed)) ms")
        #expect(resultLength == length + 500)

        let budget = isDebugBuild ? 250.0 : 5.0
        #expect(
            milliseconds(elapsed) < budget,
            "2MB + 500 edits took \(milliseconds(elapsed))ms"
        )
    }

    @Test func singleEditInLargeDocumentWithinBudget() {
        let text = makeDocument(repeating: "0123456789abcdef\n", size: 10 * 1024 * 1024)
        let length = text.utf16.count
        let elapsed = bestOf(
            3,
            setup: { () -> (PieceTreeBuffer, TextEdit) in
                let buffer = PieceTreeBuffer(text: text)
                let edit = TextEdit(
                    range: NSRange(location: buffer.length / 2, length: 0),
                    replacement: "X"
                )
                return (buffer, edit)
            },
            { pair in
                let (buffer, edit) = pair
                buffer.apply(edits: [edit])
                #expect(buffer.length == length + 1)
            }
        )
        print("[LineaCorePerf] 10MB single edit: \(milliseconds(elapsed)) ms")

        let budget = isDebugBuild ? 50.0 : 2.0
        #expect(
            milliseconds(elapsed) < budget,
            "10MB single edit took \(milliseconds(elapsed))ms"
        )
    }

    @Test func lineNumberQueriesWithinBudget() {
        let lineCount = 100_000
        let text = (0..<lineCount).map { "line \($0)\n" }.joined()
        let lineIndex = LineIndex(buffer: PieceTreeBuffer(text: text))

        var offsets: [Int] = []
        offsets.reserveCapacity(10_000)
        for index in stride(from: 0, to: lineCount, by: 10) {
            offsets.append(lineIndex.lineRange(at: index + 1).location)
        }

        var checksum = 0
        let elapsed = bestOf(3) {
            checksum = 0
            for offset in offsets {
                checksum &+= lineIndex.lineNumber(at: offset)
            }
        }
        let perQueryMicroseconds = milliseconds(elapsed) * 1_000 / Double(offsets.count)
        print(
            "[LineaCorePerf] lineNumber: \(perQueryMicroseconds) µs/query "
                + "(\(offsets.count) queries, checksum \(checksum))"
        )
        #expect(checksum > 0)

        let budget = isDebugBuild ? 20.0 : 1.0
        #expect(
            perQueryMicroseconds < budget,
            "lineNumber took \(perQueryMicroseconds)µs/query"
        )
    }

    @Test func pieceCountStaysBoundedDuringRepeatedEdits() {
        let buffer = PieceTreeBuffer(
            text: makeDocument(repeating: "abcdefghijklmnopqrstuvwxyz\n", size: 100_000)
        )
        var location = 10

        for index in 0..<1_500 {
            let edit = TextEdit(
                range: NSRange(location: location, length: 0),
                replacement: String(index % 10)
            )
            #expect(!buffer.apply(edits: [edit]).isEmpty)
            location = min(location + 7, buffer.length)

            // 与 PieceTreeBuffer 内部的压缩阈值保持一致：
            // 每次 apply 结束后都不允许碎片无限增长。
            let limit = max(2_048, buffer.length / 1_024)
            #expect(
                buffer.pieceCount <= limit,
                "pieceCount \(buffer.pieceCount) exceeded \(limit)"
            )
        }
    }

    @Test func engineHandlesFiveHundredCursorsWithoutBuildingFullText() {
        let lineCount = 100_000
        let lines = (0..<lineCount).map { "line \($0): content\n" }
        let text = lines.joined()
        var selections: [TextSelection] = []
        selections.reserveCapacity(500)
        var location = 0
        for (index, line) in lines.enumerated() {
            if index % (lineCount / 500) == 0 {
                selections.append(.caret(at: location))
            }
            location += line.utf16.count
        }

        let engine = EditorEngine(text: text, selections: selections)
        #expect(engine.fullTextBuildCount == 0)

        let elapsed = bestOf(3) {
            engine.insertText("X")
            engine.undo()
        }
        print("[LineaCorePerf] 100k lines + 500 cursors insert+undo: \(milliseconds(elapsed)) ms")

        // 纯编辑热路径不得构建全文；历史仍然是一步。
        #expect(engine.fullTextBuildCount == 0)
        #expect(engine.selections.count == 500)
        #expect(engine.history.undoCount == 0)
        #expect(engine.length == text.utf16.count)

        let budget = isDebugBuild ? 500.0 : 100.0
        #expect(
            milliseconds(elapsed) < budget,
            "500-cursor insert+undo took \(milliseconds(elapsed))ms"
        )
    }

    // MARK: - 工具

    /// 构造至少 `size` 个 UTF-16 code unit 的重复文本。
    private func makeDocument(repeating unit: String, size: Int) -> String {
        let unitLength = unit.utf16.count
        let count = max(1, size / unitLength)
        return String(repeating: unit, count: count)
    }

    private func bestOf(_ count: Int, _ body: () -> Void) -> Duration {
        var best = Duration.seconds(1_000_000)
        for _ in 0..<count {
            let elapsed = ContinuousClock().measure(body)
            if elapsed < best {
                best = elapsed
            }
        }
        return best
    }

    private func bestOf<T>(
        _ count: Int,
        setup: () -> T,
        _ body: (T) -> Void
    ) -> Duration {
        var best = Duration.seconds(1_000_000)
        for _ in 0..<count {
            let input = setup()
            let elapsed = ContinuousClock().measure {
                body(input)
            }
            if elapsed < best {
                best = elapsed
            }
        }
        return best
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
