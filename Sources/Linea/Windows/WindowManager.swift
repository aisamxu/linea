import AppKit

/// 管理所有编辑器窗口，并负责打开文件、收集会话快照。
final class WindowManager {
    private(set) var windowControllers: [EditorWindowController] = []

    var hasWindows: Bool {
        !windowControllers.isEmpty
    }

    var activeWindowController: EditorWindowController? {
        if let keyController = NSApp.keyWindow?.windowController as? EditorWindowController,
           windowControllers.contains(where: { $0 === keyController }) {
            return keyController
        }

        if let mainController = NSApp.mainWindow?.windowController as? EditorWindowController,
           windowControllers.contains(where: { $0 === mainController }) {
            return mainController
        }

        return windowControllers.last
    }

    // MARK: - 窗口

    @discardableResult
    func makeWindow(
        tabs: [EditorTab],
        selectedTabID: UUID?,
        frame: NSRect?,
        isActive: Bool
    ) -> EditorWindowController {
        let controller = EditorWindowController(
            tabs: tabs,
            selectedTabID: selectedTabID,
            frame: frame
        )

        controller.onClosed = { [weak self] closedController in
            self?.windowControllers.removeAll { $0 === closedController }
        }

        windowControllers.append(controller)

        if isActive {
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            controller.window?.orderFront(nil)
        }

        return controller
    }

    @discardableResult
    func newWindow() -> EditorWindowController {
        makeWindow(
            tabs: [],
            selectedTabID: nil,
            frame: WindowGeometry.defaultFrame(existingWindowCount: windowControllers.count),
            isActive: true
        )
    }

    func activate(_ controller: EditorWindowController) {
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func bringWindowsForward() {
        for controller in windowControllers {
            controller.window?.orderFront(nil)
        }
        activeWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 打开文件

    func openFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        var newTabs: [EditorTab] = []
        var errors: [String] = []
        var pendingPaths = Set<String>()

        for rawURL in urls {
            let url = rawURL.standardizedFileURL

            if focusExistingTab(for: url) != nil {
                continue
            }

            guard !pendingPaths.contains(url.path) else { continue }
            pendingPaths.insert(url.path)

            do {
                let text = try DocumentStore.readText(from: url)
                let signature = DocumentStore.currentSignature(of: url)
                let document = Document(
                    fileURL: url,
                    displayName: url.lastPathComponent,
                    isDirty: false,
                    savedSignature: signature
                )
                let tab = EditorTab(
                    document: document,
                    text: text,
                    selections: [NSRange(location: 0, length: 0)]
                )
                newTabs.append(tab)
            } catch {
                errors.append("“\(url.lastPathComponent)”: \(error.localizedDescription)")
            }
        }

        if !newTabs.isEmpty {
            if let target = activeWindowController ?? windowControllers.last {
                for tab in newTabs {
                    target.addTab(tab, select: false)
                }
                if let lastTab = newTabs.last {
                    target.selectTab(id: lastTab.id)
                }
            } else {
                let controller = makeWindow(
                    tabs: newTabs,
                    selectedTabID: newTabs.last?.id,
                    frame: WindowGeometry.defaultFrame(existingWindowCount: 0),
                    isActive: true
                )
                activate(controller)
            }
        }

        if !errors.isEmpty {
            Alerts.error(
                title: urls.count == 1 ? "Could not open the file" : "Could not open some files",
                message: errors.joined(separator: "\n")
            )
        }
    }

    @discardableResult
    private func focusExistingTab(for url: URL) -> EditorTab? {
        for controller in windowControllers {
            guard let tab = controller.tab(forFileURL: url) else { continue }
            controller.selectTab(id: tab.id)
            activate(controller)
            return tab
        }
        return nil
    }

    // MARK: - 会话

    /// 退出前提交所有窗口、所有标签的输入法组合。
    func commitPendingInput() {
        for controller in windowControllers {
            controller.commitPendingInput()
        }
    }

    func collectSession() -> (windows: [WindowSnapshot], drafts: [String: String]) {
        let activeController = activeWindowController
        var windows: [WindowSnapshot] = []
        var drafts: [String: String] = [:]

        for controller in windowControllers {
            guard var snapshot = controller.makeSnapshot() else { continue }
            snapshot.isActive = controller === activeController
            windows.append(snapshot)
            drafts.merge(controller.draftTexts()) { _, new in new }
        }

        if !windows.isEmpty, !windows.contains(where: { $0.isActive }) {
            windows[0].isActive = true
        }

        return (windows, drafts)
    }

    func setTerminating(_ terminating: Bool) {
        for controller in windowControllers {
            if terminating {
                controller.prepareForTermination()
            } else {
                controller.isTerminating = false
                controller.setEditingEnabled(true)
            }
        }
    }
}
