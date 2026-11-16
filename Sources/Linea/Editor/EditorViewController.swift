import AppKit
import STTextView
import STTextKitPlus

/// 单个标签页的编辑器容器。
///
/// 每个标签拥有独立的 STTextView 和独立撤销栈；切换标签只切换视图，
/// 因此光标、选区和滚动位置天然保留。
final class EditorViewController: NSViewController, STTextViewDelegate {
    let document: Document
    let scrollView: NSScrollView
    let textView: STTextView

    private let customUndoManager: UndoManager
    private var textChangeObserver: NSObjectProtocol?
    private var inputMonitor: EditorInputMonitor?

    /// 程序化加载/重载文本期间为 true，用于抑制脏状态通知。
    private var isApplyingText = false
    private var pendingScrollOrigin: CGPoint?

    /// 退出写会话期间临时关闭编辑能力，防止快照之后的新修改丢失。
    private(set) var isEditingEnabled = true

    /// 一次多光标文本替换的期望选区；STTextView 替换后只保留一个选区，需要自行恢复。
    private var activeCursorAdjustment: MultiCursorSelectionAdjuster?
    private var cursorRestoreScheduled = false

    /// 只在视图已加载时暴露给事件监视器，避免提前触发 loadView。
    var textViewIfViewLoaded: STTextView? {
        isViewLoaded ? textView : nil
    }

    var currentText: String {
        textView.text ?? ""
    }

    init(
        document: Document,
        text: String,
        selections: [NSRange],
        scrollOrigin: CGPoint? = nil
    ) {
        self.document = document
        self.customUndoManager = UndoManager()
        self.pendingScrollOrigin = scrollOrigin

        let scrollView = STTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? STTextView else {
            fatalError("STTextView.scrollableTextView() did not return an STTextView document view")
        }
        self.scrollView = scrollView
        self.textView = textView

        super.init(nibName: nil, bundle: nil)

        // 按事件分组的撤销管理器：一次按键/粘贴产生的多个选区替换合并为一步撤销。
        // STTextView 默认的 CoalescingUndoManager 按 range 合并，多光标会被拆成多步。
        customUndoManager.groupsByEvent = true
        customUndoManager.levelsOfUndo = 0

        textView.textDelegate = self
        configureTextView()
        installInitialText(text, selections: selections)
        observeTextChanges()
        inputMonitor = EditorInputMonitor(editor: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let textChangeObserver {
            NotificationCenter.default.removeObserver(textChangeObserver)
        }
    }

    // MARK: - 视图生命周期

    override func loadView() {
        let container = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyPendingScrollIfNeeded()
    }

    /// 窗口/标签真正显示后调用：应用延迟滚动并抢占焦点。
    func prepareForDisplay(focus: Bool = true) {
        applyPendingScrollIfNeeded()
        if focus {
            focusEditor()
        }
    }

    func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.view.window else { return }
            if window.firstResponder !== self.textView {
                window.makeFirstResponder(self.textView)
            }
        }
    }

    // MARK: - 配置

    private func configureTextView() {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        // 这些属性会重写全文属性，必须在设置 text 之前配置。
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .textColor

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.2
        paragraphStyle.defaultTabInterval = 28
        paragraphStyle.tabStops = []
        textView.defaultParagraphStyle = paragraphStyle

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer.lineFragmentPadding = 0

        textView.showsLineNumbers = true
        if let gutterView = textView.gutterView {
            gutterView.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            gutterView.textColor = .secondaryLabelColor
            gutterView.drawSeparator = true
        }

        // 纯文本编辑器不需要系统自动更正，也避免它们改写多光标输入。
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.usesFontPanel = false
        textView.isIncrementalSearchingEnabled = true
        textView.textFinder.incrementalSearchingShouldDimContentView = true
    }

    private func installInitialText(_ text: String, selections: [NSRange]) {
        activeCursorAdjustment = nil
        isApplyingText = true
        textView.text = text
        TextSelectionBridge.setRanges(selections, in: textView)
        customUndoManager.removeAllActions()
        isApplyingText = false
    }

    private func observeTextChanges() {
        textChangeObserver = NotificationCenter.default.addObserver(
            forName: STTextView.textDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isApplyingText else { return }
            if !self.document.isDirty {
                self.document.isDirty = true
            }
        }
    }

    // MARK: - STTextViewDelegate

    func undoManager(for textView: STTextView) -> UndoManager? {
        customUndoManager
    }

    /// 所有编辑入口（键入、粘贴、删除、右键菜单等）都会先经过这里；
    /// 退出写会话期间返回 false，避免产生快照之后的新修改。
    func textView(
        _ textView: STTextView,
        shouldChangeTextIn affectedCharRange: NSTextRange,
        replacementString: String?
    ) -> Bool {
        isEditingEnabled
    }

    /// 纯文本编辑器：把右键菜单里的 Paste 从富文本粘贴改为纯文本粘贴，
    /// 避免从浏览器等应用带入字体、字号和颜色。
    func textView(
        _ textView: STTextView,
        menu: NSMenu,
        for event: NSEvent,
        at location: any NSTextLocation
    ) -> NSMenu? {
        if let pasteItem = menu.items.first(where: {
            $0.action == #selector(NSText.paste(_:))
        }) {
            pasteItem.action = #selector(STTextView.pasteAsPlainText(_:))
        }
        return menu
    }

    /// TextKit 每次替换后会折叠多选区。这里在替换前维护每个光标的期望位置，
    /// 并在 `didChangeTextIn` 中立即写回，保证连续键入仍作用在所有光标上。
    func textView(
        _ textView: STTextView,
        willChangeTextIn affectedCharRange: NSTextRange,
        replacementString: String
    ) {
        guard !isApplyingText,
              let contentManager = textView.textLayoutManager.textContentManager
        else {
            return
        }

        if activeCursorAdjustment == nil {
            let selections = TextSelectionBridge.ranges(in: textView)
            guard selections.count > 1 else { return }
            activeCursorAdjustment = MultiCursorSelectionAdjuster(ranges: selections)
            scheduleCursorRestore()
        }

        let editRange = NSRange(affectedCharRange, in: contentManager)
        activeCursorAdjustment?.apply(
            editRange: editRange,
            replacementLength: (replacementString as NSString).length
        )
    }

    func textView(
        _ textView: STTextView,
        didChangeTextIn affectedCharRange: NSTextRange,
        replacementString: String
    ) {
        guard !isApplyingText,
              let contentManager = textView.textLayoutManager.textContentManager,
              var adjuster = activeCursorAdjustment
        else {
            return
        }

        adjuster.clamp(to: contentManager.length)
        activeCursorAdjustment = adjuster
        TextSelectionBridge.setRanges(adjuster.ranges, in: textView)
    }

    private func scheduleCursorRestore() {
        guard !cursorRestoreScheduled else { return }
        cursorRestoreScheduled = true

        // 撤销/重做会在 replaceCharacters 之后再把选区改成单个，必须等整个动作结束后补写。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cursorRestoreScheduled = false
            guard let adjuster = self.activeCursorAdjustment else { return }
            self.activeCursorAdjustment = nil
            guard !self.isApplyingText else { return }
            TextSelectionBridge.setRanges(adjuster.ranges, in: self.textView)
        }
    }

    // MARK: - 文本与快照

    /// 退出写会话期间冻结编辑器和撤销，等后台写完清单后再真正结束应用。
    /// 若写入失败且用户取消退出，会再次调用并恢复编辑能力。
    func setEditingEnabled(_ enabled: Bool) {
        isEditingEnabled = enabled

        if enabled {
            textView.isSelectable = true
            textView.isEditable = true
            textView.allowsUndo = true
            return
        }

        activeCursorAdjustment = nil
        textView.allowsUndo = false
        // 查找栏里的 Replace 会绕过普通插入路径，退出期间直接收起。
        textView.textFinder.performAction(.hideFindInterface)
        textView.isEditable = false
        textView.isSelectable = false
    }

    func replaceTextFromDisk(_ newText: String) {
        let origin = currentScrollOrigin
        let selections = TextSelectionBridge.ranges(in: textView)

        activeCursorAdjustment = nil
        isApplyingText = true
        textView.text = newText
        TextSelectionBridge.setRanges(selections, in: textView)
        customUndoManager.removeAllActions()
        isApplyingText = false

        pendingScrollOrigin = origin
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingScrollIfNeeded()
        }
    }

    func currentSelections() -> [NSRange] {
        TextSelectionBridge.ranges(in: textView)
    }

    var currentScrollOrigin: CGPoint {
        if let pendingScrollOrigin {
            return CGPoint(x: max(0, pendingScrollOrigin.x), y: max(0, pendingScrollOrigin.y))
        }
        let origin = scrollView.contentView.bounds.origin
        return CGPoint(x: max(0, origin.x), y: max(0, origin.y))
    }

    private func applyPendingScrollIfNeeded(attempt: Int = 0) {
        guard let target = pendingScrollOrigin, view.window != nil else { return }

        scrollView.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        let visibleSize = clipView.bounds.size
        let contentSize = textView.frame.size

        // 大文档首次布局可能尚未完成，此时立即 scroll 会被 AppKit clamp 到 0；
        // 最多等待约 0.6 秒再放弃，避免无限重试。
        let needsMoreLayout = (target.x > 0 && contentSize.width <= visibleSize.width)
            || (target.y > 0 && contentSize.height <= visibleSize.height)
        if needsMoreLayout, attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.applyPendingScrollIfNeeded(attempt: attempt + 1)
            }
            return
        }

        pendingScrollOrigin = nil
        let maxX = max(0, contentSize.width - visibleSize.width)
        let maxY = max(0, contentSize.height - visibleSize.height)
        let origin = CGPoint(
            x: min(max(0, target.x), maxX),
            y: min(max(0, target.y), maxY)
        )
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    // MARK: - 查找替换

    func performFindAction(_ action: NSTextFinder.Action) {
        textView.textFinder.performAction(action)
    }

    // MARK: - 多光标

    @discardableResult
    func selectNextOccurrence() -> MultiCursorResult {
        let result = MultiCursorController.selectNextOccurrence(
            in: currentText,
            selections: currentSelections()
        )
        return applyMultiCursorResult(result)
    }

    @discardableResult
    func selectAllOccurrences() -> MultiCursorResult {
        let result = MultiCursorController.selectAllOccurrences(
            in: currentText,
            selections: currentSelections()
        )
        return applyMultiCursorResult(result)
    }

    @discardableResult
    func addCursorsToSelectedLines() -> MultiCursorResult {
        let result = MultiCursorController.addCursorsToSelectedLines(
            in: currentText,
            selections: currentSelections()
        )
        return applyMultiCursorResult(result)
    }

    private func applyMultiCursorResult(_ result: MultiCursorResult) -> MultiCursorResult {
        guard case let .updated(ranges) = result else { return result }

        TextSelectionBridge.setRanges(ranges, in: textView)
        if let lastRange = ranges.last {
            textView.scrollRangeToVisible(lastRange)
        }
        view.window?.makeFirstResponder(textView)
        return result
    }

    @discardableResult
    func collapseSelectionsIfNeeded() -> Bool {
        guard !textView.hasMarkedText() else { return false }
        let ranges = currentSelections()
        guard ranges.count > 1, let lastRange = ranges.last else { return false }

        TextSelectionBridge.setRanges([lastRange], in: textView)
        textView.scrollRangeToVisible(lastRange)
        return true
    }

    /// 由 ⌘+点击事件监视器调用，坐标使用窗口坐标系。
    @discardableResult
    func addCursor(atWindowPoint point: NSPoint) -> Bool {
        guard let window = textView.window, let contentView = window.contentView else {
            return false
        }

        // 只有点击真正落在 STTextView 内部时才处理，gutter、滚动条、查找栏都放行。
        let contentPoint = contentView.convert(point, from: nil)
        guard let hitView = contentView.hitTest(contentPoint) else { return false }
        var ancestor: NSView? = hitView
        var isInsideTextView = false
        while let view = ancestor {
            if view === textView {
                isInsideTextView = true
                break
            }
            ancestor = view.superview
        }
        guard isInsideTextView else { return false }

        // STTextView 的 contentView 作为子视图整体右移了 gutter 宽度；
        // 与其原生 mouseDown 保持一致，先转到 textView 坐标再减去 gutter 宽度。
        let pointInTextView = textView.convert(point, from: nil)
        let gutterWidth = textView.gutterView?.frame.width ?? 0
        let layoutPoint = CGPoint(x: pointInTextView.x - gutterWidth, y: pointInTextView.y)
        guard layoutPoint.x >= 0 else { return false }

        let layoutManager = textView.textLayoutManager
        guard let contentManager = layoutManager.textContentManager,
              let location = layoutManager.caretLocation(
                  interactingAt: layoutPoint,
                  inContainerAt: layoutManager.documentRange.location
              )
        else {
            return false
        }

        let offset = contentManager.offset(from: contentManager.documentRange.location, to: location)
        guard offset != NSNotFound else { return false }

        var ranges = currentSelections()
        if let existingIndex = ranges.firstIndex(where: {
            $0.location == offset && $0.length == 0
        }) {
            // 再次点击已有光标等价于移除它，但至少保留一个光标。
            guard ranges.count > 1 else { return true }
            ranges.remove(at: existingIndex)
        } else {
            guard ranges.count < MultiCursorController.maximumSelections else {
                NSSound.beep()
                return true
            }
            ranges.append(NSRange(location: offset, length: 0))
        }

        TextSelectionBridge.setRanges(ranges, in: textView)
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        window.makeFirstResponder(textView)
        return true
    }
}
