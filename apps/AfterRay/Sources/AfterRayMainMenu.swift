import AppKit

/// The application menu bar. AfterRay is an `LSUIElement`, so this is the
/// only menu that exists — and ⌘C / ⌘V / ⌘Z never reach a text view unless
/// an Edit menu is here to turn those keys into `copy:` / `paste:` / `undo:`.
///
/// This menu only survives because the process is launched from AppKit
/// (`AfterRayMain`). A SwiftUI `App` scene overwrites `NSApp.mainMenu` with a
/// generated menu that has no Edit item, and it does so after
/// `applicationDidFinishLaunching`, so reinstalling here would not win.
enum AfterRayMainMenu {
    static func install(appMenu: NSMenu) {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        main.addItem(editMenuItem())
        NSApp.mainMenu = main
    }

    static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        )
        item.submenu = menu
        return item
    }
}
