import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// 一个窗口：标签栏 + 编辑区 + 文档命令（保存、关闭、查找、多光标）。
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let session: WindowSession
    let areaController = EditorAreaViewController()

    var isTerminating = false
    var onClosed: ((EditorWindowController) -> Void)?

    private var tabBarHostingView: NSHostingView<TabBarView>?
    private var cancellables = Set<AnyCancellable>()
    private var selectedChromeCancellable: AnyCancellable?

    init(tabs: [EditorTab], selectedTabID: UUID?, frame: NSRect?) {
        session = WindowSession(tabs: tabs, selectedTabID: selectedTabID)

        let desiredFrame = frame.map(WindowGeometry.adjustedForCurrentScreens)
            ?? WindowGeometry.defaultFrame(existingWindowCount: 0)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.title = "Linea"

        super.init(window: window)

        window.delegate = self
        window.setFrame(desiredFrame, display: false)

        setupContent()
        setupBindings()

        if session.tabs.isEmpty {
            let tab = makeUntitledTab()
            session.tabs = [tab]
            session.selectedTabID = tab.id
        } else if session.selectedTab == nil, let firstTab = session.tabs.first {
            session.selectedTabID = firstTab.id
        }

        window.setFrame(desiredFrame, display: false)
        selectedTabDidChange(force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - UI 构建

    private func setupContent() {
        let contentView = NSView()
        let rootViewController = NSViewController()
        rootViewController.view = contentView
        contentViewController = rootViewController
        rootViewController.addChild(areaController)

        let hostingView = NSHostingView(
            rootView: TabBarView(
                session: session,
                onSelect: { [weak self] id in self?.selectTabFromTabBar(id: id) },
                onClose: { [weak self] id in self?.closeTabFromTabBar(id: id) },
                onNew: { [weak self] in self?.newTab() }
            )
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hostingView)

        areaController.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(areaController.view)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.heightAnchor.constraint(equalToConstant: 36),

            areaController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            areaController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            areaController.view.topAnchor.constraint(equalTo: hostingView.bottomAnchor),
            areaController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        tabBarHostingView = hostingView
    }


    private func setupBindings() {
        session.$selectedTabID
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.selectedTabDidChange() }
            .store(in: &cancellables)
    }

    private func selectedTabDidChange(force: Bool = false) {
        guard let tab = session.selectedTab else {
            selectedChromeCancellable = nil
            areaController.show(nil)
            updateWindowChrome()
            return
        }

        if force || areaController.currentEditor !== tab.editor {
            areaController.show(tab.editor)
        } else {
            tab.editor.prepareForDisplay()
        }

        selectedChromeCancellable = Publishers.CombineLatest(tab.$title, tab.$isDirty)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateWindowChrome()
            }

        updateWindowChrome()
    }

    private func updateWindowChrome() {
        guard let window else { return }

        if let tab = session.selectedTab {
            window.title = tab.document.displayName
            window.representedURL = tab.document.fileURL
            window.isDocumentEdited = tab.document.isDirty
        } else {
            window.title = "Linea"
            window.representedURL = nil
            window.isDocumentEdited = false
        }
    }

    // MARK: - 标签操作

    @discardableResult
    func newTab() -> EditorTab {
        let tab = makeUntitledTab()
        session.addTab(tab)
        window?.makeKeyAndOrderFront(nil)
        selectedTabDidChange()
        return tab
    }

    func addTab(_ tab: EditorTab, select: Bool = true) {
        session.addTab(tab, select: select)
        if select {
            window?.makeKeyAndOrderFront(nil)
            selectedTabDidChange()
        }
    }

    func selectTab(id: UUID) {
        guard session.tabs.contains(where: { $0.id == id }) else { return }
        window?.makeKeyAndOrderFront(nil)

        if session.selectedTabID == id {
            areaController.currentEditor?.focusEditor()
            return
        }

        session.selectTab(id: id)
        selectedTabDidChange()
    }

    /// 按标签栏顺序切换（从 1 开始）；编号越界时忽略。
    func selectTab(number: Int) {
        let index = number - 1
        guard session.tabs.indices.contains(index) else { return }
        selectTab(id: session.tabs[index].id)
    }

    /// 同步聚焦当前标签的文本视图；窗口排序前别用，见 `EditorViewController.focusEditorNow()`。
    func focusEditor() {
        areaController.currentEditor?.focusEditorNow()
    }

    func tab(forFileURL url: URL) -> EditorTab? {
        session.tab(forFileURL: url)
    }

    private func makeUntitledTab() -> EditorTab {
        let document = Document(
            fileURL: nil,
            displayName: nextUntitledName(),
            isDirty: false,
            savedSignature: nil
        )
        return EditorTab(
            document: document,
            text: "",
            selections: [NSRange(location: 0, length: 0)]
        )
    }

    private func nextUntitledName() -> String {
        let pattern = try! NSRegularExpression(pattern: "^Untitled ([0-9]+)$")
        var maximumNumber = 0

        for tab in session.tabs {
            guard tab.document.fileURL == nil else { continue }
            let name = tab.document.displayName
            let range = NSRange(location: 0, length: (name as NSString).length)
            guard let match = pattern.firstMatch(in: name, range: range),
                  match.numberOfRanges == 2
            else {
                continue
            }
            let numberString = (name as NSString).substring(with: match.range(at: 1))
            maximumNumber = max(maximumNumber, Int(numberString) ?? 0)
        }

        return "Untitled \(maximumNumber + 1)"
    }

    private func selectTabFromTabBar(id: UUID) {
        selectTab(id: id)
    }

    private func closeTabFromTabBar(id: UUID) {
        guard let tab = session.tabs.first(where: { $0.id == id }) else { return }
        _ = closeTab(tab)
    }

    /// 关闭单个标签：脏文档先走 Save / Don't Save / Cancel。
    @discardableResult
    func closeTab(_ tab: EditorTab) -> Bool {
        guard session.tabs.contains(where: { $0.id == tab.id }) else { return true }

        // 关闭前先提交输入法组合，保证脏检查针对最终文本。
        tab.editor.commitPendingInput()

        if tab.document.isDirty {
            switch Alerts.confirmClose(documentName: tab.document.displayName) {
            case .cancel:
                return false
            case .save:
                guard save(tab: tab) else { return false }
            case .dontSave:
                break
            }
        }

        session.removeTab(id: tab.id)

        if session.tabs.isEmpty {
            window?.close()
            return true
        }

        selectedTabDidChange()
        return true
    }

    // MARK: - 保存

    @discardableResult
    func saveSelectedTab() -> Bool {
        guard let tab = session.selectedTab else { return false }
        return save(tab: tab)
    }

    @discardableResult
    func save(tab: EditorTab, forceSaveAs: Bool = false) -> Bool {
        let document = tab.document

        if forceSaveAs || document.fileURL == nil {
            return saveAs(tab: tab, suggestedURL: document.fileURL)
        }

        guard let fileURL = document.fileURL else { return false }

        let currentSignature = FileSignature.current(for: fileURL)
        if currentSignature == nil {
            switch Alerts.missingFile(documentName: document.displayName) {
            case .saveAs:
                return saveAs(tab: tab, suggestedURL: fileURL)
            case .overwrite:
                return write(tab: tab, to: fileURL)
            case .cancel:
                return false
            }
        }

        if let baseline = document.savedSignature,
           let currentSignature,
           baseline != currentSignature {
            switch Alerts.externalModification(documentName: document.displayName) {
            case .overwrite:
                return write(tab: tab, to: fileURL)
            case .reload:
                return reloadFromDisk(tab: tab, fileURL: fileURL, signature: currentSignature)
            case .cancel:
                return false
            }
        }

        return write(tab: tab, to: fileURL)
    }

    private func saveAs(tab: EditorTab, suggestedURL: URL?) -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save As"
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedURL?.lastPathComponent
            ?? tab.document.displayName
        if let suggestedURL {
            panel.directoryURL = suggestedURL.deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(tab: tab, to: url)
    }

    private func write(tab: EditorTab, to url: URL) -> Bool {
        do {
            // currentText 会先提交输入法组合，确保 marked text 一并落盘。
            try DocumentStore.writeText(tab.editor.currentText, to: url)
        } catch {
            Alerts.error(
                title: "Could not save “\(tab.document.displayName)”",
                message: error.localizedDescription
            )
            return false
        }

        let signature = DocumentStore.currentSignature(of: url)
        tab.document.markSaved(to: url, signature: signature)
        tab.editor.markSaved()
        updateWindowChrome()

        if session.selectedTab === tab {
            tab.editor.focusEditor()
        }
        return true
    }

    private func reloadFromDisk(tab: EditorTab, fileURL: URL, signature: FileSignature) -> Bool {
        do {
            let text = try DocumentStore.readText(from: fileURL)
            tab.editor.replaceTextFromDisk(text)
            tab.document.markReloaded(from: fileURL, signature: signature)
            updateWindowChrome()
            return true
        } catch {
            Alerts.error(
                title: "Could not reload “\(tab.document.displayName)”",
                message: error.localizedDescription
            )
            return false
        }
    }

    // MARK: - 快照

    func makeSnapshot() -> WindowSnapshot? {
        guard let window, !session.tabs.isEmpty else { return nil }

        let tabSnapshots: [TabSnapshot] = session.tabs.map { tab in
            let draftFileName = tab.document.needsDraft
                ? "\(tab.id.uuidString).txt"
                : nil

            return TabSnapshot(
                id: tab.id,
                filePath: tab.document.fileURL?.path,
                displayName: tab.document.displayName,
                isDirty: tab.document.isDirty,
                draftFileName: draftFileName,
                fileSignature: tab.document.savedSignature,
                selections: tab.editor.currentSelections().map { SelectionSnapshot($0) },
                scrollOrigin: ScrollOrigin(tab.editor.currentScrollOrigin)
            )
        }

        let selectedIndex = min(
            max(0, session.selectedIndex ?? 0),
            max(0, session.tabs.count - 1)
        )

        return WindowSnapshot(
            frame: WindowFrame(window.frame),
            isActive: window.isKeyWindow,
            selectedTabIndex: selectedIndex,
            tabs: tabSnapshots
        )
    }

    func draftTexts() -> [String: String] {
        var drafts: [String: String] = [:]
        for tab in session.tabs where tab.document.needsDraft {
            drafts["\(tab.id.uuidString).txt"] = tab.editor.currentText
        }
        return drafts
    }

    /// 提交所有标签的输入法组合；退出收集会话前调用，保证快照包含最终文本。
    func commitPendingInput() {
        for tab in session.tabs {
            tab.editor.commitPendingInput()
        }
    }

    func prepareForTermination() {
        isTerminating = true
        setEditingEnabled(false)
    }

    /// 退出写会话期间禁用标签栏和编辑器，避免快照之后继续产生修改。
    func setEditingEnabled(_ enabled: Bool) {
        session.isInteractionEnabled = enabled
        for tab in session.tabs {
            tab.editor.setEditingEnabled(enabled)
        }
        if enabled {
            // 会话写入失败取消退出后，把焦点还给当前标签。
            session.selectedTab?.editor.focusEditor()
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        if isTerminating { return true }

        // 脏检查前先提交输入法组合，避免把 marked text 当成未修改。
        commitPendingInput()

        // 关闭窗口时逐个处理脏标签，任一取消就保留整个窗口。
        for tab in session.tabs where tab.document.isDirty {
            switch Alerts.confirmClose(documentName: tab.document.displayName) {
            case .cancel:
                return false
            case .save:
                guard save(tab: tab) else { return false }
            case .dontSave:
                break
            }
        }

        return true
    }

    func windowWillClose(_ notification: Notification) {
        onClosed?(self)
    }

    // MARK: - 菜单动作

    @objc func selectTabAction(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else { return }
        selectTab(number: menuItem.tag)
    }

    @objc func closeTabAction(_ sender: Any?) {
        guard let tab = session.selectedTab else { return }
        _ = closeTab(tab)
    }

    @objc func saveDocument(_ sender: Any?) {
        _ = saveSelectedTab()
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let tab = session.selectedTab else { return }
        _ = save(tab: tab, forceSaveAs: true)
    }

    @objc func showFindInterface(_ sender: Any?) {
        performFindAction(.showFindInterface)
    }

    @objc func showReplaceInterface(_ sender: Any?) {
        performFindAction(.showReplaceInterface)
    }

    @objc func findNextMatch(_ sender: Any?) {
        performFindAction(.nextMatch)
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        performFindAction(.previousMatch)
    }

    @objc func selectAllFindMatches(_ sender: Any?) {
        session.selectedTab?.editor.selectAllFindMatches()
    }

    @objc func selectNextOccurrence(_ sender: Any?) {
        guard let tab = session.selectedTab else { return }
        handleMultiCursorResult(tab.editor.selectNextOccurrence())
    }

    @objc func selectAllOccurrences(_ sender: Any?) {
        guard let tab = session.selectedTab else { return }
        handleMultiCursorResult(tab.editor.selectAllOccurrences())
    }

    @objc func addCursorsToSelectedLines(_ sender: Any?) {
        guard let tab = session.selectedTab else { return }
        handleMultiCursorResult(tab.editor.addCursorsToSelectedLines())
    }

    private func performFindAction(_ action: NSTextFinder.Action) {
        session.selectedTab?.editor.performFindAction(action)
    }

    private func handleMultiCursorResult(_ result: MultiCursorResult) {
        switch result {
        case .updated:
            break
        case .noChange:
            NSSound.beep()
        case let .tooMany(limit):
            NSSound.beep()
            Alerts.error(
                title: "Too many selections",
                message: "This command would create more than \(limit) selections. Select a shorter range or fewer lines and try again."
            )
        }
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !isTerminating, let action = menuItem.action else { return false }

        switch action {
        case #selector(selectTabAction(_:)):
            // menuItem.tag 是 1 起的标签编号；超出现有标签数时禁用。
            return menuItem.tag >= 1 && menuItem.tag <= session.tabs.count
        case #selector(selectAllFindMatches(_:)):
            // 只有查找栏可见且已有匹配时才有意义。
            return session.selectedTab?.editor.canSelectAllFindMatches ?? false
        case #selector(closeTabAction(_:)),
             #selector(saveDocument(_:)),
             #selector(saveDocumentAs(_:)),
             #selector(showFindInterface(_:)),
             #selector(showReplaceInterface(_:)),
             #selector(findNextMatch(_:)),
             #selector(findPreviousMatch(_:)),
             #selector(selectNextOccurrence(_:)),
             #selector(selectAllOccurrences(_:)),
             #selector(addCursorsToSelectedLines(_:)):
            return session.selectedTab != nil
        default:
            return true
        }
    }
}
