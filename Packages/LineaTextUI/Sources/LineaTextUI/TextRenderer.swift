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
        caretVisible: Bool,
        composition: CompositionState? = nil
    ) {
        // 背景只在脏区域内填充，滚动时由 NSScrollView 负责暴露区域。
        context.setFillColor(theme.background.cgColor)
        context.fill(dirtyRect)

        let lines = layout.lines(in: dirtyRect)
        guard !lines.isEmpty else { return }

        let compositionLine = composition.flatMap {
            layout.compositionLine(for: $0)
        }
        drawSelections(
            in: context,
            dirtyRect: dirtyRect,
            lines: lines,
            layout: layout,
            selections: selections,
            isComposing: compositionLine != nil
        )
        drawCompositionSelection(
            in: context,
            dirtyRect: dirtyRect,
            layout: layout,
            compositionLine: compositionLine
        )
        drawText(
            in: context,
            dirtyRect: dirtyRect,
            lines: lines,
            layout: layout,
            compositionLine: compositionLine
        )
        drawCompositionUnderline(
            in: context,
            dirtyRect: dirtyRect,
            layout: layout,
            compositionLine: compositionLine
        )
        drawCaret(
            in: context,
            dirtyRect: dirtyRect,
            layout: layout,
            selections: selections,
            caretVisible: caretVisible,
            compositionLine: compositionLine
        )
    }

    // MARK: - 选区

    private func drawSelections(
        in context: CGContext,
        dirtyRect: CGRect,
        lines: Range<Int>,
        layout: TextLayoutEngine,
        selections: [TextSelection],
        isComposing: Bool
    ) {
        guard !selections.isEmpty else { return }

        // 只处理与可见行相交的选区，避免一个跨 10 万行的选区分段全部计算。
        let firstLine = layout.layoutLine(number: lines.lowerBound)
        let lastLine = layout.layoutLine(number: lines.upperBound - 1)
        let visibleStart = firstLine.lineRange.location
        let visibleEnd = lastLine.lineRange.location + lastLine.lineRange.length

        context.setFillColor(theme.selection.cgColor)
        // 组合期间主选区被 marked text 临时替换，不再高亮原文。
        let visibleSelections = isComposing ? selections.dropLast() : selections[...]
        for selection in visibleSelections {
            let range = selection.range
            guard range.length > 0 else { continue }
            let end = range.location + range.length
            guard end >= visibleStart, range.location <= visibleEnd else { continue }

            // 只计算可见行，避免全选 10 万行时每帧遍历整个文档。
            for rect in layout.rects(for: range, intersectingLines: lines) {
                guard rect.intersects(dirtyRect) else { continue }
                context.fill(rect)
            }
        }
    }

    // MARK: - 文本

    private func drawText(
        in context: CGContext,
        dirtyRect: CGRect,
        lines: Range<Int>,
        layout: TextLayoutEngine,
        compositionLine: CompositionLine?
    ) {
        context.setFillColor(theme.text.cgColor)
        // 只取与脏区域水平相交的片段；超长行不会为了绘制一行而排版整行。
        let xRange = dirtyRect.minX...max(dirtyRect.minX, dirtyRect.maxX)
        for lineNumber in lines {
            // 组合行用「前缀 + marked text + 后缀」的虚拟行替代原文。
            if let compositionLine, compositionLine.lineNumber == lineNumber {
                drawCompositionText(
                    in: context,
                    dirtyRect: dirtyRect,
                    layout: layout,
                    compositionLine: compositionLine
                )
                continue
            }

            let line = layout.layoutLine(number: lineNumber)
            guard !line.isEmpty else { continue }

            let fragments = layout.fragments(
                forLine: lineNumber,
                intersecting: xRange
            )
            guard !fragments.isEmpty else { continue }

            context.saveGState()
            // isFlipped 视图中，文本空间的 +y 需要翻转成屏幕向上。
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            for fragment in fragments {
                context.textPosition = CGPoint(
                    x: fragment.x,
                    y: layout.y(forLine: lineNumber) + fragment.ascent
                )
                CTLineDraw(fragment.line, context)
            }
            context.restoreGState()
        }
    }

    /// 绘制组合虚拟行，裁剪到脏区域，避免整行超出可见范围。
    private func drawCompositionText(
        in context: CGContext,
        dirtyRect: CGRect,
        layout: TextLayoutEngine,
        compositionLine: CompositionLine
    ) {
        context.saveGState()
        context.clip(to: dirtyRect)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(
            x: 0,
            y: layout.y(forLine: compositionLine.lineNumber) + compositionLine.ascent
        )
        CTLineDraw(compositionLine.line, context)
        context.restoreGState()
    }

    // MARK: - 输入法组合

    /// 组合内部选区，画在虚拟文本下方。
    private func drawCompositionSelection(
        in context: CGContext,
        dirtyRect: CGRect,
        layout: TextLayoutEngine,
        compositionLine: CompositionLine?
    ) {
        guard let compositionLine,
              compositionLine.selectedRange.length > 0
        else {
            return
        }
        let start = compositionLine.prefixLength
            + compositionLine.selectedRange.location
        let end = start + compositionLine.selectedRange.length
        let startX = CGFloat(
            CTLineGetOffsetForStringIndex(
                compositionLine.line,
                start,
                nil
            )
        )
        let endX = CGFloat(
            CTLineGetOffsetForStringIndex(
                compositionLine.line,
                end,
                nil
            )
        )
        let rect = CGRect(
            x: startX,
            y: layout.y(forLine: compositionLine.lineNumber),
            width: max(0, endX - startX),
            height: layout.lineHeight
        )
        guard rect.intersects(dirtyRect) else { return }
        context.setFillColor(theme.selection.cgColor)
        context.fill(rect)
    }

    /// marked text 下划线。
    private func drawCompositionUnderline(
        in context: CGContext,
        dirtyRect: CGRect,
        layout: TextLayoutEngine,
        compositionLine: CompositionLine?
    ) {
        guard let compositionLine else { return }
        let width = compositionLine.markedEndX - compositionLine.markedStartX
        guard width > 0 else { return }
        let rect = CGRect(
            x: compositionLine.markedStartX,
            y: layout.y(forLine: compositionLine.lineNumber)
                + compositionLine.ascent + 2,
            width: width,
            height: 2
        )
        guard rect.intersects(dirtyRect) else { return }
        context.setFillColor(theme.text.cgColor)
        context.fill(rect)
    }

    // MARK: - 光标

    private func drawCaret(
        in context: CGContext,
        dirtyRect: CGRect,
        layout: TextLayoutEngine,
        selections: [TextSelection],
        caretVisible: Bool,
        compositionLine: CompositionLine?
    ) {
        guard caretVisible else { return }

        // 组合期间光标在 marked text 内部，位置由输入法选区决定。
        if let compositionLine {
            let rect = CGRect(
                x: compositionLine.caretX,
                y: layout.y(forLine: compositionLine.lineNumber),
                width: 2,
                height: layout.lineHeight
            )
            guard rect.intersects(dirtyRect) else { return }
            context.setFillColor(theme.caret.cgColor)
            context.fill(rect)
            return
        }

        guard let caret = selections.last, caret.isCaret else { return }
        let rect = layout.caretRect(for: caret.range.location)
        guard rect.intersects(dirtyRect) else { return }
        context.setFillColor(theme.caret.cgColor)
        context.fill(rect)
    }
}
