import Foundation
import Testing
@testable import LineaCore

@Suite("TextRange")
struct TextRangeTests {
    @Test func clampsRangeToDocumentLength() {
        #expect(
            NSRange(location: 3, length: 10).clampedToTextLength(8)
                == NSRange(location: 3, length: 5)
        )
        #expect(
            NSRange(location: 20, length: 5).clampedToTextLength(8)
                == NSRange(location: 8, length: 0)
        )
        // 空文档上的光标仍然有效。
        #expect(
            NSRange(location: 0, length: 0).clampedToTextLength(0)
                == NSRange(location: 0, length: 0)
        )
    }

    @Test func clampsNegativeComponentsToZero() {
        // 编辑命令内部语义：负位置按 0、负长度按 0，保留另一分量。
        #expect(
            NSRange(location: -3, length: 2).clampedToTextLength(8)
                == NSRange(location: 0, length: 2)
        )
        #expect(
            NSRange(location: 3, length: -2).clampedToTextLength(8)
                == NSRange(location: 3, length: 0)
        )
        // NSNotFound 不是普通越界，统一归零。
        #expect(
            NSRange(location: NSNotFound, length: 2).clampedToTextLength(8)
                == NSRange(location: 0, length: 0)
        )
        // 负文本长度按空文档处理，避免减法下溢。
        #expect(
            NSRange(location: 3, length: 2).clampedToTextLength(-1)
                == NSRange(location: 0, length: 0)
        )
    }

    @Test func sanitizesInvalidExternalRanges() {
        // 外部入口语义：畸形范围整体归零，不做局部修正。
        #expect(
            NSRange(location: -3, length: 2).sanitizedToTextLength(8)
                == NSRange(location: 0, length: 0)
        )
        #expect(
            NSRange(location: 3, length: -2).sanitizedToTextLength(8)
                == NSRange(location: 0, length: 0)
        )
        #expect(
            NSRange(location: NSNotFound, length: 0).sanitizedToTextLength(8)
                == NSRange(location: 0, length: 0)
        )
        // 合法但越界的范围仍然夹取，不视为畸形。
        #expect(
            NSRange(location: 6, length: 10).sanitizedToTextLength(8)
                == NSRange(location: 6, length: 2)
        )
        #expect(
            NSRange(location: 20, length: 5).sanitizedToTextLength(8)
                == NSRange(location: 8, length: 0)
        )
    }

    @Test func validatesRangesAgainstDocumentLength() {
        #expect(NSRange(location: 0, length: 0).isValidTextRange(in: 0))
        #expect(NSRange(location: 5, length: 3).isValidTextRange(in: 8))
        #expect(!NSRange(location: 6, length: 3).isValidTextRange(in: 8))
        #expect(!NSRange(location: 9, length: 0).isValidTextRange(in: 8))
        #expect(!NSRange(location: NSNotFound, length: 0).isValidTextRange(in: 8))
        #expect(!NSRange(location: 0, length: -1).isValidTextRange(in: 8))
        #expect(!NSRange(location: 0, length: 0).isValidTextRange(in: -1))
    }
}
