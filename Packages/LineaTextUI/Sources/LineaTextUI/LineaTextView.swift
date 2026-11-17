import AppKit
import CoreGraphics
import Foundation
import LineaCore

/// 可编辑的自绘文本视图。
///
/// - 文本、选区、撤销状态的唯一事实源是 `EditorEngine`；视图只保留布局缓存、
///   拖拽与光标闪烁等临时 UI 状态。
/// - 所有编辑最终都经过引擎事务：一次按键、粘贴、多光标输入只产生一个历史条目。
/// - 光标与选区在同一次 `draw` 中绘制，不创建逐光标子视图或 layer。
public final class LineaTextView:
    NSView,
    NSTextInputClient,
    NSTextFinderClient,
    NSDraggingSource,
    TextSurface
{
    public let engine: EditorEngine
    public let layoutEngine: CoreTextLayoutEngine

    public var theme: TextTheme {
        didSet {
            renderer.theme = theme
            lineNumberRuler?.refresh()
            needsDisplay = true
        }
    }

    /// 视图处理完一次引擎变更后的外部回调。
    ///
    /// `LineaTextView` 接管了 `engine.onChange`，控制器应设置本属性而不是直接覆盖引擎回调。
    public var onChange: ((EditorChange) -> Void)?
    /// Esc（`cancelOperation:`）先交给外部处理；返回 true 表示已消费，
    /// 视图不再折叠多光标。查找栏打开时用它优先收起查找栏。
    public var onCancelOperation: (() -> Bool)?

    /// 光标闪烁状态。视图成为第一响应者后由 Timer 驱动；测试可手动设置。
    public var isCaretVisible = false {
        didSet {
            guard isCaretVisible != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 查找匹配高亮范围（升序）。由控制器根据查找器结果更新，视图只负责绘制。
    public var findHighlightRanges: [NSRange] = [] {
        didSet {
            guard findHighlightRanges != oldValue else { return }
            needsDisplay = true
        }
    }

    public weak var lineNumberRuler: LineNumberRulerView?

    /// 编辑开关。关闭时引擎拒绝所有修改，移动和选择仍然可用。
    public var isEditable: Bool {
        get { engine.isEditable }
        set {
            engine.isEditable = newValue
            if !newValue {
                engine.unmarkText()
                stopCaretBlinking()
            }
        }
    }

    /// 当前选区，最后一个为主选区；读写都直接落到引擎。
    public var selections: [TextSelection] {
        get { engine.selections }
        set {
            guard engine.setSelections(newValue) else { return }
            verticalAnchorXs = nil
            extendAnchors = nil
            selectionDisplayDidChange()
        }
    }

    /// 所有非空选区的文本，按文档顺序用换行连接（与 1.0.2 的复制行为一致）。
    public var selectedText: String {
        engine.selections
            .filter { $0.range.length > 0 }
            .sorted { $0.range.location < $1.range.location }
            .map { engine.substring(in: $0.range) }
            .joined(separator: "\n")
    }

    /// 视图已经同步到的引擎版本；绘制前发现落后会自愈重建布局缓存。
    public private(set) var displayedVersion: UInt64

    private var renderer: TextRenderer
    private var clipObservation: NSObjectProtocol?
    /// 上一次通知 AX 的可见首行，滚动时只在跨行时发 layoutChanged。
    private var lastAccessibilityVisibleLine = -1
    private var previousOnChange: ((EditorChange) -> Void)?

    private var caretBlinkTimer: Timer?

    private var isDraggingSelection = false
    private var dragAnchorOffset: Int?
    private var dragPoint: CGPoint = .zero
    private var dragScrollTimer: Timer?

    /// 在非空选区内按下但尚未超过拖拽阈值时的源选区。
    private var pendingDragSelection: NSRange?
    private var pendingDragPoint: CGPoint = .zero
    private var pendingDragClickCount = 1
    /// 本视图发起的拖拽源范围；drop 时据此把复制升级为移动。
    private var internalDragRange: NSRange?
    /// 拖拽悬停的插入点；非 nil 时绘制落点指示线。
    private(set) var dropInsertionOffset: Int?
    private var dropPoint: CGPoint = .zero
    private var dropScrollTimer: Timer?

    /// 连续垂直移动时保留每个光标的原始 x，避免经过短行后列位置漂移。
    private var verticalAnchorXs: [CGFloat]?

    /// 连续 Shift 扩展时保存每个选区的固定锚点，方向反转不会漂移。
    private var extendAnchors: [Int]?

    /// 输入法组合内 Shift 扩展的固定锚点（marked text 内 UTF-16 偏移）。
    private var compositionAnchor: Int?

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
        self.displayedVersion = engine.version
        super.init(frame: .zero)

        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizingMask = []

        // 只声明纯文本：文件 URL 等类型不会触发拖入。
        registerForDraggedTypes([.string])

        // 视图接管引擎回调：先更新布局/几何，再转发给外部控制器。
        previousOnChange = engine.onChange
        engine.onChange = { [weak self] change in
            guard let self else { return }
            self.apply(change: change)
            self.previousOnChange?(change)
            self.onChange?(change)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let clipObservation {
            NotificationCenter.default.removeObserver(clipObservation)
        }
        caretBlinkTimer?.invalidate()
        dragScrollTimer?.invalidate()
        dropScrollTimer?.invalidate()
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
        displayedVersion = engine.version
        verticalAnchorXs = nil
        extendAnchors = nil
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

    // MARK: - 引擎变更同步

    /// 引擎完成一次编辑后的视图同步入口。
    public func apply(change: EditorChange) {
        // 文本变化会让所有行的内容与宽度失效；下一帧只重排可见行。
        layoutEngine.invalidateLayout()
        displayedVersion = change.versionAfter
        verticalAnchorXs = nil
        extendAnchors = nil
        updateDocumentFrame()
        if change.lineCountBefore != change.lineCountAfter {
            lineNumberRuler?.refresh()
        }

        resetCaretBlink()
        needsDisplay = true

        // 编辑后只把主光标滚入可见区域；多光标不抢滚动。
        if let primary = engine.selections.last {
            scrollRangeToVisible(offset: primary.insertionOffset)
        }

        // 一次编辑只发一次值变化通知。
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    public override func draw(_ dirtyRect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        healIfVersionMismatched()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            renderer.draw(
                in: context,
                dirtyRect: dirtyRect,
                layout: layoutEngine,
                selections: engine.selections,
                caretVisible: isCaretVisible,
                composition: engine.composition,
                findHighlights: findHighlightRanges
            )
            drawDropIndicator(in: context, dirtyRect: dirtyRect)
        }
    }

    /// 拖拽悬停时在落点画一条竖向指示线。
    private func drawDropIndicator(in context: CGContext, dirtyRect: CGRect) {
        guard let offset = dropInsertionOffset, engine.isEditable else { return }
        let caret = layoutEngine.caretRect(for: offset)
        let indicator = CGRect(
            x: caret.minX - 1,
            y: caret.minY,
            width: 2,
            height: caret.height
        )
        guard indicator.intersects(dirtyRect) else { return }
        context.setFillColor(theme.caret.withAlphaComponent(0.7).cgColor)
        context.fill(indicator)
    }

    /// RELEASE 下若外部绕过视图直接改了引擎，绘制前重建缓存，禁止带病渲染。
    private func healIfVersionMismatched() {
        guard displayedVersion != engine.version else { return }
        layoutEngine.invalidateLayout()
        displayedVersion = engine.version
        updateDocumentFrame()
        lineNumberRuler?.refresh()
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

    public override func becomeFirstResponder() -> Bool {
        isCaretVisible = true
        scheduleCaretTimer()
        return true
    }

    public override func resignFirstResponder() -> Bool {
        stopCaretBlinking()
        return true
    }

    // MARK: - 键盘输入

    public override func keyDown(with event: NSEvent) {
        // 普通文本走 insertText(_:replacementRange:)；命令走标准键位绑定。
        interpretKeyEvents([event])
    }

    public override func doCommand(by selector: Selector) {
        // 标准键位绑定方法都实现在本类；这里兜底转发，
        // 不认识的命令交给 NSResponder 默认实现（通常是提示音）。
        guard selector != #selector(doCommand(by:)) else { return }
        if responds(to: selector) {
            perform(selector, with: nil)
        }
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string
            ?? (string as? String)
            ?? ""
        guard !text.isEmpty else { return }

        resetCaretBlink()
        if engine.isComposing {
            // 输入法提交：把最终文本作为一次事务写入主选区。
            compositionAnchor = nil
            engine.insertText(text)
            inputContext?.invalidateCharacterCoordinates()
            return
        }
        if replacementRange.location != NSNotFound {
            engine.replace(range: replacementRange, with: text, origin: .typing)
        } else {
            engine.insertText(text)
        }
    }

    /// 标准键位绑定的一参版本，等价于没有替换范围的输入。
    public override func insertText(_ insertString: Any?) {
        insertText(
            insertString as Any,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    // MARK: 插入命令

    public override func insertNewline(_ sender: Any?) { insertText("\n") }
    public override func insertLineBreak(_ sender: Any?) { insertText("\u{2028}") }
    public override func insertParagraphSeparator(_ sender: Any?) { insertText("\u{2029}") }
    public override func insertTab(_ sender: Any?) { insertText("\t") }
    public override func insertBacktab(_ sender: Any?) { insertText("\u{0019}") }
    public override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertText("\n") }
    public override func insertTabIgnoringFieldEditor(_ sender: Any?) { insertText("\t") }
    public override func insertSingleQuoteIgnoringSubstitution(_ sender: Any?) { insertText("'") }
    public override func insertDoubleQuoteIgnoringSubstitution(_ sender: Any?) { insertText("\"") }

    // MARK: 删除命令

    public override func deleteBackward(_ sender: Any?) {
        guard !deleteCompositionText(.backward) else { return }
        engine.delete(.backward, .character)
    }

    public override func deleteForward(_ sender: Any?) {
        guard !deleteCompositionText(.forward) else { return }
        engine.delete(.forward, .character)
    }

    public override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
        guard !deleteCompositionText(.backward) else { return }
        engine.delete(.backward, .character)
    }

    public override func deleteWordBackward(_ sender: Any?) {
        guard !deleteCompositionText(.backward) else { return }
        engine.delete(.backward, .word)
    }

    public override func deleteWordForward(_ sender: Any?) {
        guard !deleteCompositionText(.forward) else { return }
        engine.delete(.forward, .word)
    }

    public override func deleteToBeginningOfLine(_ sender: Any?) {
        guard !deleteCompositionText(.toStart) else { return }
        engine.delete(.backward, .line)
    }

    public override func deleteToEndOfLine(_ sender: Any?) {
        guard !deleteCompositionText(.toEnd) else { return }
        engine.delete(.forward, .line)
    }

    public override func deleteToBeginningOfParagraph(_ sender: Any?) {
        guard !deleteCompositionText(.toStart) else { return }
        engine.delete(.backward, .line)
    }

    public override func deleteToEndOfParagraph(_ sender: Any?) {
        guard !deleteCompositionText(.toEnd) else { return }
        engine.delete(.forward, .line)
    }

    @objc public func delete(_ sender: Any?) {
        // 组合中 Delete 等价于前向删除 marked text，不删除文档内容。
        guard !deleteCompositionText(.forward) else { return }
        engine.deleteSelections()
    }

    // MARK: 移动命令

    private func move(_ movement: TextMovement, extendSelection: Bool) {
        // 组合期间方向键在 marked text 内移动，不碰 buffer 选区。
        if moveCompositionCaret(movement, extendSelection: extendSelection) {
            return
        }

        var anchors: [Int]?
        if extendSelection {
            if extendAnchors?.count != engine.selections.count {
                extendAnchors = engine.selections.map {
                    TextInputController.inferredAnchor(
                        for: $0,
                        movement: movement
                    )
                }
            }
            anchors = extendAnchors
        }
        let updated = TextInputController.moveSelections(
            engine.selections,
            movement: movement,
            extendSelection: extendSelection,
            engine: engine,
            anchors: anchors
        )
        commitSelections(
            updated,
            source: .keyboard,
            reveal: true,
            keepExtendAnchors: extendSelection
        )
    }

    public override func moveLeft(_ sender: Any?) { move(.characterBackward, extendSelection: false) }
    public override func moveRight(_ sender: Any?) { move(.characterForward, extendSelection: false) }
    public override func moveBackward(_ sender: Any?) { move(.characterBackward, extendSelection: false) }
    public override func moveForward(_ sender: Any?) { move(.characterForward, extendSelection: false) }
    public override func moveWordLeft(_ sender: Any?) { move(.wordBackward, extendSelection: false) }
    public override func moveWordRight(_ sender: Any?) { move(.wordForward, extendSelection: false) }
    public override func moveWordBackward(_ sender: Any?) { move(.wordBackward, extendSelection: false) }
    public override func moveWordForward(_ sender: Any?) { move(.wordForward, extendSelection: false) }
    public override func moveToBeginningOfLine(_ sender: Any?) { move(.lineStart, extendSelection: false) }
    public override func moveToEndOfLine(_ sender: Any?) { move(.lineEnd, extendSelection: false) }
    public override func moveToLeftEndOfLine(_ sender: Any?) { move(.lineStart, extendSelection: false) }
    public override func moveToRightEndOfLine(_ sender: Any?) { move(.lineEnd, extendSelection: false) }
    public override func moveToBeginningOfParagraph(_ sender: Any?) { move(.lineStart, extendSelection: false) }
    public override func moveToEndOfParagraph(_ sender: Any?) { move(.lineEnd, extendSelection: false) }
    public override func moveToBeginningOfDocument(_ sender: Any?) { move(.documentStart, extendSelection: false) }
    public override func moveToEndOfDocument(_ sender: Any?) { move(.documentEnd, extendSelection: false) }

    public override func moveLeftAndModifySelection(_ sender: Any?) { move(.characterBackward, extendSelection: true) }
    public override func moveRightAndModifySelection(_ sender: Any?) { move(.characterForward, extendSelection: true) }
    public override func moveBackwardAndModifySelection(_ sender: Any?) { move(.characterBackward, extendSelection: true) }
    public override func moveForwardAndModifySelection(_ sender: Any?) { move(.characterForward, extendSelection: true) }
    public override func moveWordLeftAndModifySelection(_ sender: Any?) { move(.wordBackward, extendSelection: true) }
    public override func moveWordRightAndModifySelection(_ sender: Any?) { move(.wordForward, extendSelection: true) }
    public override func moveWordBackwardAndModifySelection(_ sender: Any?) { move(.wordBackward, extendSelection: true) }
    public override func moveWordForwardAndModifySelection(_ sender: Any?) { move(.wordForward, extendSelection: true) }
    public override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { move(.lineStart, extendSelection: true) }
    public override func moveToEndOfLineAndModifySelection(_ sender: Any?) { move(.lineEnd, extendSelection: true) }
    public override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { move(.lineStart, extendSelection: true) }
    public override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { move(.lineEnd, extendSelection: true) }
    public override func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) { move(.lineStart, extendSelection: true) }
    public override func moveToEndOfParagraphAndModifySelection(_ sender: Any?) { move(.lineEnd, extendSelection: true) }
    public override func moveParagraphBackwardAndModifySelection(_ sender: Any?) { move(.lineStart, extendSelection: true) }
    public override func moveParagraphForwardAndModifySelection(_ sender: Any?) { move(.lineEnd, extendSelection: true) }
    public override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { move(.documentStart, extendSelection: true) }
    public override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { move(.documentEnd, extendSelection: true) }

    public override func moveUp(_ sender: Any?) {
        moveVertically(direction: -1, extendSelection: false)
    }

    public override func moveDown(_ sender: Any?) {
        moveVertically(direction: 1, extendSelection: false)
    }

    public override func moveUpAndModifySelection(_ sender: Any?) {
        moveVertically(direction: -1, extendSelection: true)
    }

    public override func moveDownAndModifySelection(_ sender: Any?) {
        moveVertically(direction: 1, extendSelection: true)
    }

    public override func pageUp(_ sender: Any?) {
        moveVertically(direction: -1, extendSelection: false, distance: pageStep)
    }

    public override func pageDown(_ sender: Any?) {
        moveVertically(direction: 1, extendSelection: false, distance: pageStep)
    }

    public override func pageUpAndModifySelection(_ sender: Any?) {
        moveVertically(direction: -1, extendSelection: true, distance: pageStep)
    }

    public override func pageDownAndModifySelection(_ sender: Any?) {
        moveVertically(direction: 1, extendSelection: true, distance: pageStep)
    }

    public override func centerSelectionInVisibleArea(_ sender: Any?) {
        guard let primary = engine.selections.last else { return }
        scrollRangeToVisible(offset: primary.insertionOffset)
    }

    // MARK: 滚动命令

    public override func scrollPageUp(_ sender: Any?) { scroll(by: -pageStep) }
    public override func scrollPageDown(_ sender: Any?) { scroll(by: pageStep) }
    public override func scrollLineUp(_ sender: Any?) { scroll(by: -layoutEngine.lineHeight) }
    public override func scrollLineDown(_ sender: Any?) { scroll(by: layoutEngine.lineHeight) }

    public override func scrollToBeginningOfDocument(_ sender: Any?) {
        scrollTo(y: 0)
    }

    public override func scrollToEndOfDocument(_ sender: Any?) {
        scrollTo(y: .greatestFiniteMagnitude)
    }

    // MARK: 选区命令

    public override func selectAll(_ sender: Any?) {
        // 全选会让组合失去锚点，先提交再选，避免 marked text 悬空。
        commitPendingInput()
        commitSelections(
            [TextSelection(range: NSRange(location: 0, length: engine.length))],
            source: .command
        )
    }

    public override func selectWord(_ sender: Any?) {
        let caret = engine.primarySelection.insertionOffset
        guard let range = engine.wordRange(at: caret, mode: .word),
              range.length > 0
        else {
            return
        }
        commitSelections([TextSelection(range: range)], source: .command)
    }

    public override func selectLine(_ sender: Any?) {
        let line = engine.lineNumber(at: engine.primarySelection.range.location)
        commitSelections(
            [TextSelection(range: engine.lineContentRange(at: line))],
            source: .command
        )
    }

    public override func selectParagraph(_ sender: Any?) {
        selectLine(sender)
    }

    public override func cancelOperation(_ sender: Any?) {
        // 组合中 Esc 取消输入法组合，buffer 与历史保持不变。
        if engine.isComposing {
            unmarkText()
            return
        }
        if onCancelOperation?() == true {
            return
        }
        _ = collapseSelectionsIfNeeded()
    }

    /// Esc：把多光标折叠为主选区；只有一个选区时返回 false 交给上层。
    @discardableResult
    public func collapseSelectionsIfNeeded() -> Bool {
        guard !engine.isComposing,
              engine.selections.count > 1,
              let primary = engine.selections.last
        else {
            return false
        }
        commitSelections([primary], source: .command, reveal: true)
        return true
    }

    // MARK: - 撤销 / 重做

    @objc public func undo(_ sender: Any?) {
        // 与 1.0.2 一致：组合中 ⌘Z 不执行撤销。
        guard !engine.isComposing else { return }
        resetCaretBlink()
        engine.undo()
    }

    @objc public func redo(_ sender: Any?) {
        guard !engine.isComposing else { return }
        resetCaretBlink()
        engine.redo()
    }

    // MARK: - 剪贴板

    @objc public func copy(_ sender: Any?) {
        let text = selectedText
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 与 1.0.2 一致：复制路径附带 RTF；编辑热路径不构造富文本。
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: theme.font]
        )
        let rtf = attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [:]
        )
        pasteboard.setData(rtf, forType: .rtf)
    }

    @objc public func cut(_ sender: Any?) {
        // 剪切前提交组合，保证复制/删除的是最终文本。
        commitPendingInput()
        guard !selectedText.isEmpty else { return }
        copy(sender)
        engine.deleteSelections(origin: .cut)
    }

    @objc public func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    /// 始终按纯文本粘贴，避免从浏览器等应用带入字体和颜色。
    @objc public func pasteAsPlainText(_ sender: Any?) {
        guard engine.isEditable,
              let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty
        else {
            return
        }
        // 粘贴前先提交组合，避免丢失 marked text 或把半成品拼进新文本。
        commitPendingInput()
        engine.replaceSelections(with: text, origin: .paste)
    }

    // MARK: - 菜单校验

    @objc public func validateUserInterfaceItem(
        _ item: NSValidatedUserInterfaceItem
    ) -> Bool {
        let action = item.action
        switch action {
        case #selector(LineaTextView.cut(_:)),
             #selector(LineaTextView.copy(_:)):
            return !selectedText.isEmpty
        case #selector(LineaTextView.paste(_:)),
             #selector(LineaTextView.pasteAsPlainText(_:)):
            return engine.isEditable
                && NSPasteboard.general.availableType(from: [.string]) != nil
        case #selector(LineaTextView.delete(_:)):
            return engine.isEditable
                && engine.selections.contains { !$0.isCaret }
        case #selector(LineaTextView.selectAll(_:)):
            return engine.length > 0
        case #selector(LineaTextView.undo(_:)):
            return engine.canUndo
        case #selector(LineaTextView.redo(_:)):
            return engine.canRedo
        default:
            return true
        }
    }

    // MARK: - 右键菜单

    public override func menu(for event: NSEvent) -> NSMenu? {
        // 与 1.0.2 一致：空白处右键先选中点击处单词再弹菜单。
        prepareContextMenuSelection(for: event)

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Cut",
            action: #selector(LineaTextView.cut(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Copy",
            action: #selector(LineaTextView.copy(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Paste",
            action: #selector(LineaTextView.paste(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Paste and Match Style",
            action: #selector(LineaTextView.pasteAsPlainText(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Select All",
            action: #selector(LineaTextView.selectAll(_:)),
            keyEquivalent: ""
        )
        return menu
    }

    /// 右键时若没有非空选区，先选中点击处的单词（C5）。
    private func prepareContextMenuSelection(for event: NSEvent) {
        // 已有非空选区时保留用户选择，不重新选词。
        guard !engine.selections.contains(where: { !$0.isCaret }) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = layoutEngine.index(at: point)
        if let range = engine.wordRange(at: index, mode: .word), range.length > 0 {
            commitSelections([TextSelection(range: range)], source: .mouse)
        } else {
            commitSelections([.caret(at: index)], source: .mouse)
        }
    }

    // MARK: - 鼠标选择与多光标

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // 点击别处先提交组合，等价于原生文本视图的失焦提交。
        commitPendingInput()
        let point = convert(event.locationInWindow, from: nil)
        let index = layoutEngine.index(at: point)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Option 也用于多光标，不能当作普通单击（否则会折叠选区并启动拖拽选择）。
        let isPlainClick = !flags.contains(.command)
            && !flags.contains(.shift)
            && !flags.contains(.control)
            && !flags.contains(.option)

        // 无修饰键单击按在非空选区内：先保留选区，等拖动超过阈值再启动移动拖拽；
        // 若只是单击，在 mouseUp 时再折叠为光标。双击/三击不参与，保留选词/选行。
        let primary = engine.primarySelection
        if isPlainClick,
           event.clickCount == 1,
           !primary.isCaret,
           index >= primary.range.location,
           index <= NSMaxRange(primary.range)
        {
            pendingDragSelection = primary.range
            pendingDragPoint = point
            pendingDragClickCount = event.clickCount
            return
        }

        handleClick(at: index, clickCount: event.clickCount, modifiers: flags)

        // 只有无修饰键的单击开启拖拽选择；⌘/⇧ 点击不进入拖拽。
        if event.clickCount == 1, isPlainClick {
            isDraggingSelection = true
            dragAnchorOffset = index
            dragPoint = point
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // 选区内按下后拖动超过阈值：开始拖拽文本（移动/复制由落点决定）。
        if let source = pendingDragSelection {
            let distance = hypot(
                point.x - pendingDragPoint.x,
                point.y - pendingDragPoint.y
            )
            guard distance > 3 else { return }
            pendingDragSelection = nil
            startDragSession(source: source, with: event)
            return
        }

        guard isDraggingSelection, let anchor = dragAnchorOffset else {
            super.mouseDragged(with: event)
            return
        }
        dragPoint = point
        extendDragSelection(anchor: anchor)
        updateDragAutoscroll()
    }

    public override func mouseUp(with event: NSEvent) {
        // 在选区内按下但没拖动：按普通点击折叠为光标。
        if pendingDragSelection != nil {
            pendingDragSelection = nil
            let point = convert(event.locationInWindow, from: nil)
            let index = layoutEngine.index(at: point)
            handleClick(at: index, clickCount: pendingDragClickCount, modifiers: [])
        }
        endDrag()
        super.mouseUp(with: event)
    }

    /// 程序化点击入口：测试与控制器可复用同一套点击语义，避免伪造 NSEvent。
    @discardableResult
    public func select(
        at point: CGPoint,
        clickCount: Int = 1,
        modifiers: NSEvent.ModifierFlags = []
    ) -> Bool {
        let index = layoutEngine.index(at: point)
        handleClick(
            at: index,
            clickCount: clickCount,
            modifiers: modifiers.intersection(.deviceIndependentFlagsMask)
        )
        return true
    }

    private func handleClick(
        at index: Int,
        clickCount: Int,
        modifiers: NSEvent.ModifierFlags
    ) {
        if modifiers.contains(.command) {
            toggleCursor(at: index)
            return
        }
        if modifiers.contains(.shift), modifiers.contains(.control) {
            appendCursor(at: index)
            return
        }
        // Option+点击：与 ⌘+点击一致添加/移除光标；配合 Shift 只追加不切换，
        // 对齐 Sublime / VS Code 在 macOS 上的鼠标多光标习惯。
        if modifiers.contains(.option) {
            if modifiers.contains(.shift) {
                appendCursor(at: index)
            } else {
                toggleCursor(at: index)
            }
            return
        }
        if clickCount >= 3 {
            let line = engine.lineNumber(at: index)
            commitSelections(
                [TextSelection(range: engine.lineContentRange(at: line))],
                source: .mouse
            )
            return
        }
        if clickCount == 2,
           let range = engine.wordRange(at: index, mode: .word),
           range.length > 0
        {
            commitSelections([TextSelection(range: range)], source: .mouse)
            return
        }
        if modifiers.contains(.shift) {
            let primary = engine.primarySelection
            let start = min(primary.range.location, index)
            let end = max(primary.insertionOffset, index)
            commitSelections(
                [TextSelection(range: NSRange(location: start, length: end - start))],
                source: .mouse
            )
            return
        }
        commitSelections([TextSelection.caret(at: index)], source: .mouse)
    }

    /// ⌘+点击：已有光标则移除，否则追加；至少保留一个光标。
    private func toggleCursor(at index: Int) {
        var current = engine.selections
        if let existing = current.firstIndex(where: {
            $0.isCaret && $0.range.location == index
        }) {
            guard current.count > 1 else { return }
            current.remove(at: existing)
        } else {
            guard current.count < SelectionModel.maximumSelections else {
                NSSound.beep()
                return
            }
            current.append(.caret(at: index))
        }
        commitSelections(current, source: .multiCursor)
    }

    /// ⇧⌃+点击：追加光标，不打开新选择。
    private func appendCursor(at index: Int) {
        var current = engine.selections
        guard !current.contains(where: { $0.isCaret && $0.range.location == index }) else {
            return
        }
        guard current.count < SelectionModel.maximumSelections else {
            NSSound.beep()
            return
        }
        current.append(.caret(at: index))
        commitSelections(current, source: .multiCursor)
    }

    private func extendDragSelection(anchor: Int) {
        let index = layoutEngine.index(at: dragPoint)
        let start = min(anchor, index)
        let end = max(anchor, index)
        commitSelections(
            [TextSelection(range: NSRange(location: start, length: end - start))],
            source: .mouse
        )
    }

    private func endDrag() {
        isDraggingSelection = false
        dragAnchorOffset = nil
        stopDragScrollTimer()
    }

    // MARK: 拖拽边缘自动滚动

    private func updateDragAutoscroll() {
        guard let scrollView = enclosingScrollView else { return }
        let visible = scrollView.documentVisibleRect
        let outside = dragPoint.y < visible.minY
            || dragPoint.y > visible.maxY
            || dragPoint.x < visible.minX
            || dragPoint.x > visible.maxX
        if outside {
            startDragScrollTimer()
        } else {
            stopDragScrollTimer()
        }
    }

    private func startDragScrollTimer() {
        guard dragScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.performDragScrollTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        dragScrollTimer = timer
    }

    private func stopDragScrollTimer() {
        dragScrollTimer?.invalidate()
        dragScrollTimer = nil
    }

    private func performDragScrollTick() {
        guard isDraggingSelection,
              let scrollView = enclosingScrollView,
              let anchor = dragAnchorOffset
        else {
            stopDragScrollTimer()
            return
        }

        let clipView = scrollView.contentView
        let visible = clipView.bounds
        let edge: CGFloat = 16
        var delta = CGPoint.zero
        if dragPoint.y < visible.minY { delta.y = -edge }
        else if dragPoint.y > visible.maxY { delta.y = edge }
        if dragPoint.x < visible.minX { delta.x = -edge }
        else if dragPoint.x > visible.maxX { delta.x = edge }
        guard delta != .zero else {
            stopDragScrollTimer()
            return
        }

        let maxX = max(0, frame.width - visible.width)
        let maxY = max(0, frame.height - visible.height)
        var origin = visible.origin
        origin.x = min(max(0, origin.x + delta.x), maxX)
        origin.y = min(max(0, origin.y + delta.y), maxY)
        guard origin != visible.origin else { return }

        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
        // 滚动后同一屏幕点对应新的文本偏移，重新扩展选区。
        extendDragSelection(anchor: anchor)
    }

    // MARK: - 拖放

    /// 标记「本视图发起」的拖拽，drop 时据此移动而不是复制。
    static let internalDragType = NSPasteboard.PasteboardType(
        "com.aisamxu.linea.internal-drag"
    )

    /// 从已有选区开始拖拽；文本通过 `.string` 提供给其他应用。
    private func startDragSession(source: NSRange, with event: NSEvent) {
        let text = engine.substring(in: source)
        guard !text.isEmpty else { return }
        endDrag()

        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(
            "\(source.location),\(source.length)",
            forType: Self.internalDragType
        )
        internalDragRange = source

        // 拖拽图像取选区首行矩形，宽度封顶避免长行生成超大位图。
        let rects = layoutEngine.rects(for: source)
        let first = rects.first ?? layoutEngine.caretRect(for: source.location)
        let frame = CGRect(
            x: first.minX,
            y: first.minY,
            width: min(max(first.width, 16), 320),
            height: max(first.height, layoutEngine.lineHeight)
        )
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(
            frame,
            contents: draggingImage(for: text, size: frame.size)
        )
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    /// 拖拽时跟随鼠标的文本快照，只绘制首行前 200 个字符。
    private func draggingImage(for text: String, size: CGSize) -> NSImage {
        let firstLine = String(text.prefix(while: { !$0.isNewline }))
        let clipped = String(firstLine.prefix(200))
        let font = NSFont(
            descriptor: CTFontCopyFontDescriptor(theme.font),
            size: CTFontGetSize(theme.font)
        ) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        return NSImage(size: size, flipped: true) { [theme] rect in
            theme.selection.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            let attributed = NSAttributedString(
                string: clipped,
                attributes: [
                    .font: font,
                    .foregroundColor: theme.text,
                ]
            )
            let textHeight = attributed.size().height
            attributed.draw(
                at: CGPoint(x: 4, y: max(0, (rect.height - textHeight) / 2))
            )
            return true
        }
    }

    // MARK: NSDraggingSource

    public func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // 编辑器内部拖拽移动文本；拖到其他应用时复制。
        context == .withinApplication ? [.move, .copy] : .copy
    }

    public func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // 移动由 destination 在 drop 时一次事务完成，这里只清理状态。
        internalDragRange = nil
        pendingDragSelection = nil
    }

    // MARK: NSDraggingDestination

    public override func draggingEntered(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        updateDropTarget(sender)
    }

    public override func draggingUpdated(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        updateDropTarget(sender)
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropTarget()
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        clearDropTarget()
    }

    public override func prepareForDragOperation(
        _ sender: NSDraggingInfo
    ) -> Bool {
        dropText(from: sender) != nil
    }

    public override func performDragOperation(
        _ sender: NSDraggingInfo
    ) -> Bool {
        defer { clearDropTarget() }
        guard let text = dropText(from: sender), !text.isEmpty else {
            return false
        }

        let point = convert(sender.draggingLocation, from: nil)
        let offset = layoutEngine.index(at: point)
        let source = internalDragRange
        internalDragRange = nil
        return insertDroppedText(text, at: offset, moving: source)
    }

    /// drop 的落点逻辑：`moving` 非 nil 表示本视图内部移动，否则按复制插入。
    @discardableResult
    func insertDroppedText(
        _ text: String,
        at offset: Int,
        moving source: NSRange?
    ) -> Bool {
        if let source {
            return moveSelection(source: source, to: offset, text: text)
        }

        // 外部纯文本：插入到落点，不替换现有选区。
        let caret = offset + text.utf16.count
        return engine.apply(
            edits: [
                TextEdit(
                    range: NSRange(location: offset, length: 0),
                    replacement: text
                )
            ],
            selectionAfter: [.caret(at: caret)],
            origin: .drag
        ) != nil
    }

    /// 只接受纯文本拖入：文件 URL 一律拒绝（与 1.0.2 一致，不支持拖入打开）。
    private func dropText(from info: NSDraggingInfo) -> String? {
        guard engine.isEditable, !engine.isComposing else { return nil }
        let pasteboard = info.draggingPasteboard
        guard !(pasteboard.types?.contains(.fileURL) ?? false) else { return nil }
        guard pasteboard.types?.contains(.string) == true else { return nil }
        return pasteboard.string(forType: .string)
    }

    /// 始终显示落点指示；返回拖动操作类型供系统绘制光标（移动/复制）。
    private func updateDropTarget(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        guard dropText(from: sender) != nil else {
            clearDropTarget()
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        dropInsertionOffset = layoutEngine.index(at: point)
        updateDropAutoscroll(at: point)
        needsDisplay = true
        return internalDragRange != nil ? .move : .copy
    }

    private func clearDropTarget() {
        guard dropInsertionOffset != nil || dropScrollTimer != nil else { return }
        dropInsertionOffset = nil
        stopDropScrollTimer()
        needsDisplay = true
    }

    /// 内部移动：源选区与落点合成一批 edits，删除源后光标落在插入文本末尾。
    private func moveSelection(
        source: NSRange,
        to offset: Int,
        text: String
    ) -> Bool {
        // 落点在源选区内或紧邻边界：原地放下，不产生编辑和历史。
        guard offset < source.location || offset > NSMaxRange(source) else {
            return true
        }
        // 源在落点之前时，删除后目标坐标左移源长度。
        var caret = offset
        if source.location < offset {
            caret -= source.length
        }
        caret += text.utf16.count

        // apply 要求 edits 按 location 升序；落点在源之前时需交换顺序。
        let edits = [
            TextEdit(range: source, replacement: ""),
            TextEdit(
                range: NSRange(location: offset, length: 0),
                replacement: text
            ),
        ].sorted { $0.range.location < $1.range.location }

        return engine.apply(
            edits: edits,
            selectionAfter: [.caret(at: caret)],
            origin: .drag
        ) != nil
    }

    // MARK: 拖入边缘自动滚动

    private func updateDropAutoscroll(at point: CGPoint) {
        dropPoint = point
        guard let scrollView = enclosingScrollView else { return }
        let visible = scrollView.documentVisibleRect
        let outside = point.y < visible.minY
            || point.y > visible.maxY
            || point.x < visible.minX
            || point.x > visible.maxX
        if outside {
            startDropScrollTimer()
        } else {
            stopDropScrollTimer()
        }
    }

    private func startDropScrollTimer() {
        guard dropScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.performDropScrollTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        dropScrollTimer = timer
    }

    private func stopDropScrollTimer() {
        dropScrollTimer?.invalidate()
        dropScrollTimer = nil
    }

    private func performDropScrollTick() {
        guard let scrollView = enclosingScrollView else {
            stopDropScrollTimer()
            return
        }
        let clipView = scrollView.contentView
        let visible = clipView.bounds
        let edge: CGFloat = 16
        var delta = CGPoint.zero
        if dropPoint.y < visible.minY { delta.y = -edge }
        else if dropPoint.y > visible.maxY { delta.y = edge }
        if dropPoint.x < visible.minX { delta.x = -edge }
        else if dropPoint.x > visible.maxX { delta.x = edge }
        guard delta != .zero else {
            stopDropScrollTimer()
            return
        }

        let maxX = max(0, frame.width - visible.width)
        let maxY = max(0, frame.height - visible.height)
        var origin = visible.origin
        origin.x = min(max(0, origin.x + delta.x), maxX)
        origin.y = min(max(0, origin.y + delta.y), maxY)
        guard origin != visible.origin else { return }

        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
        // 滚动后同一屏幕点对应新的文本偏移，刷新落点指示。
        dropInsertionOffset = layoutEngine.index(at: dropPoint)
        needsDisplay = true
    }

    // MARK: - 多光标命令

    @discardableResult
    public func selectNextOccurrence() -> MultiCursorCommandResult {
        let result = MultiCursorCommands.selectNextOccurrence(
            in: engine.text,
            selections: engine.selections
        )
        applyMultiCursorResult(result)
        return result
    }

    @discardableResult
    public func selectAllOccurrences() -> MultiCursorCommandResult {
        let result = MultiCursorCommands.selectAllOccurrences(
            in: engine.text,
            selections: engine.selections
        )
        applyMultiCursorResult(result)
        return result
    }

    @discardableResult
    public func addCursorsToSelectedLines() -> MultiCursorCommandResult {
        let result = MultiCursorCommands.addCursorsToSelectedLines(
            in: engine.text,
            selections: engine.selections,
            lineIndex: engine.lineIndex
        )
        applyMultiCursorResult(result)
        return result
    }

    private func applyMultiCursorResult(_ result: MultiCursorCommandResult) {
        guard case let .updated(updated) = result else { return }
        commitSelections(updated, source: .multiCursor, reveal: true)
    }

    // MARK: - NSTextInputClient

    public func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        guard engine.isEditable else { return }
        let text = (string as? NSAttributedString)?.string
            ?? (string as? String)
            ?? ""
        // AppKit 约定：空 marked text 表示取消组合。
        guard !text.isEmpty else {
            unmarkText()
            return
        }
        compositionAnchor = nil
        engine.setMarkedText(
            text,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        resetCaretBlink()
        needsDisplay = true
        inputContext?.invalidateCharacterCoordinates()
    }

    public func unmarkText() {
        compositionAnchor = nil
        engine.unmarkText()
        needsDisplay = true
        inputContext?.invalidateCharacterCoordinates()
    }

    /// 组合期间返回 marked text 内部选区在文档坐标系中的位置。
    public func selectedRange() -> NSRange {
        guard let composition = engine.composition else {
            return engine.primarySelection.range
        }
        // 组合选区落在 marked text 内，长度可以超出 buffer 末尾（marked text 尚未写入）。
        let location = max(0, compositionDocumentStart + composition.selectedRange.location)
        return NSRange(
            location: location,
            length: max(0, composition.selectedRange.length)
        )
    }

    public func markedRange() -> NSRange {
        guard let composition = engine.composition else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(
            location: compositionDocumentStart,
            length: composition.markedTextLength
        )
    }

    public func hasMarkedText() -> Bool {
        guard let composition = engine.composition else { return false }
        return !composition.markedText.isEmpty
    }

    /// 显式提交待输入内容。保存、切换标签、关窗、查找、拖放、AX 读取前调用。
    public func commitPendingInput() {
        guard engine.isComposing else { return }
        compositionAnchor = nil
        engine.commitPendingInput()
        resetCaretBlink()
        needsDisplay = true
        inputContext?.invalidateCharacterCoordinates()
    }

    /// 先提交组合再返回全文，供会话快照与保存使用。
    public func prepareForSnapshot() -> String {
        commitPendingInput()
        return engine.text
    }

    // MARK: - 组合内编辑

    private enum CompositionDeletion {
        case backward
        case forward
        case toStart
        case toEnd
    }

    /// 组合期间方向键在 marked text 内移动；返回 false 表示当前没有组合。
    private func moveCompositionCaret(
        _ movement: TextMovement,
        extendSelection: Bool
    ) -> Bool {
        guard let composition = engine.composition else { return false }
        let marked = composition.markedText as NSString
        let length = marked.length
        guard length > 0 else { return true }

        var selected = composition.selectedRange

        // 有选区且不扩展：只折叠到方向对应的一端，与文档选区行为一致。
        if !extendSelection, selected.length > 0 {
            switch movement {
            case .characterBackward, .wordBackward, .lineStart, .documentStart:
                break
            case .characterForward, .wordForward, .lineEnd, .documentEnd:
                selected.location += selected.length
            }
            selected.length = 0
            applyCompositionSelection(selected)
            return true
        }

        let anchor: Int
        let active: Int
        if extendSelection {
            // 首次 Shift 扩展时记录锚点，反向移动才能正确回缩。
            if compositionAnchor == nil {
                compositionAnchor = selected.location
            }
            anchor = compositionAnchor ?? selected.location
            if selected.length == 0 {
                active = selected.location
            } else if anchor <= selected.location {
                active = selected.location + selected.length
            } else {
                active = selected.location
            }
        } else {
            compositionAnchor = nil
            anchor = 0
            active = selected.location
        }

        let target: Int
        switch movement {
        case .characterBackward, .wordBackward:
            target = previousGraphemeBoundary(before: active, in: marked)
        case .characterForward, .wordForward:
            target = nextGraphemeBoundary(after: active, in: marked)
        case .lineStart, .documentStart:
            target = 0
        case .lineEnd, .documentEnd:
            target = length
        }

        if extendSelection {
            selected = NSRange(
                location: min(anchor, target),
                length: abs(anchor - target)
            )
        } else {
            selected = NSRange(location: target, length: 0)
        }
        applyCompositionSelection(selected)
        return true
    }

    /// 组合期间删除只修改 marked text，不写入 buffer；返回 false 表示当前没有组合。
    private func deleteCompositionText(_ kind: CompositionDeletion) -> Bool {
        guard let composition = engine.composition else { return false }
        let marked = composition.markedText as NSString
        let selected = composition.selectedRange
        let start = min(max(0, selected.location), marked.length)
        let end = min(start + selected.length, marked.length)

        let deleteStart: Int
        let deleteEnd: Int
        switch kind {
        case .backward:
            deleteStart = start < end
                ? start
                : previousGraphemeBoundary(before: start, in: marked)
            deleteEnd = end
        case .forward:
            deleteStart = start
            deleteEnd = start < end
                ? end
                : nextGraphemeBoundary(after: end, in: marked)
        case .toStart:
            deleteStart = 0
            deleteEnd = end
        case .toEnd:
            deleteStart = start
            deleteEnd = marked.length
        }

        // 已到组合边界：消耗按键但不动文档。
        guard deleteEnd > deleteStart else { return true }

        let updated = marked.replacingCharacters(
            in: NSRange(location: deleteStart, length: deleteEnd - deleteStart),
            with: ""
        )
        compositionAnchor = nil
        if updated.isEmpty {
            engine.unmarkText()
        } else {
            engine.setMarkedText(
                updated,
                selectedRange: NSRange(location: deleteStart, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        }
        resetCaretBlink()
        needsDisplay = true
        inputContext?.invalidateCharacterCoordinates()
        return true
    }

    private func applyCompositionSelection(_ selected: NSRange) {
        guard let composition = engine.composition else { return }
        engine.setMarkedText(
            composition.markedText,
            selectedRange: selected,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        resetCaretBlink()
        needsDisplay = true
        inputContext?.invalidateCharacterCoordinates()
    }

    private func previousGraphemeBoundary(
        before offset: Int,
        in text: NSString
    ) -> Int {
        guard offset > 0 else { return 0 }
        return text.rangeOfComposedCharacterSequence(at: offset - 1).location
    }

    private func nextGraphemeBoundary(
        after offset: Int,
        in text: NSString
    ) -> Int {
        guard offset < text.length else { return text.length }
        let range = text.rangeOfComposedCharacterSequence(at: offset)
        return range.location + range.length
    }

    /// 组合替换的文档起点：输入法显式范围优先，否则为组合开始时的主选区。
    private var compositionDocumentStart: Int {
        guard let composition = engine.composition else { return 0 }
        if composition.replacementRange.location != NSNotFound,
           composition.replacementRange.location >= 0
        {
            return min(composition.replacementRange.location, engine.length)
        }
        return min(
            max(0, composition.baseSelections.last?.range.location ?? 0),
            engine.length
        )
    }

    public func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              range.location <= engine.length,
              range.length <= engine.length - range.location
        else {
            return nil
        }
        actualRange?.pointee = range
        return NSAttributedString(
            string: engine.substring(in: range),
            attributes: [.font: theme.font]
        )
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// 候选窗定位：返回光标在屏幕坐标系中的矩形。
    public func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        let location: Int
        if range.location == NSNotFound {
            location = engine.primarySelection.range.location
        } else {
            location = min(max(0, range.location), engine.length)
        }
        actualRange?.pointee = NSRange(location: location, length: 0)

        // 组合期间候选窗跟随虚拟行中的 marked text 光标，而不是原文档光标。
        let caret: CGRect
        if let composition = engine.composition,
           let compositionLine = layoutEngine.compositionLine(for: composition)
        {
            caret = CGRect(
                x: compositionLine.caretX,
                y: layoutEngine.y(forLine: compositionLine.lineNumber),
                width: 2,
                height: layoutEngine.lineHeight
            )
        } else {
            caret = layoutEngine.caretRect(for: location)
        }
        guard let window else { return caret }
        let windowRect = convert(caret, to: nil)
        return window.convertToScreen(windowRect)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return 0 }
        let windowPoint = window.convertPoint(fromScreen: point)
        let viewPoint = convert(windowPoint, from: nil)
        return layoutEngine.index(at: viewPoint)
    }

    public func windowLevel() -> Int {
        window?.level.rawValue ?? NSWindow.Level.normal.rawValue
    }

    public func drawsVerticallyForCharacter(at charIndex: Int) -> Bool {
        false
    }

    // MARK: - NSTextFinderClient

    // Replace All 会把多个替换从后往前逐个回调；这里先收集，在
    // didReplaceCharacters 一次性升序应用，保证一个撤销条目且不逐个重排。
    private var pendingFinderEdits: [TextEdit] = []

    public var string: String {
        engine.text
    }

    public var isSelectable: Bool {
        true
    }

    public var allowsMultipleSelection: Bool {
        true
    }

    public var firstSelectedRange: NSRange {
        engine.primarySelection.range
    }

    public var selectedRanges: [NSValue] {
        get { engine.selections.map { NSValue(range: $0.range) } }
        set {
            let updated = newValue
                .map { TextSelection(range: clampedDocumentRange($0.rangeValue)) }
                .sorted { $0.range.location < $1.range.location }
            if !updated.isEmpty {
                selections = Array(updated.suffix(10_000))
            }
        }
    }

    public var visibleCharacterRanges: [NSValue] {
        let visibleRect = enclosingScrollView?.documentVisibleRect ?? bounds
        let lines = layoutEngine.lines(in: visibleRect)
        guard !lines.isEmpty else { return [] }
        let first = engine.lineRange(at: lines.lowerBound)
        let last = engine.lineRange(at: lines.upperBound - 1)
        return [NSValue(range: NSRange(
            location: first.location,
            length: last.location + last.length - first.location
        ))]
    }

    public func stringLength() -> Int {
        engine.length
    }

    public func substring(with range: NSRange) -> String {
        guard isValidDocumentRange(range) else { return "" }
        return engine.substring(in: range)
    }

    public func contentView(
        at index: Int,
        effectiveRange: NSRangePointer
    ) -> NSView? {
        effectiveRange.pointee = NSRange(
            location: 0,
            length: engine.length
        )
        return self
    }

    public func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard isValidDocumentRange(range) else { return nil }
        if range.length == 0 {
            return [NSValue(rect: layoutEngine.caretRect(for: range.location))]
        }
        return layoutEngine.rects(for: range).map { NSValue(rect: $0) }
    }

    public func shouldReplaceCharacters(
        inRanges ranges: [NSValue],
        with strings: [String]
    ) -> Bool {
        guard engine.isEditable, ranges.count == strings.count else {
            return false
        }
        return ranges.allSatisfy { isValidDocumentRange($0.rangeValue) }
    }

    /// 收集单个替换；NSTextFinder 的 Replace All 会连续调用多次。
    public func replaceCharacters(in range: NSRange, with string: String) {
        guard engine.isEditable, isValidDocumentRange(range) else { return }
        // 查找替换前提交组合，避免 marked text 与替换范围交叉。
        commitPendingInput()
        pendingFinderEdits.append(TextEdit(range: range, replacement: string))
    }

    /// 一次应用本轮全部替换；多个匹配只产生一个历史条目。
    public func didReplaceCharacters() {
        guard !pendingFinderEdits.isEmpty else { return }
        let edits = pendingFinderEdits.sorted {
            $0.range.location < $1.range.location
        }
        pendingFinderEdits.removeAll(keepingCapacity: true)
        engine.apply(edits: edits, origin: .replaceAll)
    }

    /// 查找栏出现/文本将变前由控制器调用，避免增量查找缓存过期。
    public func noteFindStringWillChange(_ textFinder: NSTextFinder) {
        textFinder.noteClientStringWillChange()
    }

    // MARK: - 无障碍

    // 视图是单一 AX 元素，不创建隐藏 NSTextView；文本、选区与行号全部从引擎读取。
    // 参数化属性（按范围取字符串/矩形、按行/索引取范围）由下面实现的
    // accessibility* 方法直接暴露，现代 NSAccessibility 协议会自动发现。

    public override func isAccessibilityElement() -> Bool {
        true
    }

    public override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    public override func accessibilityValue() -> Any? {
        engine.text
    }

    public override func accessibilitySelectedText() -> String? {
        let text = selectedText
        return text.isEmpty ? nil : text
    }

    public override func accessibilitySelectedTextRange() -> NSRange {
        engine.primarySelection.range
    }

    public override func accessibilitySelectedTextRanges() -> [NSValue]? {
        // AX 期望按文档顺序给出所有选区；主选区仍是最后一个。
        engine.selections
            .map(\.range)
            .sorted { $0.location < $1.location }
            .map { NSValue(range: $0) }
    }

    public override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        let clamped = clampedDocumentRange(range)
        selections = [TextSelection(range: clamped)]
    }

    public override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        guard let ranges, !ranges.isEmpty else { return }
        let updated = ranges
            .map { TextSelection(range: clampedDocumentRange($0.rangeValue)) }
            .sorted { $0.range.location < $1.range.location }
        selections = Array(updated.suffix(10_000))
    }

    public override func accessibilityNumberOfCharacters() -> Int {
        engine.length
    }

    /// AX 行号从 0 开始；引擎行号从 1 开始。
    public override func accessibilityInsertionPointLineNumber() -> Int {
        engine.lineNumber(at: engine.primarySelection.insertionOffset) - 1
    }

    public override func accessibilityVisibleCharacterRange() -> NSRange {
        let visibleRect = enclosingScrollView?.documentVisibleRect ?? bounds
        let lines = layoutEngine.lines(in: visibleRect)
        guard !lines.isEmpty else {
            let caret = min(engine.primarySelection.range.location, engine.length)
            return NSRange(location: caret, length: 0)
        }
        let first = engine.lineRange(at: lines.lowerBound)
        let last = engine.lineRange(at: lines.upperBound - 1)
        let end = min(engine.length, last.location + last.length)
        return NSRange(
            location: first.location,
            length: max(0, end - first.location)
        )
    }

    public override func accessibilityString(for range: NSRange) -> String? {
        guard isValidDocumentRange(range) else { return nil }
        return engine.substring(in: range)
    }

    /// AX 行号从 0 开始，返回该行的完整范围（含行终止符）。
    public override func accessibilityRange(forLine line: Int) -> NSRange {
        let clampedLine = min(max(line, 0), engine.lineCount - 1) + 1
        return engine.lineRange(at: clampedLine)
    }

    public override func accessibilityLine(for index: Int) -> Int {
        let clamped = min(max(0, index), engine.length)
        return engine.lineNumber(at: clamped) - 1
    }

    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let window else { return .zero }
        let clamped = clampedDocumentRange(range)
        let rect: CGRect
        if clamped.length == 0 {
            rect = layoutEngine.caretRect(for: clamped.location)
        } else {
            let rects = layoutEngine.rects(for: clamped)
            guard let first = rects.first else { return .zero }
            rect = rects.dropFirst().reduce(first) { $0.union($1) }
        }
        let windowRect = convert(rect, to: nil)
        return window.convertToScreen(windowRect)
    }

    /// 屏幕坐标转组合字符范围，供 VoiceOver 点击/缩放定位。
    public override func accessibilityRange(for position: NSPoint) -> NSRange {
        guard let window else {
            return NSRange(location: 0, length: 0)
        }
        let windowPoint = window.convertPoint(fromScreen: position)
        let viewPoint = convert(windowPoint, from: nil)
        let index = layoutEngine.index(at: viewPoint)
        return composedCharacterRange(at: index)
    }

    public override func accessibilityRange(for index: Int) -> NSRange {
        composedCharacterRange(at: index)
    }

    public override func accessibilityAttributedString(
        for range: NSRange
    ) -> NSAttributedString? {
        guard let text = accessibilityString(for: range) else { return nil }
        return NSAttributedString(
            string: text,
            attributes: [.font: theme.font]
        )
    }

    /// 文档范围夹取；AX 客户端传来的越界范围不崩溃。
    private func clampedDocumentRange(_ range: NSRange) -> NSRange {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else {
            return NSRange(location: 0, length: 0)
        }
        let location = min(range.location, engine.length)
        let length = min(range.length, engine.length - location)
        return NSRange(location: location, length: length)
    }

    private func isValidDocumentRange(_ range: NSRange) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= engine.length
            && range.length <= engine.length - range.location
    }

    /// 返回 index 所在组合字符（grapheme）的文档范围。
    private func composedCharacterRange(at index: Int) -> NSRange {
        guard engine.length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        let clamped = min(max(0, index), engine.length)
        let line = engine.lineNumber(at: clamped)
        let contentRange = engine.lineContentRange(at: line)
        let content = engine.substring(in: contentRange) as NSString
        guard content.length > 0 else {
            return NSRange(location: contentRange.location, length: 0)
        }
        let local = min(
            max(0, clamped - contentRange.location),
            content.length
        )
        // 文档末尾没有“下一个字符”，取最后一个 grapheme。
        let probe = local == content.length ? content.length - 1 : local
        let range = content.rangeOfComposedCharacterSequence(at: probe)
        return NSRange(
            location: contentRange.location + range.location,
            length: range.length
        )
    }

    // MARK: - TextSurface

    public func setSelections(_ selections: [TextSelection]) {
        self.selections = selections
    }

    // MARK: - 内部

    private func commitSelections(
        _ updated: [TextSelection],
        source: SelectionSource,
        reveal: Bool = false,
        keepVerticalAnchor: Bool = false,
        keepExtendAnchors: Bool = false
    ) {
        resetCaretBlink()
        if !keepExtendAnchors {
            extendAnchors = nil
        }
        guard engine.setSelections(updated, source: source) else { return }
        if !keepVerticalAnchor {
            verticalAnchorXs = nil
        }
        selectionDisplayDidChange(reveal: reveal)
    }

    private func selectionDisplayDidChange(reveal: Bool = false) {
        resetCaretBlink()
        needsDisplay = true
        if reveal, let primary = engine.selections.last {
            // 只滚主光标，避免多光标编辑时视图跟着最后一个选区乱跳。
            scrollRangeToVisible(offset: primary.insertionOffset)
        }
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    private func resetCaretBlink() {
        isCaretVisible = true
        guard window?.firstResponder === self else { return }
        scheduleCaretTimer()
    }

    private func scheduleCaretTimer() {
        caretBlinkTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.isCaretVisible.toggle()
        }
        RunLoop.main.add(timer, forMode: .common)
        caretBlinkTimer = timer
    }

    private func stopCaretBlinking() {
        caretBlinkTimer?.invalidate()
        caretBlinkTimer = nil
        isCaretVisible = false
    }

    private var pageStep: CGFloat {
        let visibleHeight = enclosingScrollView?.contentView.bounds.height
            ?? layoutEngine.lineHeight * 20
        return max(layoutEngine.lineHeight, visibleHeight - layoutEngine.lineHeight)
    }

    private func caretX(at offset: Int) -> CGFloat {
        layoutEngine.caretRect(for: offset).minX
    }

    private func moveVertically(
        direction: Int,
        extendSelection: Bool,
        distance: CGFloat? = nil
    ) {
        // 上下键通常被输入法用于候选翻页；未消费时也不在组合期间移动文档光标。
        guard !engine.isComposing else { return }
        let current = engine.selections
        let step = distance ?? layoutEngine.lineHeight

        // 一次连续垂直移动只捕获一次 x 锚点，短行不会让后续移动横向漂移。
        if verticalAnchorXs?.count != current.count {
            verticalAnchorXs = current.map { selection in
                let caret = direction < 0
                    ? selection.range.location
                    : selection.insertionOffset
                return caretX(at: caret)
            }
        }
        guard let anchors = verticalAnchorXs else { return }

        // Shift+上下同样使用固定锚点，跨方向反复移动不会累积误差。
        if extendSelection, extendAnchors?.count != current.count {
            extendAnchors = current.map { selection in
                if selection.isCaret {
                    return selection.range.location
                }
                return direction < 0
                    ? selection.insertionOffset
                    : selection.range.location
            }
        }

        var updated: [TextSelection] = []
        updated.reserveCapacity(current.count)
        for (index, selection) in current.enumerated() {
            if !extendSelection, !selection.isCaret {
                // 有选区时先折叠到方向对应的一端，不额外跨行。
                let caret = direction < 0
                    ? selection.range.location
                    : selection.insertionOffset
                updated.append(
                    TextSelection.caret(at: caret, affinity: selection.affinity)
                )
                continue
            }

            let active: Int
            let anchor: Int?
            if extendSelection {
                anchor = extendAnchors.flatMap {
                    index < $0.count ? $0[index] : nil
                }
                if let anchor, anchor <= selection.range.location {
                    active = selection.insertionOffset
                } else if let anchor, anchor >= selection.insertionOffset {
                    active = selection.range.location
                } else {
                    // 光标或锚点落在选区内部：以当前活动端为准。
                    active = direction < 0
                        ? selection.range.location
                        : selection.insertionOffset
                }
            } else {
                active = selection.range.location
                anchor = nil
            }

            let line = engine.lineNumber(at: active)
            let targetY = layoutEngine.y(forLine: line) + CGFloat(direction) * step
            let target = layoutEngine.verticalDestination(
                from: active,
                toY: targetY,
                x: anchors[index]
            )

            if let anchor {
                let start = min(anchor, target)
                let end = max(anchor, target)
                updated.append(
                    TextSelection(
                        range: NSRange(location: start, length: end - start),
                        affinity: selection.affinity
                    )
                )
            } else {
                updated.append(
                    TextSelection.caret(at: target, affinity: selection.affinity)
                )
            }
        }

        commitSelections(
            updated,
            source: .keyboard,
            reveal: true,
            keepVerticalAnchor: true,
            keepExtendAnchors: extendSelection
        )
    }

    private func scroll(by dy: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let maxY = max(0, frame.height - clipView.bounds.height)
        var origin = clipView.bounds.origin
        origin.y = min(max(0, origin.y + dy), maxY)
        guard origin != clipView.bounds.origin else { return }
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func scrollTo(y: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let maxY = max(0, frame.height - clipView.bounds.height)
        var origin = clipView.bounds.origin
        origin.y = min(max(0, y), maxY)
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

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
            self?.notifyAccessibilityIfVisibleLinesChanged()
        }
        syncViewportWidth()
        lastAccessibilityVisibleLine = currentAccessibilityVisibleLine
    }

    private var currentAccessibilityVisibleLine: Int {
        let visibleRect = enclosingScrollView?.documentVisibleRect ?? bounds
        return layoutEngine.lines(in: visibleRect).lowerBound
    }

    private func notifyAccessibilityIfVisibleLinesChanged() {
        let line = currentAccessibilityVisibleLine
        guard line != lastAccessibilityVisibleLine else { return }
        lastAccessibilityVisibleLine = line
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func syncViewportWidth() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        setViewportWidth(clipView.bounds.width)
    }
}
