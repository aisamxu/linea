import Foundation
@testable import LineaCore

/// 用最直白的数组实现行模型，作为 piece tree / LineIndex 的差分基准。
struct ReferenceBuffer {
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

struct ReferenceBreak {
    let start: Int
    let end: Int
}

func referenceBreaks(_ units: [UInt16]) -> [ReferenceBreak] {
    var result: [ReferenceBreak] = []
    var index = 0
    while index < units.count {
        let unit = units[index]
        if unit == 0x0D {
            var end = index + 1
            if end < units.count, units[end] == 0x0A {
                end += 1
            }
            result.append(ReferenceBreak(start: index, end: end))
            index = end
            continue
        }
        if unit == 0x0A || unit == 0x2028 || unit == 0x2029 {
            result.append(ReferenceBreak(start: index, end: index + 1))
        }
        index += 1
    }
    return result
}

func referenceLines(_ units: [UInt16]) -> [NSRange] {
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
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
