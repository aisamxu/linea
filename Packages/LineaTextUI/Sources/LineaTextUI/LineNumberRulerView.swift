import AppKit
import Foundation

/// 行号 ruler。
///
/// 只绘制当前可见行，不维护行号子视图；宽度随位数增长，最小 35pt。
/// 行号字体/颜色取自 `LineaTextView.theme`，随系统外观切换。
public final class LineNumberRulerView: NSRulerView {
    public private(set) weak var textView: LineaTextView?

    /// 行号与分隔线之间、行号与左边缘之间的留白。
    private let horizontalPadding: CGFloat = 6
    private let minimumThickness: CGFloat = 35

    /// 最近一次绘制覆盖的行范围，供测试确认没有遍历全文。
    public private(set) var lastVisibleLineRange: Range<Int> = 1..<1

    public init(scrollView: NSScrollView, textView: LineaTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)

        clientView = textView
        ruleThickness = minimumThickness
        scrollView.verticalRulerView = self
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        textView.lineNumberRuler = self

        // 系统 banner 式 ruler 会在自身边界外绘制装饰线和背景，进而盖住
        // 窗口上方的标签栏；把 ruler 图层裁剪到自身范围。
        wantsLayer = true
        layer?.masksToBounds = true

        refresh()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var isFlipped: Bool { true }

    /// 主题或行数变化后刷新宽度与内容。
    public func refresh() {
        guard let textView else { return }
        let theme = textView.theme
        let digitWidth = ("0" as NSString).size(
            withAttributes: [.font: theme.lineNumberFont]
        ).width
        let digits = max(2, String(max(1, textView.layoutEngine.lineCount)).count)
        let desired = max(
            minimumThickness,
            ceil(CGFloat(digits) * digitWidth) + horizontalPadding * 2
        )
        if abs(ruleThickness - desired) > 0.5 {
            ruleThickness = desired
        }
        needsDisplay = true
    }

    public override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let context = NSGraphicsContext.current?.cgContext
        else {
            return
        }

        let theme = textView.theme
        let layout = textView.layoutEngine
        let bounds = self.bounds

        // 脏矩形必须与 ruler 自身范围求交：AppKit（macOS 26 的 banner 式 ruler）
        // 会传入覆盖整个滚动视图的 rect，例如 (0, -64, 900, 600)。若不裁剪，
        // 白色背景和分隔线会画到行号栏外，把上方标签栏整条盖住。
        let dirtyRect = bounds.intersection(rect)
        guard !dirtyRect.isEmpty else { return }

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)

        // 背景只填裁剪后的脏区域，既避免滚动时重绘整条 ruler，也不会越界。
        context.setFillColor(theme.background.cgColor)
        context.fill(dirtyRect)

        // 文档坐标 -> ruler 坐标。滚动后 textView 原点位于 ruler 可见区域上方。
        let relativePoint = convert(NSPoint.zero, from: textView)
        // 视图尚未进入窗口时 visibleRect 可能为空，依次退回 clip view 和文档
        // bounds，保证首帧和离屏绘制也能得到正确行范围。
        let clipBounds = scrollView?.contentView.bounds ?? .zero
        let visibleRect: CGRect
        if !textView.visibleRect.isEmpty {
            visibleRect = textView.visibleRect
        } else if clipBounds.width > 0, clipBounds.height > 0 {
            visibleRect = clipBounds
        } else {
            visibleRect = textView.bounds
        }
        let visibleLines = layout.lines(in: visibleRect)
        lastVisibleLineRange = visibleLines
        guard !visibleLines.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: theme.lineNumberFont,
            .foregroundColor: theme.lineNumber,
        ]

        for lineNumber in visibleLines {
            let text = String(lineNumber) as NSString
            let textSize = text.size(withAttributes: attributes)
            let lineY = layout.y(forLine: lineNumber) + relativePoint.y
            let x = bounds.width - horizontalPadding - textSize.width
            let y = lineY + (layout.lineHeight - textSize.height) / 2
            text.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
        }

        // 右侧分隔线，与编辑器内容区分；高度同样限制在 ruler 范围内。
        context.setFillColor(theme.lineNumberSeparator.cgColor)
        context.fill(
            CGRect(
                x: bounds.maxX - 1,
                y: dirtyRect.minY,
                width: 1,
                height: dirtyRect.height
            )
        )
    }
}
