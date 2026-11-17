import Foundation
import Testing
@testable import LineaTextUI

@Suite("FindMatchScanner")
struct FindMatchScannerTests {
    @Test func matchesLiteralTextCaseInsensitively() {
        let ranges = FindMatchScanner.ranges(of: "ab", in: "AB ab aB")
        #expect(ranges == [
            NSRange(location: 0, length: 2),
            NSRange(location: 3, length: 2),
            NSRange(location: 6, length: 2),
        ])
    }

    @Test func matchesDoNotOverlap() {
        // 与 NSTextFinder 的“查找下一个”一致：从上一个匹配末尾继续。
        #expect(FindMatchScanner.ranges(of: "aa", in: "aaaa") == [
            NSRange(location: 0, length: 2),
            NSRange(location: 2, length: 2),
        ])
    }

    @Test func emptyNeedleReturnsNoMatches() {
        #expect(FindMatchScanner.ranges(of: "", in: "abc").isEmpty)
        #expect(FindMatchScanner.ranges(of: "a", in: "").isEmpty)
    }

    @Test func respectsLimit() {
        #expect(FindMatchScanner.ranges(of: "a", in: "aaaa", limit: 2).count == 2)
        #expect(FindMatchScanner.ranges(of: "a", in: "aaaa", limit: 0).isEmpty)
    }

    @Test func handlesUnicodeAndNewlines() {
        let text = "Ärger\närger\n"
        let ranges = FindMatchScanner.ranges(of: "ärger", in: text)
        #expect(ranges == [
            NSRange(location: 0, length: 5),
            NSRange(location: 6, length: 5),
        ])
    }
}
