import Combine
import Foundation

/// 标签栏的展示模型。文档的标题/脏状态变化会转发成 @Published，供 SwiftUI 更新。
final class EditorTab: ObservableObject, Identifiable {
    let id: UUID
    let document: Document
    let editor: EditorViewController

    @Published private(set) var title: String
    @Published private(set) var isDirty: Bool

    private var cancellable: AnyCancellable?

    init(document: Document, editor: EditorViewController) {
        self.id = document.id
        self.document = document
        self.editor = editor
        self.title = document.displayName
        self.isDirty = document.isDirty

        cancellable = Publishers.CombineLatest(document.$displayName, document.$isDirty)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name, dirty in
                guard let self else { return }
                if self.title != name {
                    self.title = name
                }
                if self.isDirty != dirty {
                    self.isDirty = dirty
                }
            }
    }
}

/// 一个窗口内的标签集合与当前选择。
extension EditorTab {
    convenience init(
        document: Document,
        text: String,
        selections: [NSRange],
        scrollOrigin: CGPoint? = nil
    ) {
        let editor = EditorViewController(
            document: document,
            text: text,
            selections: selections,
            scrollOrigin: scrollOrigin
        )
        self.init(document: document, editor: editor)
    }
}

final class WindowSession: ObservableObject {
    @Published var tabs: [EditorTab]
    @Published var selectedTabID: UUID?
    /// 退出写会话期间为 false，用于临时禁用标签栏交互，避免快照之后产生新状态。
    @Published var isInteractionEnabled = true

    init(tabs: [EditorTab] = [], selectedTabID: UUID? = nil) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID ?? tabs.first?.id
    }

    var selectedTab: EditorTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    var selectedIndex: Int? {
        guard let selectedTabID else { return nil }
        return tabs.firstIndex { $0.id == selectedTabID }
    }

    func tab(forFileURL url: URL) -> EditorTab? {
        let standardized = url.standardizedFileURL
        return tabs.first { $0.document.fileURL == standardized }
    }

    func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    func addTab(_ tab: EditorTab, select: Bool = true) {
        guard !tabs.contains(where: { $0.id == tab.id }) else { return }
        tabs.append(tab)
        if select {
            selectedTabID = tab.id
        }
    }

    /// 关闭标签后自动选中右侧相邻标签；没有右侧则选左侧。
    @discardableResult
    func removeTab(id: UUID) -> EditorTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = tabs.remove(at: index)

        if selectedTabID == id {
            if tabs.isEmpty {
                selectedTabID = nil
            } else {
                selectedTabID = tabs[min(index, tabs.count - 1)].id
            }
        }

        return removed
    }
}
