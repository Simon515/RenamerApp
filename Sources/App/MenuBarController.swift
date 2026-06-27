import Cocoa
import SwiftUI

@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    init() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "folder.badge.gear", accessibilityDescription: "Renamer")
        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        statusItem = item

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 220, height: 160)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarPopover(
            openMainWindow: openMainWindow,
            onPickFolders: { [weak self] urls in
                self?.popover?.performClose(nil)
                NotificationCenter.default.post(name: .renamerPickFolders, object: urls)
            }
        ))
        self.popover = popover
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title == "Renamer" {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // If no window, SwiftUI WindowGroup creates one on activation.
    }
}
