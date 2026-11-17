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

    /// 把大段文本变化后的布局合并到下一轮事件循环，避免每个 range 都强制重排。
    private var viewportReflowScheduled = false
    private var viewportReflowGeneration = 0
    private var pendingViewportAnchor: NSRange?

    /// 退出写会话期间临时关闭编辑能力，防止快照之后的新修改丢失。
    private(set) var isEditingEnabled = true

    /// 一次多光标文本替换的期望选区；STTextView 替换后只保留一个选区，需要自行恢复。
    private var activeCursorAdjustment: MultiCursorSelectionAdjuster?
    private var cursorRestoreScheduled = false
    private var isFlushingCursorRestore = false
    /// 输入法组合期间仍逐 range 同步写回，避免异步恢复打断 marked text。
    private var usesSynchronousCursorRestore = false

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
        // 首次显示只补齐当前可见区域的 fragment，不强行滚动到光标；
        // 会话恢复的滚动位置由 pendingScrollOrigin 负责。
        scheduleViewportReflow(anchor: nil)
    }

    /// 窗口/标签真正显示后调用：应用延迟滚动并抢占焦点。
    func prepareForDisplay(focus: Bool = true) {
        applyPendingScrollIfNeeded()
        scheduleViewportReflow(anchor: nil)
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
        usesSynchronousCursorRestore = false
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

    /// TextKit 每次替换后会折叠多选区。替换前维护每个光标的期望位置，
    /// 整个多 range 替换结束后只写回一次，避免 k 个 range × k 个选区的 O(k²) 开销。
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
            // 中文等输入法组合期间继续走同步路径，保持现有 marked text 行为。
            usesSynchronousCursorRestore = textView.hasMarkedText()
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
              let contentManager = textView.textLayoutManager.textContentManager
        else {
            return
        }

        // 普通键入/删除只在整次替换结束后恢复一次；IME 组合期间保留逐 range 同步写回。
        if usesSynchronousCursorRestore, var adjuster = activeCursorAdjustment {
            adjuster.clamp(to: contentManager.length)
            activeCursorAdjustment = adjuster
            TextSelectionBridge.setRanges(adjuster.ranges, in: textView)
        }

        // 大段粘贴后 STTextView 只在滚动前布局；这里合并调度一次异步补布局，
        // 让滚动后新露出的尾部区域也生成 layout fragment。
        let editRange = NSRange(affectedCharRange, in: contentManager)
        let replacementLength = (replacementString as NSString).length
        let containsNewline = replacementString.contains("\n") || replacementString.contains("\r")
        if containsNewline || replacementLength >= 256 || editRange.length >= 256 {
            scheduleViewportReflow(anchor: activeCursorAdjustment?.ranges.last)
        }
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

            if self.usesSynchronousCursorRestore {
                self.usesSynchronousCursorRestore = false
                self.scheduleViewportReflow(anchor: adjuster.ranges.last)
                return
            }
            self.restoreCursor(adjuster)
        }
    }

    /// 在一次按键/粘贴的整个替换结束后写回全部多光标选区。
    private func restoreCursor(_ adjuster: MultiCursorSelectionAdjuster) {
        guard !isApplyingText,
              let contentManager = textView.textLayoutManager.textContentManager
        else {
            return
        }

        var adjuster = adjuster
        adjuster.clamp(to: contentManager.length)
        TextSelectionBridge.setRanges(adjuster.ranges, in: textView)
        scheduleViewportReflow(anchor: adjuster.ranges.last)
    }

    /// 命令或会话快照读取选区前，先把尚未执行的异步恢复同步完成。
    private func flushPendingCursorRestore() {
        guard !isFlushingCursorRestore,
              !isApplyingText,
              let adjuster = activeCursorAdjustment
        else {
            return
        }

        isFlushingCursorRestore = true
        defer { isFlushingCursorRestore = false }

        activeCursorAdjustment = nil
        usesSynchronousCursorRestore = false
        restoreCursor(adjuster)
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
        usesSynchronousCursorRestore = false
        textView.allowsUndo = false
        // 查找栏里的 Replace 会绕过普通插入路径，退出期间直接收起。
        textView.textFinder.performAction(.hideFindInterface)
        textView.isEditable = false
        textView.isSelectable = false
    }

    func replaceTextFromDisk(_ newText: String) {
        // 异步恢复尚未执行时先同步完成，避免重载后丢失多光标。
        flushPendingCursorRestore()
        let origin = currentScrollOrigin
        let selections = TextSelectionBridge.ranges(in: textView)

        activeCursorAdjustment = nil
        usesSynchronousCursorRestore = false
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
        flushPendingCursorRestore()
        return TextSelectionBridge.ranges(in: textView)
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

        // 先让 STTextView 自己跑完一轮 layout，再读取文档高度。
        textView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let visibleSize = clipView.bounds.size
        let usageSize = textView.textLayoutManager.usageBoundsForTextContainer
        let contentSize = CGSize(
            width: max(textView.frame.width, usageSize.width),
            height: max(textView.frame.height, usageSize.height)
        )

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

        let maxX = max(0, contentSize.width - visibleSize.width)
        let maxY = max(0, contentSize.height - visibleSize.height)
        let origin = CGPoint(
            x: min(max(0, target.x), maxX),
            y: min(max(0, target.y), maxY)
        )
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)

        // AppKit 可能因为文档尚未完全长高而把 origin clamp 回较小值。
        let actualOrigin = clipView.bounds.origin
        let reachedTarget = abs(actualOrigin.x - origin.x) <= 1
            && abs(actualOrigin.y - origin.y) <= 1
        if !reachedTarget, attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.applyPendingScrollIfNeeded(attempt: attempt + 1)
            }
            return
        }

        pendingScrollOrigin = nil
        scheduleViewportReflow(anchor: nil)
    }

    /// 把滚动、选区恢复后可能缺失的 viewport 布局合并到一次异步补排。
    private func scheduleViewportReflow(anchor: NSRange?) {
        guard view.window != nil else { return }

        viewportReflowGeneration += 1
        // nil 表示只补排当前可见区域；显式覆盖旧 anchor，避免恢复滚动时被过期光标拉走。
        pendingViewportAnchor = anchor
        guard !viewportReflowScheduled else { return }

        viewportReflowScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.performViewportReflow()
        }
    }

    private func performViewportReflow() {
        viewportReflowScheduled = false
        guard view.window != nil else {
            pendingViewportAnchor = nil
            return
        }

        let anchor = pendingViewportAnchor
        pendingViewportAnchor = nil
        let generation = viewportReflowGeneration

        // 第一轮执行 STTextView 挂起的 postLayoutAction（滚动到光标）；
        // 第二轮才按滚动后的可见区域生成新露出的 fragment views。
        textView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()

        if let anchor, !isRangeVisible(anchor) {
            textView.scrollRangeToVisible(anchor)
        }

        textView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()

        // 补排期间若有新编辑，允许再合并一轮，直到最后一次编辑后的状态稳定。
        if generation != viewportReflowGeneration, !viewportReflowScheduled {
            scheduleViewportReflow(anchor: pendingViewportAnchor)
        }
    }

    private func isRangeVisible(_ range: NSRange) -> Bool {
        guard let contentManager = textView.textLayoutManager.textContentManager else {
            return false
        }

        // 零宽光标在文档末尾时，取前一个字符的片段来判断所在行是否可见。
        let probeRange = range.length == 0 && range.location > 0
            ? NSRange(location: range.location - 1, length: 1)
            : range
        guard let textRange = NSTextRange(probeRange, in: contentManager),
              let frame = textView.textLayoutManager.textSegmentFrame(
                  in: textRange,
                  type: .standard
              )
        else {
            return false
        }
        return scrollView.documentVisibleRect.intersects(frame)
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
        scheduleViewportReflow(anchor: ranges.last)
        view.window?.makeFirstResponder(textView)
        return result
    }

    @discardableResult
    func collapseSelectionsIfNeeded() -> Bool {
        guard !textView.hasMarkedText() else { return false }
        let ranges = currentSelections()
        guard ranges.count > 1, let lastRange = ranges.last else { return false }

        TextSelectionBridge.setRanges([lastRange], in: textView)
        scheduleViewportReflow(anchor: lastRange)
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
        scheduleViewportReflow(anchor: NSRange(location: offset, length: 0))
        window.makeFirstResponder(textView)
        return true
    }
}
