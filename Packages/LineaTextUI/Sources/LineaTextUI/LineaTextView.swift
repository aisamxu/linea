import AppKit
import CoreGraphics
import Foundation
import LineaCore

/// 自建只读文本视图。
///
/// Phase 2 先验证布局、滚动与绘制；编辑/输入法/查找在后续阶段接入。
/// 视图只持有布局缓存和滚动状态，文本与选区始终从 `EditorEngine`/调用方读取。
public final class LineaTextView: NSView {
    public let engine: EditorEngine
    public let layoutEngine: CoreTextLayoutEngine

    public var theme: TextTheme {
        didSet {
            renderer.theme = theme
            lineNumberRuler?.refresh()
            needsDisplay = true
        }
    }

    /// 当前选区；最后一个为主选区。只影响绘制，不修改引擎。
    public var selections: [TextSelection] = [] {
        didSet {
            guard selections != oldValue else { return }
            invalidateSelectionDisplay()
        }
    }

    /// 光标闪烁状态由控制器驱动；Phase 2 默认不画光标。
    public var isCaretVisible = false {
        didSet {
            guard isCaretVisible != oldValue else { return }
            needsDisplay = true
        }
    }

    public weak var lineNumberRuler: LineNumberRulerView?

    private var renderer: TextRenderer
    private var clipObservation: NSObjectProtocol?

    public init(engine: EditorEngine, theme: TextTheme = .standard) {
        self.engine = engine
        self.theme = theme
        self.renderer = TextRenderer(theme: theme)
        self.layoutEngine = CoreTextLayoutEngine(
            engine: engine,
            font: theme.font,
            tabInterval: theme.tabInterval,
            lineHeightMultiple: theme.lineHeightMultiple
        )
        super.init(frame: .zero)

        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizingMask = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let clipObservation {
            NotificationCenter.default.removeObserver(clipObservation)
        }
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    // MARK: - 文档几何

    public var documentHeight: CGFloat { layoutEngine.documentHeight }
    public var documentWidth: CGFloat { layoutEngine.documentWidth }

    /// 设置视口宽度；文档至少与视口同宽，长行按需撑开横向滚动。
    public func setViewportWidth(_ width: CGFloat) {
        let clamped = max(0, width)
        guard abs(layoutEngine.viewportWidth - clamped) > 0.5 else { return }
        layoutEngine.viewportWidth = clamped
        updateDocumentFrame()
        needsDisplay = true
    }

    /// 文本内容或字体变化后调用：清空行缓存并更新文档尺寸。
    public func reloadData() {
        layoutEngine.invalidateLayout()
        updateDocumentFrame()
        lineNumberRuler?.refresh()
        needsDisplay = true
    }

    /// 把文档尺寸同步到 frame；滚动视图据此决定滚动条范围。
    public func updateDocumentFrame() {
        let newSize = NSSize(
            width: max(layoutEngine.documentWidth, layoutEngine.viewportWidth),
            height: max(layoutEngine.documentHeight, 1)
        )
        guard frame.size != newSize else { return }
        setFrameSize(newSize)
    }

    public func scrollRangeToVisible(_ range: NSRange) {
        let rect: CGRect
        if range.length == 0 {
            rect = layoutEngine.caretRect(for: range.location)
        } else {
            let rects = layoutEngine.rects(for: range)
            guard let first = rects.first else { return }
            rect = rects.dropFirst().reduce(first) { $0.union($1) }
        }
        scrollToVisible(rect)
    }

    public func scrollRangeToVisible(offset: Int) {
        scrollRangeToVisible(NSRange(location: offset, length: 0))
    }

    // MARK: - 视图生命周期

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachToScrollViewIfNeeded()
    }

    public override func layout() {
        super.layout()
        syncViewportWidth()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 颜色在 draw 时按当前 appearance 解析，不需要重建布局缓存。
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            renderer.draw(
                in: context,
                dirtyRect: dirtyRect,
                layout: layoutEngine,
                selections: selections,
                caretVisible: isCaretVisible
            )
        }
    }

    // MARK: - 内部

    private func attachToScrollViewIfNeeded() {
        guard let clipView = enclosingScrollView?.contentView else { return }

        if let clipObservation {
            NotificationCenter.default.removeObserver(clipObservation)
            self.clipObservation = nil
        }
        clipView.postsBoundsChangedNotifications = true
        clipObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.syncViewportWidth()
        }
        syncViewportWidth()
    }

    private func syncViewportWidth() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        setViewportWidth(clipView.bounds.width)
    }

    private func invalidateSelectionDisplay() {
        // 选区矩形与文本同层绘制，直接重绘可见区域；不创建选区子视图。
        needsDisplay = true
    }
}
