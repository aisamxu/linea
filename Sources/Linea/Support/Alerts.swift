import AppKit

/// 所有阻塞式用户确认集中在这里，保证文案和默认按钮一致。
enum Alerts {
    enum CloseDecision {
        case save
        case dontSave
        case cancel
    }

    enum ConflictDecision {
        case overwrite
        case reload
        case cancel
    }

    enum MissingFileDecision {
        case saveAs
        case overwrite
        case cancel
    }

    static func confirmClose(documentName: String) -> CloseDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes made to “\(documentName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .dontSave
        default:
            return .cancel
        }
    }

    static func externalModification(documentName: String) -> ConflictDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(documentName)” was changed on disk."
        alert.informativeText = "Do you want to overwrite the file with your version, or reload the version on disk? Reloading discards your unsaved changes."
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Reload")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .overwrite
        case .alertSecondButtonReturn:
            return .reload
        default:
            return .cancel
        }
    }

    static func missingFile(documentName: String) -> MissingFileDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(documentName)” no longer exists."
        alert.informativeText = "You can save it to a new location, or recreate it at the original path."
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Recreate")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .saveAs
        case .alertSecondButtonReturn:
            return .overwrite
        default:
            return .cancel
        }
    }

    static func error(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func restoreProblems(_ problems: [String]) {
        guard !problems.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some items could not be restored"
        alert.informativeText = problems.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// 返回 true 表示用户明确选择“仍然退出”，接受未保存内容丢失。
    static func sessionWriteFailed(_ error: Error) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Could not save the session."
        alert.informativeText = "\(error.localizedDescription)\n\nIf you quit anyway, unsaved document contents will be lost."
        alert.addButton(withTitle: "Cancel Quit")
        let quitButton = alert.addButton(withTitle: "Quit Anyway")
        quitButton.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
