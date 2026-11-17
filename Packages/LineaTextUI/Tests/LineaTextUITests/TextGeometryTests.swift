import CoreGraphics
import Testing
@testable import LineaTextUI

@Suite("TextGeometry")
struct TextGeometryTests {
    private let lineHeight: CGFloat = 20

    @Test func clampsLineNumbers() {
        #expect(TextGeometry.clampedLine(-5, lineCount: 10) == 1)
        #expect(TextGeometry.clampedLine(0, lineCount: 10) == 1)
        #expect(TextGeometry.clampedLine(1, lineCount: 10) == 1)
        #expect(TextGeometry.clampedLine(10, lineCount: 10) == 10)
        #expect(TextGeometry.clampedLine(11, lineCount: 10) == 10)
        // 空文档仍然有一行，避免除零和空范围。
        #expect(TextGeometry.clampedLine(1, lineCount: 0) == 1)
    }

    @Test func lineTopY() {
        #expect(TextGeometry.y(forLine: 1, lineHeight: lineHeight) == 0)
        #expect(TextGeometry.y(forLine: 2, lineHeight: lineHeight) == 20)
        #expect(TextGeometry.y(forLine: 5, lineHeight: lineHeight) == 80)
        // 非正行号按第一行处理。
        #expect(TextGeometry.y(forLine: 0, lineHeight: lineHeight) == 0)
    }

    @Test func lineNumberAtY() {
        #expect(TextGeometry.lineNumber(forY: -10, lineHeight: lineHeight, lineCount: 5) == 1)
        #expect(TextGeometry.lineNumber(forY: 0, lineHeight: lineHeight, lineCount: 5) == 1)
        #expect(TextGeometry.lineNumber(forY: 19.99, lineHeight: lineHeight, lineCount: 5) == 1)
        #expect(TextGeometry.lineNumber(forY: 20, lineHeight: lineHeight, lineCount: 5) == 2)
        #expect(TextGeometry.lineNumber(forY: 99, lineHeight: lineHeight, lineCount: 5) == 5)
        #expect(TextGeometry.lineNumber(forY: 1_000, lineHeight: lineHeight, lineCount: 5) == 5)
        #expect(TextGeometry.lineNumber(forY: 10, lineHeight: 0, lineCount: 5) == 1)
    }

    @Test func visibleLineRange() {
        let lines = TextGeometry.lines(
            in: CGRect(x: 0, y: 0, width: 100, height: 20),
            lineHeight: lineHeight,
            lineCount: 10
        )
        #expect(lines == 1..<2)

        let straddling = TextGeometry.lines(
            in: CGRect(x: 0, y: 19, width: 100, height: 2),
            lineHeight: lineHeight,
            lineCount: 10
        )
        #expect(straddling == 1..<3)

        let partial = TextGeometry.lines(
            in: CGRect(x: 0, y: 25, width: 100, height: 10),
            lineHeight: lineHeight,
            lineCount: 10
        )
        #expect(partial == 2..<3)

        let clipped = TextGeometry.lines(
            in: CGRect(x: 0, y: 180, width: 100, height: 100),
            lineHeight: lineHeight,
            lineCount: 10
        )
        #expect(clipped == 10..<11)
    }

    @Test func emptyRectHasNoLines() {
        #expect(
            TextGeometry.lines(
                in: .zero,
                lineHeight: lineHeight,
                lineCount: 10
            ).isEmpty
        )
        #expect(
            TextGeometry.lines(
                in: CGRect(x: 0, y: 0, width: 0, height: 100),
                lineHeight: lineHeight,
                lineCount: 10
            ).isEmpty
        )
        #expect(
            TextGeometry.lines(
                in: CGRect(x: 0, y: 0, width: 100, height: 0),
                lineHeight: lineHeight,
                lineCount: 10
            ).isEmpty
        )
    }

    @Test func lineRect() {
        let rect = TextGeometry.lineRect(
            forLine: 3,
            lineHeight: lineHeight,
            width: 500
        )
        #expect(rect.origin == CGPoint(x: 0, y: 40))
        #expect(rect.size == CGSize(width: 500, height: 20))
    }
}
