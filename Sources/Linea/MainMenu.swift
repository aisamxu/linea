import AppKit

/// 纯代码构建英文主菜单。文档/编辑/查找/多光标动作通过 responder chain
/// 交给当前 EditorWindowController 处理。
enum MainMenu {
    static func install() {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        mainMenu.addItem(applicationMenuItem)
        applicationMenuItem.submenu = makeApplicationMenu()

        mainMenu.addItem(makeFileMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        mainMenu.addItem(makeSelectionMenuItem())

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        windowMenuItem.submenu = makeWindowMenu()
        let windowMenu = windowMenuItem.submenu!

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private static func makeApplicationMenu() -> NSMenu {
        let menu = NSMenu(title: "Linea")

        let about = NSMenuItem(
            title: "About Linea",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = NSApp
        menu.addItem(about)

        menu.addItem(.separator())

        let hide = NSMenuItem(
            title: "Hide Linea",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hide.target = NSApp
        menu.addItem(hide)

        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        menu.addItem(hideOthers)

        let showAll = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAll.target = NSApp
        menu.addItem(showAll)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Linea",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    private static func makeFileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")

        menu.addItem(item(
            "New",
            #selector(AppDelegate.newDocumentAction(_:)),
            "n"
        ))
        menu.addItem(item(
            "New Tab",
            #selector(AppDelegate.newTabAction(_:)),
            "t"
        ))
        menu.addItem(item(
            "New Window",
            #selector(AppDelegate.newWindowAction(_:)),
            "n",
            [.command, .shift]
        ))
        menu.addItem(item(
            "Open…",
            #selector(AppDelegate.openDocument(_:)),
            "o"
        ))

        menu.addItem(.separator())

        menu.addItem(item(
            "Close Tab",
            #selector(EditorWindowController.closeTabAction(_:)),
            "w"
        ))
        menu.addItem(item(
            "Close Window",
            #selector(NSWindow.performClose(_:)),
            "w",
            [.command, .shift]
        ))

        menu.addItem(.separator())

        menu.addItem(item(
            "Save",
            #selector(EditorWindowController.saveDocument(_:)),
            "s"
        ))
        menu.addItem(item(
            "Save As…",
            #selector(EditorWindowController.saveDocumentAs(_:)),
            "s",
            [.command, .shift]
        ))

        return menuItem(title: "File", submenu: menu)
    }

    private static func makeEditMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")

        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))

        menu.addItem(.separator())

        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        // 纯文本编辑器：LineaTextView.paste 只读 .string，不会带入 RTF 字体和颜色。
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))

        menu.addItem(.separator())

        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(item(
            "Find…",
            #selector(EditorWindowController.showFindInterface(_:)),
            "f"
        ))
        findMenu.addItem(item(
            "Find and Replace…",
            #selector(EditorWindowController.showReplaceInterface(_:)),
            "f",
            [.command, .option]
        ))
        findMenu.addItem(.separator())
        findMenu.addItem(item(
            "Find Next",
            #selector(EditorWindowController.findNextMatch(_:)),
            "g"
        ))
        findMenu.addItem(item(
            "Find Previous",
            #selector(EditorWindowController.findPreviousMatch(_:)),
            "g",
            [.command, .shift]
        ))
        findMenu.addItem(.separator())
        // 把查找栏当前结果全部转为多选区，随后可直接多光标编辑。
        findMenu.addItem(item(
            "Select All Matches",
            #selector(EditorWindowController.selectAllFindMatches(_:)),
            "g",
            [.command, .option]
        ))

        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = findMenu
        menu.addItem(findItem)

        return menuItem(title: "Edit", submenu: menu)
    }

    private static func makeSelectionMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Selection")

        menu.addItem(item(
            "Select Next Occurrence",
            #selector(EditorWindowController.selectNextOccurrence(_:)),
            "d"
        ))
        menu.addItem(item(
            "Select All Occurrences",
            #selector(EditorWindowController.selectAllOccurrences(_:)),
            "g",
            [.command, .control]
        ))
        menu.addItem(item(
            "Add Cursors to Selected Lines",
            #selector(EditorWindowController.addCursorsToSelectedLines(_:)),
            "l",
            [.command, .shift]
        ))

        return menuItem(title: "Selection", submenu: menu)
    }

    private static func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")

        menu.addItem(item(
            "Minimize",
            #selector(NSWindow.performMiniaturize(_:)),
            "m"
        ))
        menu.addItem(item(
            "Zoom",
            #selector(NSWindow.performZoom(_:))
        ))

        menu.addItem(.separator())

        // ⌘1…⌘9 按标签栏顺序切换；menuItem.tag 使用 1 起的标签编号。
        let selectTabMenu = NSMenu(title: "Select Tab")
        for number in 1...9 {
            let selectItem = item(
                "Tab \(number)",
                #selector(EditorWindowController.selectTabAction(_:)),
                String(number)
            )
            selectItem.tag = number
            selectTabMenu.addItem(selectItem)
        }
        let selectTabItem = NSMenuItem(title: "Select Tab", action: nil, keyEquivalent: "")
        selectTabItem.submenu = selectTabMenu
        menu.addItem(selectTabItem)

        menu.addItem(.separator())

        menu.addItem(item(
            "Bring All to Front",
            #selector(NSApplication.arrangeInFront(_:))
        ))

        return menu
    }

    private static func menuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.submenu = submenu
        return menuItem
    }

    private static func item(
        _ title: String,
        _ action: Selector?,
        _ keyEquivalent: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        menuItem.keyEquivalentModifierMask = modifiers
        return menuItem
    }
}
