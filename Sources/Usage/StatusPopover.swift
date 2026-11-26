import AppKit
import Combine

@MainActor
final class UsagePopoverLayout: ObservableObject {
    @Published var maximumHeight: CGFloat = (NSScreen.main?.visibleFrame.height ?? 1080) / 2
}

/// A square, borderless status panel instead of NSPopover's rounded system chrome.
@MainActor
final class StatusPopover: NSObject, NSWindowDelegate {
    let layout = UsagePopoverLayout()
    private let panel: StatusPanel
    private weak var anchorView: NSView?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    override init() {
        panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 160),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = true
        panel.hasShadow = true
        panel.delegate = self
    }

    var contentViewController: NSViewController? {
        get { panel.contentViewController }
        set { panel.contentViewController = newValue }
    }

    var contentSize: NSSize {
        get { panel.frame.size }
        set {
            guard newValue.width > 0, newValue.height > 0, panel.frame.size != newValue else { return }
            panel.setContentSize(newValue)
            if isShown { position() }
        }
    }

    var isShown: Bool { panel.isVisible }

    func show(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
        anchorView = view
        position()
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func performClose(_ sender: Any?) {
        panel.orderOut(nil)
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
    }

    func windowDidResignKey(_ notification: Notification) {
        performClose(nil)
    }

    private func position() {
        guard let view = anchorView, let window = view.window else { return }
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? window.frame
        let maximumHeight = bounds.height / 2
        if layout.maximumHeight != maximumHeight { layout.maximumHeight = maximumHeight }
        let x = min(max(anchor.midX - panel.frame.width / 2, bounds.minX + 6),
                    bounds.maxX - panel.frame.width - 6)
        let y = max(bounds.minY + 6, anchor.minY - panel.frame.height - 6)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installMonitors() {
        guard localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.performClose(nil) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.performClose(nil)
                return nil
            }
            if event.type != .keyDown, event.window !== self.panel, event.window !== self.anchorView?.window {
                self.performClose(nil)
            }
            return event
        }
    }
}

private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
