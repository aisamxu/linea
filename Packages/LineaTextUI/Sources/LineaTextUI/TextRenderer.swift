import AppKit
import CoreGraphics
import CoreText
import Foundation
import LineaCore

/// 单视图直接绘制：背景、选区、文本、光标一次画完。
///
/// 不创建逐选区/逐光标的子视图或 layer；`dirtyRect` 之外的行不排版。
public struct TextRenderer {
    public var theme: TextTheme

    public init(theme: TextTheme) {
        self.theme = theme
    }

    public func draw(
        in context: CGContext,
        dirtyRect: CGRect,
        layout: TextLayoutEngine,
        selections: [TextSelection],
        caretVisible: Bool
    ) {
        // 背景只在脏区域内填充，滚动时由 NSScrollView 负责暴露区域。
        context.setFillColor(theme.background.cgColor)
        context.fill(dirtyRect)

        let lines = layout.lines(in: dirtyRect)
        guard !lines.isEmpty else { return }

        drawSelections(
            in: context,
            dirtyRect: dirtyRect,
            lines: lines,
            layout: layout,
            selections: selections
        )
        drawText(in: context, lines: lines, layout: layout)
        drawCaret(
            in: context,
            dirtyRect: dirtyRect,
            layout: layout,
            selections: selections,
            caretVisible: caretVisible
        )
    }

    // MARK: - 选区

    private func drawSelections(
        in context: CGContext,
        dirtyRect: CGRect,
        lines: Range<Int>,
        layout: TextLayoutEngine,
        selections: [TextSelection]
    ) {
        guard !selections.isEmpty else { return }

        // 只处理与可见行相交的选区，避免一个跨 10 万行的选区分段全部计算。
        let firstLine = layout.layoutLine(number: lines.lowerBound)
        let lastLine = layout.layoutLine(number: lines.upperBound - 1)
        let visibleStart = firstLine.lineRange.location
        let visibleEnd = lastLine.lineRange.location + lastLine.lineRange.length

        context.setFillColor(theme.selection.cgColor)
        for selection in selections {
            let range = selection.range
            guard range.length > 0 else { continue }
            let end = range.location + range.length
            guard end >= visibleStart, range.location <= visibleEnd else { continue }

            for rect in layout.rects(for: range) {
                guard rect.intersects(dirtyRect) else { continue }
                context.fill(rect)
            }
        }
    }

    // MARK: - 文本

    private func drawText(
        in context: CGContext,
        lines: Range<Int>,
        layout: TextLayoutEngine
    ) {
        context.setFillColor(theme.text.cgColor)
        for lineNumber in lines {
            let line = layout.layoutLine(number: lineNumber)
            guard !line.isEmpty else { continue }

            context.saveGState()
            // isFlipped 视图中，文本空间的 +y 需要翻转成屏幕向上。
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(
                x: 0,
                y: layout.y(forLine: lineNumber) + line.ascent
            )
            CTLineDraw(line.line, context)
            context.restoreGState()
        }
    }

    // MARK: - 光标

    private func drawCaret(
        in context: CGContext,
        dirtyRect: CGRect,
        layout: TextLayoutEngine,
        selections: [TextSelection],
        caretVisible: Bool
    ) {
        guard caretVisible, let caret = selections.last, caret.isCaret else { return }
        let rect = layout.caretRect(for: caret.range.location)
        guard rect.intersects(dirtyRect) else { return }
        context.setFillColor(theme.caret.cgColor)
        context.fill(rect)
    }
}
