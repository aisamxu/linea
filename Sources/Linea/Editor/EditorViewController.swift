import AppKit
import LineaCore
import LineaTextUI

/// 单个标签页的编辑器容器。
///
/// 每个标签拥有独立的 `LineaTextView` 与 `EditorEngine`（含撤销栈）；
/// 切换标签只切换视图，因此光标、选区和滚动位置天然保留。
/// 文本、选取、版本的唯一事实源是引擎，控制器只负责生命周期、
/// 查找栏、滚动恢复与脏状态同步。
final class EditorViewController: NSViewController {
    let document: Document
    let scrollView: NSScrollView
    let textView: LineaTextView
    let engine: EditorEngine

    private let textFinder = NSTextFinder()
    private var lineNumberRuler: LineNumberRulerView?
    private var pendingScrollOrigin: CGPoint?

    private var finderMatchesObservation: NSKeyValueObservation?
    private var findBarVisibleObservation: NSKeyValueObservation?
    /// 查找栏搜索框的文本变化通知；只保留一个 observer。
    private var findFieldObserver: NSObjectProtocol?
    private weak var observedFindField: NSSearchField?
    /// 查找器发布的全量增量匹配；非空时是绘制高亮的权威来源。
    private var finderMatchRanges: [NSRange] = []
    /// 搜索框文本变化后本地立即扫描出的匹配，用于等待查找器全量结果的空窗期。
    private var quickMatchRanges: [NSRange] = []
    /// 当前查找字符串，编辑文本后据此刷新本地高亮。
    private var lastFindString = ""

    /// 退出写会话期间临时关闭编辑能力，防止快照之后的新修改丢失。
    private(set) var isEditingEnabled = true

    /// 保存、会话快照、切换标签前都通过它取文本；会先提交输入法组合。
    var currentText: String {
        textView.prepareForSnapshot()
    }

    init(
        document: Document,
        text: String,
        selections: [NSRange],
        scrollOrigin: CGPoint? = nil
    ) {
        self.document = document
        let engine = EditorEngine(
            text: text,
            selections: selections.map { TextSelection(range: $0) }
        )
        self.engine = engine
        self.textView = LineaTextView(engine: engine)
        self.scrollView = NSScrollView()
        self.pendingScrollOrigin = scrollOrigin

        super.init(nibName: nil, bundle: nil)

        configureScrollView()
        configureFinding()
        observeChanges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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

    override func viewDidLayout() {
        super.viewDidLayout()
        syncViewport()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        syncViewport()
        applyPendingScrollIfNeeded()
    }

    /// 窗口/标签真正显示后调用：同步视口、应用延迟滚动并抢占焦点。
    func prepareForDisplay(focus: Bool = true) {
        syncViewport()
        applyPendingScrollIfNeeded()
        if focus {
            focusEditor()
        }
    }

    func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            self?.focusEditorNow()
        }
    }

    /// 立即把第一响应者交给文本视图。
    ///
    /// 窗口首次显示时必须紧跟 `makeKeyAndOrderFront` 同步调用：SwiftUI 的
    /// `NSHostingView`（标签栏）会在窗口显示时把内部的 `KeyViewProxy` 设为
    /// 第一响应者，异步聚焦会被它覆盖，表现为没有光标、键盘输入全部丢失。
    func focusEditorNow() {
        guard let window = view.window else { return }
        if window.firstResponder !== textView {
            window.makeFirstResponder(textView)
        }
    }

    // MARK: - 配置

    private func configureScrollView() {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView

        lineNumberRuler = LineNumberRulerView(
            scrollView: scrollView,
            textView: textView
        )
    }

    private func configureFinding() {
        textFinder.client = textView
        textFinder.findBarContainer = scrollView
        textFinder.isIncrementalSearchingEnabled = true
        // 系统“变暗内容视图”只对原生内容视图生效；自绘视图改为读取
        // incrementalMatchRanges 自己绘制高亮（系统文档推荐路径）。
        textFinder.incrementalSearchingShouldDimContentView = false

        // 查找器在后台搜索完成时更新匹配范围（主队列），据此驱动自绘高亮。
        finderMatchesObservation = textFinder.observe(
            \.incrementalMatchRanges,
            options: [.new]
        ) { [weak self] finder, _ in
            self?.updateFinderMatchRanges(
                finder.incrementalMatchRanges.map(\.rangeValue)
            )
        }

        // Escape 等路径由查找器自行收起查找栏，KVO 保证高亮同步清除。
        findBarVisibleObservation = scrollView.observe(
            \.isFindBarVisible,
            options: [.new]
        ) { [weak self] scrollView, _ in
            guard let self else { return }
            if scrollView.isFindBarVisible {
                self.observeFindFieldIfNeeded()
                self.applyFindHighlights()
            } else {
                self.clearFindHighlights()
            }
        }

        // NSTextFinder 要求字符串修改前失效缓存，否则增量查找会继续用旧全文。
        engine.onWillChange = { [weak self] in
            self?.textFinder.noteClientStringWillChange()
        }
    }

    /// 窗口尺寸变化后同步视口宽度；布局引擎按它决定横向滚动范围。
    private func syncViewport() {
        let width = scrollView.contentSize.width
        guard width > 0 else { return }
        textView.setViewportWidth(width)
        textView.updateDocumentFrame()
    }

    private func observeChanges() {
        // 引擎的脏标记是单调的：编辑/undo/redo 置脏，只有保存或重载清除。
        textView.onChange = { [weak self] _ in
            guard let self else { return }
            if self.engine.isDirty, !self.document.isDirty {
                self.document.isDirty = true
            }
            // 文本变化后查找器的增量结果会滞后，先用本地扫描刷新高亮。
            self.refreshQuickMatchesAfterTextChange()
        }
    }

    // MARK: - 文本与快照

    /// 退出写会话期间冻结编辑器和查找栏，等后台写完清单后再真正结束应用。
    /// 若写入失败且用户取消退出，会再次调用并恢复编辑能力。
    func setEditingEnabled(_ enabled: Bool) {
        isEditingEnabled = enabled

        if enabled {
            textView.isEditable = true
            return
        }

        // 冻结前先提交组合，避免快照之后才落盘或丢失 marked text。
        textView.commitPendingInput()
        // 冻结/解冻是历史边界：解冻后的第一次键入不能与冻结前合并成一步。
        engine.breakUndoCoalescing()
        // 查找栏里的 Replace 会绕过普通插入路径，退出期间直接收起。
        textFinder.performAction(.hideFindInterface)
        textView.isEditable = false
    }

    /// 保存成功或退出冻结前提交尚未落盘的输入法组合。
    func commitPendingInput() {
        textView.commitPendingInput()
    }

    /// 保存成功后清除引擎脏标记，保持 Document 与引擎一致。
    func markSaved() {
        engine.markSaved()
        document.isDirty = false
    }

    func replaceTextFromDisk(_ newText: String) {
        let origin = currentScrollOrigin
        let selections = engine.selections

        // 重载清空历史并保持 clean；旧选区按新文本长度 clamp。
        engine.load(text: newText, selections: selections, markClean: true)
        textView.reloadData()
        // load 不触发 onChange，查找栏若仍打开需手动刷新高亮。
        refreshQuickMatchesAfterTextChange()

        pendingScrollOrigin = origin
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingScrollIfNeeded()
        }
    }

    func currentSelections() -> [NSRange] {
        engine.selections.map(\.range)
    }

    var currentScrollOrigin: CGPoint {
        if let pendingScrollOrigin {
            return CGPoint(
                x: max(0, pendingScrollOrigin.x),
                y: max(0, pendingScrollOrigin.y)
            )
        }
        let origin = scrollView.contentView.bounds.origin
        return CGPoint(x: max(0, origin.x), y: max(0, origin.y))
    }

    private func applyPendingScrollIfNeeded() {
        guard let target = pendingScrollOrigin, view.window != nil else { return }

        syncViewport()
        let clipView = scrollView.contentView
        let visibleSize = clipView.bounds.size
        let contentSize = textView.frame.size

        let maxX = max(0, contentSize.width - visibleSize.width)
        let maxY = max(0, contentSize.height - visibleSize.height)
        let origin = CGPoint(
            x: min(max(0, target.x), maxX),
            y: min(max(0, target.y), maxY)
        )
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
        pendingScrollOrigin = nil
    }

    // MARK: - 查找替换

    func performFindAction(_ action: NSTextFinder.Action) {
        textFinder.performAction(action)

        switch action {
        case .showFindInterface, .showReplaceInterface:
            // 查找栏恢复上次查找字符串时不会触发 textDidChange，需要主动接管。
            observeFindFieldIfNeeded()
        case .hideFindInterface:
            clearFindHighlights()
            lastFindString = ""
        case .selectAll, .selectAllInSelection,
             .nextMatch, .previousMatch,
             .replace, .replaceAll, .replaceAndFind, .replaceAllInSelection:
            // 这些动作以查找器当前匹配为准，去掉本地兜底，避免与选区/替换结果重叠。
            quickMatchRanges = []
            applyFindHighlights()
        default:
            break
        }
    }

    /// 查找栏可见且已有匹配时，允许把全部查找结果转成多光标。
    var canSelectAllFindMatches: Bool {
        guard scrollView.isFindBarVisible else { return false }
        return !effectiveFindMatchRanges.isEmpty
    }

    /// 把当前查找结果全部变成选区（多光标），随后可直接编辑。
    func selectAllFindMatches() {
        // 先让编辑器获得焦点。若在查找器写入全部选区后再改第一响应者，
        // NSTextFinder 会把选区压回当前匹配（实测只剩最后一个匹配）。
        focusEditorNow()
        textFinder.performAction(.selectAll)
        // 选区已表达全部匹配，不再叠加黄色高亮。
        quickMatchRanges = []
        finderMatchRanges = textFinder.incrementalMatchRanges.map(\.rangeValue)
        applyFindHighlights()
    }

    private var effectiveFindMatchRanges: [NSRange] {
        finderMatchRanges.isEmpty ? quickMatchRanges : finderMatchRanges
    }

    private func updateFinderMatchRanges(_ ranges: [NSRange]) {
        finderMatchRanges = ranges
        applyFindHighlights()
    }

    private func updateQuickMatches(for needle: String) {
        lastFindString = needle
        quickMatchRanges = FindMatchScanner.ranges(of: needle, in: engine.text)
        applyFindHighlights()
    }

    /// 编辑文本后本地重新扫描；查找器的全量结果稍后到达时会覆盖本地结果。
    private func refreshQuickMatchesAfterTextChange() {
        guard scrollView.isFindBarVisible, !lastFindString.isEmpty else { return }
        finderMatchRanges = []
        quickMatchRanges = FindMatchScanner.ranges(
            of: lastFindString,
            in: engine.text
        )
        applyFindHighlights()
    }

    private func applyFindHighlights() {
        guard scrollView.isFindBarVisible else {
            textView.findHighlightRanges = []
            return
        }
        textView.findHighlightRanges = effectiveFindMatchRanges
    }

    private func clearFindHighlights() {
        finderMatchRanges = []
        quickMatchRanges = []
        textView.findHighlightRanges = []
    }

    /// 找到查找栏搜索框并监听文本变化；查找栏由 NSTextFinder 延迟创建，需重试一次。
    private func observeFindFieldIfNeeded() {
        if let field = findSearchField() {
            attachFindFieldObserver(field)
            updateQuickMatches(for: field.stringValue)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let field = self.findSearchField() else { return }
            self.attachFindFieldObserver(field)
            self.updateQuickMatches(for: field.stringValue)
        }
    }

    private func findSearchField() -> NSSearchField? {
        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        return descendants(of: scrollView).first { $0 is NSSearchField } as? NSSearchField
    }

    private func attachFindFieldObserver(_ field: NSSearchField) {
        guard observedFindField !== field else { return }
        if let findFieldObserver {
            NotificationCenter.default.removeObserver(findFieldObserver)
        }
        observedFindField = field
        findFieldObserver = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification,
            object: field,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let field = notification.object as? NSSearchField
            else {
                return
            }
            self.updateQuickMatches(for: field.stringValue)
        }
    }

    deinit {
        if let findFieldObserver {
            NotificationCenter.default.removeObserver(findFieldObserver)
        }
    }

    // MARK: - 多光标

    @discardableResult
    func selectNextOccurrence() -> MultiCursorResult {
        convert(textView.selectNextOccurrence())
    }

    @discardableResult
    func selectAllOccurrences() -> MultiCursorResult {
        convert(textView.selectAllOccurrences())
    }

    @discardableResult
    func addCursorsToSelectedLines() -> MultiCursorResult {
        convert(textView.addCursorsToSelectedLines())
    }

    private func convert(_ result: MultiCursorCommandResult) -> MultiCursorResult {
        switch result {
        case let .updated(selections):
            // 视图已写回选区并滚动主光标，这里只把范围转给窗口层做提示。
            view.window?.makeFirstResponder(textView)
            return .updated(selections.map(\.range))
        case .noChange:
            return .noChange
        case let .tooMany(limit):
            return .tooMany(limit: limit)
        }
    }

    @discardableResult
    func collapseSelectionsIfNeeded() -> Bool {
        textView.collapseSelectionsIfNeeded()
    }
}

/// 多光标命令对窗口层的结果，用于区分“无变化”“超上限”的提示。
enum MultiCursorResult: Equatable {
    case updated([NSRange])
    case noChange
    case tooMany(limit: Int)
}
