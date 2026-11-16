import Foundation

/// 把会话清单还原成窗口和标签。
///
/// clean 文件重新从磁盘读取；dirty 文件和未命名文档从草稿读取。
/// 单个标签失败只跳过该标签，并在最后汇总提示，不阻断其它内容恢复。
enum SessionRestorer {
    static func restore(
        manifest: SessionManifest,
        store: SessionStore,
        into windowManager: WindowManager
    ) -> [String] {
        var problems: [String] = []
        var usedTabIDs = Set<UUID>()
        var restoredWindows: [(snapshot: WindowSnapshot, tabs: [EditorTab], selectedID: UUID?)] = []

        for windowSnapshot in manifest.windows {
            guard !windowSnapshot.tabs.isEmpty else { continue }

            var restoredTabs: [(originalIndex: Int, tab: EditorTab)] = []
            for (index, tabSnapshot) in windowSnapshot.tabs.enumerated() {
                guard !usedTabIDs.contains(tabSnapshot.id) else {
                    problems.append("“\(tabSnapshot.displayName)” was skipped because its identifier was duplicated.")
                    continue
                }

                do {
                    let tab = try makeTab(
                        snapshot: tabSnapshot,
                        sessionID: manifest.sessionID,
                        store: store
                    )
                    usedTabIDs.insert(tab.id)
                    restoredTabs.append((index, tab))
                } catch {
                    problems.append(
                        "“\(tabSnapshot.displayName)” could not be restored: \(error.localizedDescription)"
                    )
                }
            }

            guard !restoredTabs.isEmpty else { continue }

            let requestedIndex = min(
                max(0, windowSnapshot.selectedTabIndex),
                max(0, windowSnapshot.tabs.count - 1)
            )
            let selectedID = restoredTabs.first(where: { $0.originalIndex == requestedIndex })?.tab.id
                ?? restoredTabs[0].tab.id

            restoredWindows.append((
                snapshot: windowSnapshot,
                tabs: restoredTabs.map(\.tab),
                selectedID: selectedID
            ))
        }

        guard !restoredWindows.isEmpty else { return problems }

        var activeWindowIndex = 0
        if let index = restoredWindows.firstIndex(where: { $0.snapshot.isActive }) {
            activeWindowIndex = index
        }

        var activeController: EditorWindowController?
        for (index, restoredWindow) in restoredWindows.enumerated() {
            let isActive = index == activeWindowIndex
            let controller = windowManager.makeWindow(
                tabs: restoredWindow.tabs,
                selectedTabID: restoredWindow.selectedID,
                frame: restoredWindow.snapshot.frame.rect,
                isActive: isActive
            )
            if isActive {
                activeController = controller
            }
        }

        if let activeController {
            windowManager.activate(activeController)
        }

        return problems
    }

    private static func makeTab(
        snapshot: TabSnapshot,
        sessionID: UUID,
        store: SessionStore
    ) throws -> EditorTab {
        let selections = snapshot.selections.map(\.nsRange)
        let normalizedSelections = selections.isEmpty
            ? [NSRange(location: 0, length: 0)]
            : selections

        if let filePath = snapshot.filePath, !filePath.isEmpty {
            let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
            let displayName = snapshot.displayName.isEmpty
                ? fileURL.lastPathComponent
                : snapshot.displayName

            if let draftFileName = snapshot.draftFileName {
                // 有草稿说明退出时是 dirty 状态，必须用草稿恢复，不能悄悄回退到磁盘旧内容。
                let text = try store.readDraft(named: draftFileName, sessionID: sessionID)
                let document = Document(
                    id: snapshot.id,
                    fileURL: fileURL,
                    displayName: displayName,
                    isDirty: true,
                    savedSignature: snapshot.fileSignature
                )
                return EditorTab(
                    document: document,
                    text: text,
                    selections: normalizedSelections,
                    scrollOrigin: snapshot.scrollOrigin.point
                )
            }

            let text = try DocumentStore.readText(from: fileURL)
            let signature = DocumentStore.currentSignature(of: fileURL) ?? snapshot.fileSignature
            let document = Document(
                id: snapshot.id,
                fileURL: fileURL,
                displayName: displayName,
                isDirty: false,
                savedSignature: signature
            )
            return EditorTab(
                document: document,
                text: text,
                selections: normalizedSelections,
                scrollOrigin: snapshot.scrollOrigin.point
            )
        }

        // 未命名文档即使文本为空也必须有草稿文件，否则无法恢复标签本身。
        guard let draftFileName = snapshot.draftFileName else {
            throw SessionStoreError.readFailed(
                "The draft for this untitled document is missing."
            )
        }

        let text = try store.readDraft(named: draftFileName, sessionID: sessionID)
        let displayName = snapshot.displayName.isEmpty ? "Untitled" : snapshot.displayName
        let document = Document(
            id: snapshot.id,
            fileURL: nil,
            displayName: displayName,
            isDirty: snapshot.isDirty || !text.isEmpty,
            savedSignature: nil
        )
        return EditorTab(
            document: document,
            text: text,
            selections: normalizedSelections,
            scrollOrigin: snapshot.scrollOrigin.point
        )
    }
}
