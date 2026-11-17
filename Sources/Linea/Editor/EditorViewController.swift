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

    let findBar = FindBarView()
    private var findBarHeightConstraint: NSLayoutConstraint!
    private var lineNumberRuler: LineNumberRulerView?
    private var pendingScrollOrigin: CGPoint?

    private var findBarVisible = false
    private var findOptions = FindBarView.Options()
    /// 当前查询的全部匹配（升序）；高亮、导航与替换都以它为准。
    private var findMatches: [NSRange] = []
    private var currentMatchIndex: Int?
    /// 最近一次查询；查找栏收起后 ⌘G/⇧⌘G 仍可继续导航。
    private var lastFindQuery = ""

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
        configureFindBar()
        observeChanges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - 视图生命周期

    override func loadView() {
        let container = NSView()

        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        container.addSubview(findBar)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // 查找栏收起时高度为 0，编辑区仍占满整个容器。
        findBarHeightConstraint = findBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: container.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findBarHeightConstraint,
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
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

    private func configureFindBar() {
        findBar.onQueryChanged = { [weak self] _ in
            self?.search(selectFirst: true)
        }
        findBar.onOptionsChanged = { [weak self] options in
            guard let self else { return }
            self.findOptions = options
            self.search(selectFirst: true)
        }
        findBar.onNext = { [weak self] in self?.findNext() }
        findBar.onPrevious = { [weak self] in self?.findPrevious() }
        findBar.onSelectAllMatches = { [weak self] in
            self?.selectAllFindMatches()
        }
        findBar.onReplace = { [weak self] replacement in
            self?.replaceCurrentMatch(with: replacement)
        }
        findBar.onReplaceAll = { [weak self] replacement in
            self?.replaceAllMatches(with: replacement)
        }
        findBar.onClose = { [weak self] in self?.closeFindBar() }

        // 查找栏可见时 Esc 优先收起查找栏，而不是折叠多光标。
        textView.onCancelOperation = { [weak self] in
            guard let self, self.findBarVisible else { return false }
            self.closeFindBar()
            return true
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
            // 文本变化后立即按当前查询重算匹配，高亮与计数保持同步。
            self.refreshFindMatchesAfterTextChange()
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
        // 查找替换会绕过普通插入路径，退出冻结期间直接收起查找栏。
        closeFindBar()
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
        // load 不触发 onChange，查找栏若仍打开需手动刷新匹配。
        refreshFindMatchesAfterTextChange()

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

    var isFindBarVisible: Bool { findBarVisible }

    /// 查找栏可见且已有匹配时，允许把全部查找结果转成多光标。
    var canSelectAllFindMatches: Bool {
        findBarVisible && !findMatches.isEmpty
    }

    /// 显示查找栏。打开时优先用主选区的单行文本预填搜索框。
    func showFindBar(replacing: Bool) {
        // 组合期间 buffer 里还没有 marked text，先提交再查找。
        textView.commitPendingInput()

        // 多光标查找前折叠为主选区，行为与 1.0.2 一致。
        let primary = engine.selections.last
        let selectedText: String?
        if let primary, primary.range.length > 0 {
            let text = engine.substring(in: primary.range)
            // 搜索框是单行控件；跨行选区不预填，避免把换行塞进查询。
            selectedText = text.contains(where: { $0.isNewline }) ? nil : text
        } else {
            selectedText = nil
        }
        if engine.selections.count > 1, let primary {
            textView.setSelections([primary])
        }

        findBarVisible = true
        findBar.isHidden = false
        findBar.isReplaceRowVisible = replacing
        findBarHeightConstraint.constant = findBar.preferredHeight
        findBar.setOptions(findOptions)
        if let selectedText {
            findBar.setQuery(selectedText, selectAll: true)
        } else {
            findBar.setQuery(lastFindQuery, selectAll: true)
        }
        view.layoutSubtreeIfNeeded()
        syncViewport()
        search(selectFirst: true)
        findBar.focusSearchField(selectAll: true)
    }

    /// 收起查找栏；保留查询与选项，方便下次打开或 ⌘G 继续导航。
    func closeFindBar() {
        guard findBarVisible else { return }
        findBarVisible = false
        findBar.isHidden = true
        findBarHeightConstraint.constant = 0
        findMatches = []
        currentMatchIndex = nil
        textView.findHighlightRanges = []
        findBar.updateResult(current: nil, total: 0)
        view.layoutSubtreeIfNeeded()
        syncViewport()
        focusEditorNow()
    }

    func findNext() {
        moveToMatch(backward: false)
    }

    func findPrevious() {
        moveToMatch(backward: true)
    }

    /// 把当前查找结果全部变成选区（多光标），随后可直接编辑。
    func selectAllFindMatches() {
        guard findBarVisible else { return }
        // 先把匹配刷新到最新，避免按钮状态与文本不一致。
        search(selectFirst: false)
        guard !findMatches.isEmpty else {
            NSSound.beep()
            return
        }
        textView.setSelections(findMatches.map { TextSelection(range: $0) })
        // 选区已表达全部匹配，不再叠加黄色高亮。
        textView.findHighlightRanges = []
        currentMatchIndex = nil
        findBar.updateResult(current: nil, total: findMatches.count)
        focusEditorNow()
    }

    /// 替换当前匹配；替换后自动选中下一处，便于连续操作。
    func replaceCurrentMatch(with replacement: String) {
        guard findBarVisible, !findMatches.isEmpty else { return }

        let index: Int
        if let currentMatchIndex, findMatches.indices.contains(currentMatchIndex) {
            index = currentMatchIndex
        } else if let selection = engine.selections.last?.range,
                  let exact = findMatches.firstIndex(of: selection) {
            index = exact
        } else {
            index = 0
        }
        let range = findMatches[index]
        guard range.location + range.length <= engine.length else { return }

        engine.replace(range: range, with: replacement, origin: .programmatic)
        // 编辑回调已重新扫描；从替换文本末尾继续找下一处。
        let threshold = range.location + (replacement as NSString).length
        if !findMatches.isEmpty,
           let next = findMatches.firstIndex(where: { $0.location >= threshold }) {
            selectMatch(at: next, reveal: true)
        } else {
            currentMatchIndex = nil
            textView.setSelections([.caret(at: min(threshold, engine.length))])
            findBar.updateResult(current: nil, total: findMatches.count)
        }
    }

    /// 一次事务替换全部匹配，并保持替换前的滚动位置。
    func replaceAllMatches(with replacement: String) {
        guard findBarVisible, !findMatches.isEmpty else { return }

        let origin = currentScrollOrigin
        let edits = findMatches.map {
            TextEdit(range: $0, replacement: replacement)
        }
        let first = findMatches[0]
        let caret = first.location + (replacement as NSString).length
        engine.apply(
            edits: edits,
            selectionAfter: [.caret(at: caret)],
            origin: .programmatic
        )

        // 编辑后视图会把主光标滚入可见区域；恢复用户原来的位置，
        // 避免 Replace All 后跳到文档开头。行号栏强制刷新，防止残留空白。
        restoreScrollOrigin(origin)
        textView.lineNumberRuler?.refresh()
        scrollView.contentView.needsDisplay = true

        // 替换文本可能仍匹配查询（例如大小写不同），按新文本重新计数。
        search(selectFirst: false)
    }

    private var scannerOptions: FindMatchOptions {
        FindMatchOptions(
            matchCase: findOptions.matchCase,
            wholeWord: findOptions.wholeWord
        )
    }

    /// 按搜索框当前内容重算匹配。`selectMatch` 为 true 时选中锚点之后的第一处。
    private func search(selectFirst: Bool) {
        guard findBarVisible else { return }
        lastFindQuery = findBar.query
        guard !lastFindQuery.isEmpty else {
            findMatches = []
            currentMatchIndex = nil
            textView.findHighlightRanges = []
            findBar.updateResult(current: nil, total: 0)
            return
        }

        findMatches = FindMatchScanner.ranges(
            of: lastFindQuery,
            in: engine.text,
            options: scannerOptions
        )
        textView.findHighlightRanges = findMatches

        guard !findMatches.isEmpty else {
            currentMatchIndex = nil
            findBar.updateResult(current: nil, total: 0)
            return
        }

        if selectFirst {
            let anchor = engine.selections.last?.range.location ?? 0
            let index = findMatches.firstIndex { $0.location >= anchor } ?? 0
            selectMatch(at: index, reveal: true)
        } else if let selection = engine.selections.last?.range,
                  selection.length > 0,
                  let exact = findMatches.firstIndex(of: selection) {
            currentMatchIndex = exact
            findBar.updateResult(current: exact + 1, total: findMatches.count)
        } else {
            currentMatchIndex = nil
            findBar.updateResult(current: nil, total: findMatches.count)
        }
    }

    private func selectMatch(at index: Int, reveal: Bool) {
        guard findMatches.indices.contains(index) else { return }
        currentMatchIndex = index
        let range = findMatches[index]
        textView.setSelections([TextSelection(range: range)])
        if reveal {
            textView.scrollRangeToVisible(range)
        }
        findBar.updateResult(current: index + 1, total: findMatches.count)
    }

    /// ⌘G/⇧⌘G。查找栏收起时按上次查询导航，不重新打开查找栏。
    private func moveToMatch(backward: Bool) {
        let matches: [NSRange]
        if findBarVisible {
            matches = findMatches
        } else if !lastFindQuery.isEmpty {
            matches = FindMatchScanner.ranges(
                of: lastFindQuery,
                in: engine.text,
                options: scannerOptions
            )
        } else {
            showFindBar(replacing: false)
            return
        }
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }

        let selection = engine.selections.last?.range
            ?? NSRange(location: 0, length: 0)
        let target: Int
        if backward {
            target = matches.lastIndex { $0.location < selection.location }
                ?? matches.count - 1
        } else {
            // 当前匹配已选中时从它之后开始，否则从插入点开始。
            let threshold = selection.length > 0
                ? selection.location + 1
                : selection.location
            target = matches.firstIndex { $0.location >= threshold } ?? 0
        }

        let range = matches[target]
        textView.setSelections([TextSelection(range: range)])
        textView.scrollRangeToVisible(range)
        if findBarVisible {
            findMatches = matches
            currentMatchIndex = target
            findBar.updateResult(current: target + 1, total: matches.count)
        }
    }

    /// 编辑文本后刷新高亮与计数，但不移动光标（用户可能正在普通编辑）。
    private func refreshFindMatchesAfterTextChange() {
        guard findBarVisible else { return }
        search(selectFirst: false)
    }

    /// 把滚动位置恢复到 `origin`，并夹取到当前文档范围内。
    private func restoreScrollOrigin(_ origin: CGPoint) {
        syncViewport()
        let clipView = scrollView.contentView
        let visibleSize = clipView.bounds.size
        let contentSize = textView.frame.size
        let target = CGPoint(
            x: min(max(0, origin.x), max(0, contentSize.width - visibleSize.width)),
            y: min(max(0, origin.y), max(0, contentSize.height - visibleSize.height))
        )
        clipView.scroll(to: target)
        scrollView.reflectScrolledClipView(clipView)
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
        }
    }

    @discardableResult
    func collapseSelectionsIfNeeded() -> Bool {
        textView.collapseSelectionsIfNeeded()
    }
}

/// 多光标命令对窗口层的结果，用于区分“无变化”的提示。
enum MultiCursorResult: Equatable {
    case updated([NSRange])
    case noChange
}
