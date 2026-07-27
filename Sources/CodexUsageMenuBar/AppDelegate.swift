import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    enum StatusItemAction: Equatable {
        case togglePopover
        case showContextMenu
    }

    struct WindowLayout: Equatable {
        let preferredSize: NSSize
        let minimumSize: NSSize
        let isResizable: Bool
    }

    static let settingsWindowLayout = WindowLayout(
        preferredSize: SettingsLayout.preferredWindowSize,
        minimumSize: SettingsLayout.minimumWindowSize,
        isResizable: true
    )

    let store: UsageStore
    let languageController: AppLanguageController

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var dashboardWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    private var languageObservation: AnyCancellable?

    override init() {
        store = UsageStore()
        languageController = .shared
        super.init()
        observeLanguageChanges()
    }

    init(
        store: UsageStore,
        languageController: AppLanguageController = .shared
    ) {
        self.store = store
        self.languageController = languageController
        super.init()
        observeLanguageChanges()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy(.accessory)
        configurePopover()
        configureStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flushState()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === dashboardWindowController?.window {
            dashboardWindowController = nil
        } else if window === settingsWindowController?.window {
            settingsWindowController = nil
        }
        updateActivationPolicy()
    }

    private func configurePopover() {
        let rootView = LocalizedAppRoot(
            languageController: languageController
        ) {
            MenuBarView(
                onShowDashboard: { [weak self] in
                    self?.showDashboard()
                },
                onShowSettings: { [weak self] in
                    self?.showSettings()
                }
            )
            .environmentObject(self.store)
        }

        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.layoutSubtreeIfNeeded()

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(
            width: 360,
            height: max(1, hostingController.view.fittingSize.height)
        )
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }

        let image = NSImage(
            systemSymbolName: "chart.bar.xaxis",
            accessibilityDescription: "Codex Usage Lens"
        )
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Codex Usage Lens"
        button.setAccessibilityLabel("Codex Usage Lens")
        updateStatusItemLocalization(button)
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApplication.shared.currentEvent
        if
            Self.statusItemAction(for: event) == .showContextMenu,
            let event
        {
            popover.performClose(nil)
            NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: sender)
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    static func statusItemAction(for event: NSEvent?) -> StatusItemAction {
        guard let event else {
            return .togglePopover
        }
        if event.type == .rightMouseUp {
            return .showContextMenu
        }
        if
            event.type == .leftMouseUp,
            event.modifierFlags.contains(.control)
        {
            return .showContextMenu
        }
        return .togglePopover
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
        }
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(
            menuItem(
                title: L10n.string("menu.show"),
                action: #selector(showDashboard),
                keyEquivalent: ""
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                title: L10n.string("settings.command"),
                action: #selector(showSettings),
                keyEquivalent: ","
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                title: L10n.string("menu.quit"),
                action: #selector(quitApplication),
                keyEquivalent: "q"
            )
        )

        return menu
    }

    private func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.target = self
        item.isEnabled = true
        return item
    }

    private func observeLanguageChanges() {
        languageObservation = languageController.$selection
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applyCurrentLanguage()
                }
            }
    }

    private func applyCurrentLanguage() {
        configurePopover()
        if let button = statusItem?.button {
            updateStatusItemLocalization(button)
        }
        dashboardWindowController?.window?.title =
            L10n.string("window.dashboard.title")
        settingsWindowController?.window?.title =
            L10n.string("window.settings.title")
    }

    private func updateStatusItemLocalization(_ button: NSStatusBarButton) {
        button.setAccessibilityHelp(
            L10n.string("status.accessibility.help")
        )
    }

    @objc
    private func showDashboard() {
        popover.performClose(nil)

        if dashboardWindowController == nil {
            dashboardWindowController = makeWindowController(
                title: L10n.string("window.dashboard.title"),
                contentSize: NSSize(width: 1040, height: 760),
                minimumSize: NSSize(width: 900, height: 650),
                resizable: true,
                autosaveName: "CodexUsageLensDashboard"
            ) {
                LocalizedAppRoot(
                    languageController: languageController
                ) {
                    DashboardView()
                        .environmentObject(self.store)
                }
            }
        }

        showWindow(dashboardWindowController)
    }

    @objc
    func showSettings() {
        popover.performClose(nil)

        if settingsWindowController == nil {
            let layout = Self.settingsWindowLayout
            settingsWindowController = makeWindowController(
                title: L10n.string("window.settings.title"),
                contentSize: layout.preferredSize,
                minimumSize: layout.minimumSize,
                resizable: layout.isResizable,
                autosaveName: "CodexUsageLensSettings"
            ) {
                LocalizedAppRoot(
                    languageController: languageController
                ) {
                    SettingsView()
                        .environmentObject(self.store)
                }
            }
        }

        showWindow(settingsWindowController)
    }

    @objc
    private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func showWindow(_ controller: NSWindowController?) {
        applyActivationPolicy(.regular)
        controller?.showWindow(nil)
        controller?.window?.deminiaturize(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func activationPolicy(
        hasDashboardWindow: Bool,
        hasSettingsWindow: Bool
    ) -> NSApplication.ActivationPolicy {
        hasDashboardWindow || hasSettingsWindow ? .regular : .accessory
    }

    private func updateActivationPolicy() {
        applyActivationPolicy(
            Self.activationPolicy(
                hasDashboardWindow: dashboardWindowController != nil,
                hasSettingsWindow: settingsWindowController != nil
            )
        )
    }

    private func applyActivationPolicy(
        _ policy: NSApplication.ActivationPolicy
    ) {
        guard NSApplication.shared.activationPolicy() != policy else { return }
        NSApplication.shared.setActivationPolicy(policy)
    }

    private func makeWindowController<Content: View>(
        title: String,
        contentSize: NSSize,
        minimumSize: NSSize,
        resizable: Bool,
        autosaveName: String,
        @ViewBuilder content: () -> Content
    ) -> NSWindowController {
        var styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable
        ]
        if resizable {
            styleMask.insert(.resizable)
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentMinSize = minimumSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: content())
        window.center()
        window.setFrameAutosaveName(autosaveName)

        return NSWindowController(window: window)
    }
}
