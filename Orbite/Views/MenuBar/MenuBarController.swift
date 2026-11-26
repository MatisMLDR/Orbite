import AppKit
import Observation
import SwiftUI
import os

nonisolated private let log = Logger(subsystem: "app.matis.Orbite", category: "menubar")

extension Notification.Name {
    /// Posted by the app delegate when Orbite is reopened (Dock, Finder, Spotlight) without a visible window.
    static let orbiteReopen = Notification.Name("orbiteReopen")
}

/// Orbite's item in the menu bar: a live SwiftUI label in an AppKit status item (SwiftUI's
/// MenuBarExtra only shows text and images, and cannot keep a fixed width), and a popover panel.
/// It also hides the Dock icon while the window is closed.
final class MenuBarController: NSObject, NSPopoverDelegate {
    private unowned let model: AppModel
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?
    private var occlusionObserver: NSObjectProtocol?
    private var wasEnabled: Bool?

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.delegate = self

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(reopen), name: .orbiteReopen, object: nil)
        observeSettings()
    }

    // MARK: - Settings

    private func observeSettings() {
        let (enabled, style) = withObservationTracking {
            (model.ui.menuBarEnabled, model.ui.menuBarStyle)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSettings() }
        }
        apply(enabled: enabled, style: style)
    }

    private func apply(enabled: Bool, style: MenuBarStyle) {
        defer { wasEnabled = enabled }
        if enabled {
            let item = self.item ?? makeItem()
            item.length = style.width
            // The menu bar lays the item out later: check whether it found room then.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshVisibility() }
            return
        }
        if let item {
            popover.performClose(nil)
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
            occlusionObserver = nil
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            refreshVisibility()
        }
        // Turned off with the window closed: without the window the app would have no interface left.
        if wasEnabled == true, mainWindow == nil { showMainWindow() }
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: model.ui.menuBarStyle.width)
        item.autosaveName = "OrbiteTraffic"
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.setAccessibilityLabel("Orbite")
            let label = PassthroughHostingView(rootView: MenuBarItemContent(model: model))
            label.sizingOptions = []
            label.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                label.topAnchor.constraint(equalTo: button.topAnchor),
                label.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }
        if let window = item.button?.window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisibility() }
            }
        }
        self.item = item
        return item
    }

    /// macOS hides, without telling, an item that does not fit (next to the notch, a full menu bar):
    /// Réglages says so instead of leaving an empty choice.
    private func refreshVisibility() {
        let hidden = item.map { !($0.button?.window?.occlusionState.contains(.visible) ?? false) } ?? false
        log.debug("menu bar: hidden=\(hidden, privacy: .public)")
        if model.ui.menuBarItemHidden != hidden { model.ui.menuBarItemHidden = hidden }
    }

    // MARK: - Panel

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // Built at each opening and dropped at closing: a hidden panel would still redraw every second.
        let panel = NSHostingController(rootView: MenuBarPanel().environment(model))
        panel.sizingOptions = .preferredContentSize
        popover.contentViewController = panel
        model.setPanelOpen(true)
        NSApp.activate()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // A transient popover only closes on clicks inside Orbite: also close it on clicks elsewhere.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        popover.contentViewController = nil
        model.setPanelOpen(false)
    }

    func closePanel() {
        popover.performClose(nil)
    }

    // MARK: - Window and Dock

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && Self.isMain($0) }
    }

    private static func isMain(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main") == true
    }

    /// Brings the window back (with its Dock icon), optionally on an app of the panel.
    func showMainWindow(selecting selection: Selection? = nil) {
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular)
        if let selection {
            // The panel shows live traffic: show it live in the window too.
            if !model.store.window.isLive { model.store.window = TimeWindow(span: model.store.window.span, end: nil) }
            model.ui.selection = selection
        }
        // A window SwiftUI kept does not appear again: give it back its views first.
        model.setWindowOpen(true)
        if let window = NSApp.windows.first(where: Self.isMain) {
            window.makeKeyAndOrderFront(nil)
        } else {
            model.ui.openMainWindow?()
        }
        NSApp.activate()
    }

    /// Opens the window on the diagnosis sheet.
    func showDiagnosis() {
        showMainWindow()
        DispatchQueue.main.async { self.model.ui.showDiagnosis = true }
    }

    func showSettings() {
        popover.performClose(nil)
        model.ui.openSettingsWindow?()
        NSApp.activate()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, Self.isMain(window) else { return }
        model.setWindowOpen(false)
        // The window stays closed: Orbite keeps measuring from the menu bar, out of the Dock.
        if model.ui.menuBarEnabled { NSApp.setActivationPolicy(.accessory) }
    }

    @objc private func reopen() {
        showMainWindow()
    }
}

/// The label reads the style itself, so changing it in Réglages needs no new hosting view.
private struct MenuBarItemContent: View {
    let model: AppModel

    var body: some View {
        MenuBarLabel(style: model.ui.menuBarStyle)
            .environment(model)
    }
}

/// Lets clicks through to the status item's button.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
