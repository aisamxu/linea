import Foundation
import Testing
@testable import LineaCore

@Suite("TextNavigation")
struct TextNavigationTests {
    // MARK: - grapheme

    @Test func graphemeBoundariesAroundZWJEmoji() {
        let text = "a👩‍👩‍👧‍👦b"
        let ns = text as NSString
        let family = ns.range(of: "👩‍👩‍👧‍👦")
        let familyEnd = family.location + family.length
        let provider = makeProvider(for: text)

        #expect(provider.nextCharacterBoundary(after: 0) == 1)
        #expect(provider.nextCharacterBoundary(after: 1) == familyEnd)
        #expect(provider.nextCharacterBoundary(after: family.location + 2) == familyEnd)
        #expect(provider.nextCharacterBoundary(after: familyEnd) == familyEnd + 1)
        #expect(provider.nextCharacterBoundary(after: familyEnd + 1) == familyEnd + 1)

        #expect(provider.previousCharacterBoundary(before: familyEnd) == 1)
        #expect(provider.previousCharacterBoundary(before: family.location + 2) == 1)
        #expect(provider.previousCharacterBoundary(before: familyEnd + 1) == familyEnd)
        #expect(provider.previousCharacterBoundary(before: 1) == 0)
    }

    @Test func graphemeBoundariesAroundCombiningMarks() {
        let provider = makeProvider(for: "e\u{301}x")
        #expect(provider.nextCharacterBoundary(after: 0) == 2)
        #expect(provider.nextCharacterBoundary(after: 1) == 2)
        #expect(provider.nextCharacterBoundary(after: 2) == 3)
        #expect(provider.previousCharacterBoundary(before: 2) == 0)
        #expect(provider.previousCharacterBoundary(before: 1) == 0)
        #expect(provider.previousCharacterBoundary(before: 3) == 2)
    }

    @Test func crlfIsOneGrapheme() {
        let provider = makeProvider(for: "a\r\nb")
        #expect(provider.nextCharacterBoundary(after: 1) == 3)
        #expect(provider.nextCharacterBoundary(after: 2) == 3)
        #expect(provider.previousCharacterBoundary(before: 3) == 1)
        #expect(provider.previousCharacterBoundary(before: 2) == 1)
    }

    @Test func longClusterExpandsWindow() {
        // 6000 个组合符构成一个 grapheme，超过初始 256 单元窗口。
        let text = "a" + String(repeating: "\u{301}", count: 6_000) + "b"
        let clusterEnd = 6_001
        let provider = makeProvider(for: text)
        #expect(provider.nextCharacterBoundary(after: 0) == clusterEnd)
        #expect(provider.nextCharacterBoundary(after: 5_000) == clusterEnd)
        #expect(provider.previousCharacterBoundary(before: clusterEnd) == 0)
        #expect(provider.previousCharacterBoundary(before: 5_000) == 0)
        #expect(provider.nextCharacterBoundary(after: clusterEnd) == 6_002)
    }

    @Test func boundariesClampOutOfRange() {
        let provider = makeProvider(for: "abc")
        #expect(provider.nextCharacterBoundary(after: -10) == 1)
        #expect(provider.nextCharacterBoundary(after: 99) == 3)
        #expect(provider.previousCharacterBoundary(before: -1) == 0)
        #expect(provider.previousCharacterBoundary(before: 99) == 2)
    }

    // MARK: - ASCII 标识符

    @Test func identifierWordRangeMatchesLegacyBehavior() {
        let provider = makeProvider(for: "foo_bar baz")
        #expect(provider.wordRange(at: 0, mode: .identifier) == NSRange(location: 0, length: 7))
        #expect(provider.wordRange(at: 4, mode: .identifier) == NSRange(location: 0, length: 7))
        #expect(provider.wordRange(at: 7, mode: .identifier) == NSRange(location: 0, length: 7))
        #expect(provider.wordRange(at: 8, mode: .identifier) == NSRange(location: 8, length: 3))
        #expect(provider.wordRange(at: 11, mode: .identifier) == NSRange(location: 8, length: 3))

        let separatorOnly = makeProvider(for: "abc  def")
        #expect(separatorOnly.wordRange(at: 4, mode: .identifier) == nil)
    }

    @Test func identifierBoundaries() {
        let provider = makeProvider(for: "foo_bar baz")
        #expect(provider.previousWordBoundary(before: 8, mode: .identifier) == 0)
        #expect(provider.previousWordBoundary(before: 4, mode: .identifier) == 0)
        #expect(provider.previousWordBoundary(before: 0, mode: .identifier) == 0)
        #expect(provider.nextWordBoundary(after: 0, mode: .identifier) == 7)
        #expect(provider.nextWordBoundary(after: 4, mode: .identifier) == 7)
        #expect(provider.nextWordBoundary(after: 7, mode: .identifier) == 11)
        #expect(provider.nextWordBoundary(after: 11, mode: .identifier) == 11)
    }

    @Test func identifierModeIgnoresCJK() {
        let provider = makeProvider(for: "中文abc")
        #expect(provider.wordRange(at: 2, mode: .identifier) == NSRange(location: 2, length: 3))
        #expect(provider.wordRange(at: 0, mode: .identifier) == nil)
        #expect(provider.nextWordBoundary(after: 0, mode: .identifier) == 5)
        #expect(provider.previousWordBoundary(before: 5, mode: .identifier) == 2)
    }

    // MARK: - Unicode 词

    @Test func unicodeWordRanges() {
        let provider = makeProvider(for: "hello,world")
        #expect(provider.wordRange(at: 0, mode: .word) == NSRange(location: 0, length: 5))
        #expect(provider.wordRange(at: 2, mode: .word) == NSRange(location: 0, length: 5))
        #expect(provider.wordRange(at: 5, mode: .word) == NSRange(location: 0, length: 5))
        #expect(provider.wordRange(at: 6, mode: .word) == NSRange(location: 6, length: 5))
        #expect(provider.wordRange(at: 10, mode: .word) == NSRange(location: 6, length: 5))
        #expect(provider.wordRange(at: 11, mode: .word) == NSRange(location: 6, length: 5))
    }

    @Test func unicodeWordBoundaries() {
        let provider = makeProvider(for: "hello,world")
        #expect(provider.previousWordBoundary(before: 8, mode: .word) == 6)
        #expect(provider.previousWordBoundary(before: 6, mode: .word) == 0)
        #expect(provider.previousWordBoundary(before: 5, mode: .word) == 0)
        #expect(provider.previousWordBoundary(before: 0, mode: .word) == 0)
        #expect(provider.nextWordBoundary(after: 3, mode: .word) == 5)
        #expect(provider.nextWordBoundary(after: 5, mode: .word) == 11)
        #expect(provider.nextWordBoundary(after: 6, mode: .word) == 11)
        #expect(provider.nextWordBoundary(after: 10, mode: .word) == 11)
        #expect(provider.nextWordBoundary(after: 11, mode: .word) == 11)
    }

    @Test func longWordExpandsWindow() {
        let text = String(repeating: "a", count: 10_000)
        let provider = makeProvider(for: text)
        #expect(provider.wordRange(at: 5_000, mode: .word) == NSRange(location: 0, length: 10_000))
        #expect(provider.previousWordBoundary(before: 5_000, mode: .word) == 0)
        #expect(provider.nextWordBoundary(after: 5_000, mode: .word) == 10_000)
    }

    @Test func lineIndexIsExposed() {
        let provider = makeProvider(for: "one\ntwo\r\nthree")
        #expect(provider.lineIndex.lineCount == 3)
        #expect(provider.lineIndex.lineRange(at: 2) == NSRange(location: 4, length: 5))
        #expect(provider.lineIndex.previousLineStart(before: 9) == 4)
        #expect(provider.textLength == 14)
    }

    private func makeProvider(for text: String) -> DefaultTextNavigationProvider {
        DefaultTextNavigationProvider(buffer: PieceTreeBuffer(text: text))
    }
}
