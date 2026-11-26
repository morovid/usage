import AppKit
import SwiftUI
import UserNotifications

@main
@MainActor
enum UsageApp {
    static func main() {
        let app = NSApplication.shared
        // Accessory apps can enter the Dock later when Accounts opens. Set the
        // image explicitly instead of relying on Launch Services' cached icon.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            app.applicationIconImage = icon
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // No SwiftUI scenes: windows are created only for explicit user actions.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let popover = StatusPopover()
    private var accountsWindow: NSWindow?
    private let accountsPresentation = AccountsPresentation()
    private var store: AppStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store = AppStore()
        UNUserNotificationCenter.current().delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Usage")
            button.image?.isTemplate = true
            button.toolTip = "Usage — AI account limits\nClick for usage · Right-click for menu"
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.contentSize = NSSize(width: 370, height: 460)
        popover.contentViewController = NSHostingController(
            rootView: UsagePopover(store: store,
                                  addAccount: { [weak self] in self?.showAddAccount() },
                                  openAccounts: { [weak self] in self?.showAccounts() },
                                  onResize: { [weak self] size in self?.popover.contentSize = size }))
        store.start()
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp ||
            NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            let menu = NSMenu()
            menu.addItem(withTitle: "About Usage", action: #selector(showAbout), keyEquivalent: "")
            menu.addItem(withTitle: "Accounts…", action: #selector(showAccounts), keyEquivalent: ",")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Usage", action: #selector(quit), keyEquivalent: "q")
            for item in menu.items { item.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc func showAccounts() {
        popover.performClose(nil)
        if accountsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 590),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Usage · Accounts"
            window.minSize = NSSize(width: 740, height: 540)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: AccountsView(store: store, presentation: accountsPresentation))
            window.center()
            accountsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        if accountsWindow?.isMiniaturized == true {
            accountsWindow?.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        accountsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === accountsWindow else { return }
        // Keep background monitoring running, but hide the Dock/Cmd-Tab entry.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if accountsWindow != nil { showAccounts() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }

    private func showAddAccount() {
        showAccounts()
        accountsPresentation.addAccountRequested = true
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(string: "Track your AI account usage and get notified as you approach your limits.\n\n")
        credits.append(NSAttributedString(string: "usage.morovid.com", attributes: [
            .link: URL(string: "https://usage.morovid.com")!
        ]))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Usage",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Morovid"
        ])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.showAccounts() }
    }
}
