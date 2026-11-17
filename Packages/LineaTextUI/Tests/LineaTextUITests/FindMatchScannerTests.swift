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

    @Test func matchCaseOnlyReturnsExactCase() {
        let text = "AB ab Ab aB"
        let ranges = FindMatchScanner.ranges(
            of: "AB",
            in: text,
            options: FindMatchOptions(matchCase: true)
        )
        #expect(ranges == [NSRange(location: 0, length: 2)])
    }

    @Test func wholeWordRejectsPartialIdentifiers() {
        let text = "cat scatter cat_cat cat2 9cat cat."
        let ranges = FindMatchScanner.ranges(
            of: "cat",
            in: text,
            options: FindMatchOptions(wholeWord: true)
        )
        // 只有两侧都不接字母/数字/下划线的 cat 命中。
        #expect(ranges == [
            NSRange(location: 0, length: 3),
            NSRange(location: 30, length: 3),
        ])
    }

    @Test func wholeWordCombinesWithMatchCase() {
        let text = "Cat cat CAT"
        let ranges = FindMatchScanner.ranges(
            of: "cat",
            in: text,
            options: FindMatchOptions(matchCase: true, wholeWord: true)
        )
        #expect(ranges == [NSRange(location: 4, length: 3)])
    }

    @Test func wholeWordAllowsPunctuationBoundaries() {
        let text = "(cat) [cat], cat"
        let ranges = FindMatchScanner.ranges(
            of: "cat",
            in: text,
            options: FindMatchOptions(wholeWord: true)
        )
        #expect(ranges == [
            NSRange(location: 1, length: 3),
            NSRange(location: 7, length: 3),
            NSRange(location: 13, length: 3),
        ])
    }
}
