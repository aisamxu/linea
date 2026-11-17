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
        textFinder.incrementalSearchingShouldDimContentView = true
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
