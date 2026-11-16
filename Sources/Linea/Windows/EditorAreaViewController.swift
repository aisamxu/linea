import AppKit

/// 负责在当前窗口的编辑区域中切换不同的 EditorViewController。
final class EditorAreaViewController: NSViewController {
    private(set) var currentEditor: EditorViewController?

    override func loadView() {
        view = NSView()
    }

    func show(_ editor: EditorViewController?) {
        if currentEditor === editor {
            editor?.prepareForDisplay()
            return
        }

        currentEditor?.view.removeFromSuperview()
        currentEditor?.removeFromParent()
        currentEditor = nil

        guard let editor else { return }

        addChild(editor)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editor.view)
        NSLayoutConstraint.activate([
            editor.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editor.view.topAnchor.constraint(equalTo: view.topAnchor),
            editor.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        currentEditor = editor
        editor.prepareForDisplay()
    }
}
