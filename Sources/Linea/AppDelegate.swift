import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowManager: WindowManager!
    private var sessionStore: SessionStore!

    private var pendingOpenURLs: [URL] = []
    private var isTestMode = false
    private var isTerminationInProgress = false

    // MARK: - 生命周期

    func applicationWillFinishLaunching(_ notification: Notification) {
        isTestMode = Self.detectTestMode()
        if !isTestMode {
            MainMenu.install()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isTestMode else { return }

        windowManager = WindowManager()
        sessionStore = SessionStore()

        restorePreviousSessionOrOpenBlankWindow()

        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs.removeAll()
            windowManager.openFiles(urls)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !isTestMode, !isTerminationInProgress else { return false }

        if windowManager.windowControllers.isEmpty {
            windowManager.newWindow()
        } else if !flag {
            windowManager.bringWindowsForward()
        } else {
            windowManager.activeWindowController?.window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isTestMode, !isTerminationInProgress else { return }

        if windowManager == nil {
            pendingOpenURLs.append(contentsOf: urls)
        } else {
            windowManager.openFiles(urls)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - 启动恢复

    private func restorePreviousSessionOrOpenBlankWindow() {
        do {
            if let restoration = try sessionStore.beginRestoration() {
                let problems = SessionRestorer.restore(
                    manifest: restoration.manifest,
                    store: sessionStore,
                    into: windowManager
                )

                if !windowManager.hasWindows {
                    windowManager.newWindow()
                }

                sessionStore.finishRestoration(restoration)

                if !problems.isEmpty {
                    DispatchQueue.main.async {
                        Alerts.restoreProblems(problems)
                    }
                }
            } else {
                windowManager.newWindow()
            }
        } catch {
            Alerts.error(
                title: "Could not restore the previous session",
                message: error.localizedDescription
            )
            windowManager.newWindow()
        }
    }

    // MARK: - 文件菜单

    @objc func newDocumentAction(_ sender: Any?) {
        guard !isTestMode, !isTerminationInProgress else { return }

        if let controller = windowManager.activeWindowController {
            controller.newTab()
        } else {
            windowManager.newWindow()
        }
    }

    /// ⌘T：优先在当前窗口新建标签；没有窗口时新建窗口（窗口内自带空白标签）。
    @objc func newTabAction(_ sender: Any?) {
        newDocumentAction(sender)
    }

    @objc func newWindowAction(_ sender: Any?) {
        guard !isTestMode, !isTerminationInProgress else { return }
        windowManager.newWindow()
    }

    @objc func openDocument(_ sender: Any?) {
        guard !isTestMode, !isTerminationInProgress else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        if let window = windowManager.activeWindowController?.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK else { return }
                self?.windowManager.openFiles(panel.urls)
            }
        } else {
            guard panel.runModal() == .OK else { return }
            windowManager.openFiles(panel.urls)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newDocumentAction(_:)),
             #selector(newTabAction(_:)),
             #selector(newWindowAction(_:)),
             #selector(openDocument(_:)):
            return !isTestMode && !isTerminationInProgress
        default:
            return true
        }
    }

    // MARK: - 退出

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTestMode {
            return .terminateNow
        }

        if isTerminationInProgress {
            return .terminateLater
        }

        // 顺序必须是「提交输入法组合 → 收集会话 → 冻结」，
        // 否则会话快照可能缺少最后一次组合提交。
        windowManager.commitPendingInput()
        let collected = windowManager.collectSession()

        // 没有窗口/标签时不写会话，并确保旧快照不会在下次启动重放。
        guard !collected.windows.isEmpty else {
            do {
                try sessionStore.clearSession()
                return .terminateNow
            } catch {
                return Alerts.sessionWriteFailed(error) ? .terminateNow : .terminateCancel
            }
        }

        isTerminationInProgress = true
        windowManager.setTerminating(true)

        let manifest = SessionManifest(
            sessionID: UUID(),
            createdAt: Date(),
            windows: collected.windows
        )
        let drafts = collected.drafts
        let store: SessionStore = sessionStore
        let manager: WindowManager = windowManager

        // 编辑期间不写快照；只有正常退出才在后台写完清单和草稿后结束应用。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try store.write(manifest: manifest, drafts: drafts)
                DispatchQueue.main.async {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            } catch {
                DispatchQueue.main.async {
                    manager.setTerminating(false)
                    let quitAnyway = Alerts.sessionWriteFailed(error)
                    if quitAnyway {
                        NSApp.reply(toApplicationShouldTerminate: true)
                    } else {
                        self?.isTerminationInProgress = false
                        NSApp.reply(toApplicationShouldTerminate: false)
                    }
                }
            }
        }

        return .terminateLater
    }

    // MARK: - 测试隔离

    private static func detectTestMode() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if NSClassFromString("XCTestCase") != nil {
            return true
        }
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            return true
        }
        return false
    }
}
