import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    enum StatusItemAction: Equatable {
        case togglePopover
        case showContextMenu
    }

    enum PreviewAppearance: Equatable {
        case light
        case dark
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
    private var statusPanelController: NSWindowController?
    private var statusPanelHostingController: NSViewController?
    private var outsideClickMonitor: Any?
    private var panelEventMonitor: Any?
    private var dashboardWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    private var aboutWindowController: NSWindowController?
    private var menuPreviewWindowController: NSWindowController?
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
        applyPreviewAppearanceOverride()
        applyActivationPolicy(.accessory)
        configurePopover()
        configureStatusItem()
        if CommandLine.arguments.contains("--preview-menu") {
            showMenuPreviewWindow()
        } else if CommandLine.arguments.contains("--preview-about") {
            showAbout()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeStatusPanelEventMonitors()
        store.flushState()
    }

    static func previewAppearance(
        arguments: [String]
    ) -> PreviewAppearance? {
        if arguments.contains("--preview-dark") {
            return .dark
        }
        if arguments.contains("--preview-light") {
            return .light
        }
        return nil
    }

    private func applyPreviewAppearanceOverride() {
        switch Self.previewAppearance(arguments: CommandLine.arguments) {
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case nil:
            NSApplication.shared.appearance = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === dashboardWindowController?.window {
            dashboardWindowController = nil
        } else if window === settingsWindowController?.window {
            settingsWindowController = nil
        } else if window === aboutWindowController?.window {
            aboutWindowController = nil
        } else if window === menuPreviewWindowController?.window {
            menuPreviewWindowController = nil
        }
        updateActivationPolicy()
    }

    private func configurePopover() {
        closePopover()

        let rootView = LocalizedAppRoot(
            languageController: languageController
        ) {
            MenuBarView(
                onShowDashboard: { [weak self] in
                    self?.showDashboard()
                },
                onShowSettings: { [weak self] in
                    self?.showSettings()
                },
                onShowAbout: { [weak self] in
                    self?.showAbout()
                }
            )
            .environmentObject(self.store)
        }

        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.layoutSubtreeIfNeeded()
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.cornerRadius =
            StatusMenuPanel.cornerRadius
        hostingController.view.layer?.cornerCurve = .continuous
        hostingController.view.layer?.masksToBounds = true

        let contentSize = NSSize(
            width: 360,
            height: max(1, hostingController.view.fittingSize.height)
        )
        let panel = StatusMenuPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController

        statusPanelHostingController = hostingController
        statusPanelController = NSWindowController(window: panel)
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

        if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.25
            ) { [weak self, weak button] in
                guard let self, let button else { return }
                self.togglePopover(relativeTo: button)
            }
        }
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApplication.shared.currentEvent
        if
            Self.statusItemAction(for: event) == .showContextMenu,
            let event
        {
            closePopover()
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
        guard let panel = statusPanelController?.window else { return }

        if panel.isVisible {
            closePopover()
        } else {
            resizeAndPositionStatusPanel(relativeTo: button)
            installStatusPanelEventMonitors()
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    private func closePopover() {
        removeStatusPanelEventMonitors()
        statusPanelController?.window?.orderOut(nil)
    }

    private func resizeAndPositionStatusPanel(
        relativeTo button: NSStatusBarButton
    ) {
        guard
            let panel = statusPanelController?.window,
            let hostingView = statusPanelHostingController?.view,
            let buttonWindow = button.window
        else {
            return
        }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let contentSize = NSSize(
            width: 360,
            height: max(1, fittingSize.height)
        )
        panel.setContentSize(contentSize)

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(
            buttonRectInWindow
        )
        let visibleFrame = (
            buttonWindow.screen
                ?? NSScreen.screens.first
        )?.visibleFrame ?? buttonRectOnScreen

        let sideInset: CGFloat = 8
        let panelGap: CGFloat = 6
        let panelX = Self.statusPanelOriginX(
            buttonFrame: buttonRectOnScreen,
            panelWidth: contentSize.width,
            visibleFrame: visibleFrame,
            sideInset: sideInset,
            iconGap: panelGap
        )
        let preferredY =
            buttonRectOnScreen.minY - contentSize.height - panelGap
        let panelY = max(
            visibleFrame.minY + sideInset,
            preferredY
        )

        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
    }

    static func statusPanelOriginX(
        buttonFrame: NSRect,
        panelWidth: CGFloat,
        visibleFrame: NSRect,
        sideInset: CGFloat = 8,
        iconGap: CGFloat = 6
    ) -> CGFloat {
        let minimumX = visibleFrame.minX + sideInset
        let maximumX = visibleFrame.maxX - panelWidth - sideInset
        let rightOfIconX = buttonFrame.maxX + iconGap
        return min(
            max(rightOfIconX, minimumX),
            max(minimumX, maximumX)
        )
    }

    private func installStatusPanelEventMonitors() {
        removeStatusPanelEventMonitors()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }

        panelEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown, event.keyCode == 53 {
                closePopover()
                return nil
            }

            if
                event.type == .leftMouseUp,
                event.window === statusPanelController?.window,
                let button = statusItem?.button
            {
                DispatchQueue.main.async { [weak self, weak button] in
                    guard let self, let button else { return }
                    self.resizeAndPositionStatusPanel(relativeTo: button)
                }
            }

            return event
        }
    }

    private func removeStatusPanelEventMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let panelEventMonitor {
            NSEvent.removeMonitor(panelEventMonitor)
            self.panelEventMonitor = nil
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
        aboutWindowController?.window?.title =
            L10n.string("window.about.title")
    }

    private func updateStatusItemLocalization(_ button: NSStatusBarButton) {
        button.setAccessibilityHelp(
            L10n.string("status.accessibility.help")
        )
    }

    @objc
    private func showDashboard() {
        closePopover()

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
        closePopover()

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
    func showAbout() {
        closePopover()

        if aboutWindowController == nil {
            aboutWindowController = makeWindowController(
                title: L10n.string("window.about.title"),
                contentSize: NSSize(width: 520, height: 540),
                minimumSize: NSSize(width: 520, height: 540),
                resizable: false,
                autosaveName: "CodexUsageLensAbout"
            ) {
                LocalizedAppRoot(
                    languageController: languageController
                ) {
                    AboutView()
                }
            }
        }

        showWindow(aboutWindowController)
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

    private func showMenuPreviewWindow() {
        menuPreviewWindowController = makeWindowController(
            title: "Codex",
            contentSize: NSSize(width: 360, height: 820),
            minimumSize: NSSize(width: 360, height: 600),
            resizable: false,
            autosaveName: "CodexUsageLensMenuPreview"
        ) {
            LocalizedAppRoot(
                languageController: self.languageController
            ) {
                MenuBarView(
                    onShowDashboard: { [weak self] in
                        self?.showDashboard()
                    },
                    onShowSettings: { [weak self] in
                        self?.showSettings()
                    },
                    onShowAbout: { [weak self] in
                        self?.showAbout()
                    }
                )
                .environmentObject(self.store)
            }
        }

        if
            let window = menuPreviewWindowController?.window,
            let view = window.contentViewController?.view
        {
            view.layoutSubtreeIfNeeded()
            let fittingSize = view.fittingSize
            if fittingSize.width > 0, fittingSize.height > 0 {
                window.setContentSize(fittingSize)
            }
        }
        showWindow(menuPreviewWindowController)
    }

    static func activationPolicy(
        hasDashboardWindow: Bool,
        hasSettingsWindow: Bool,
        hasAboutWindow: Bool = false
    ) -> NSApplication.ActivationPolicy {
        hasDashboardWindow || hasSettingsWindow || hasAboutWindow
            ? .regular
            : .accessory
    }

    private func updateActivationPolicy() {
        if menuPreviewWindowController != nil {
            applyActivationPolicy(.regular)
            return
        }
        applyActivationPolicy(
            Self.activationPolicy(
                hasDashboardWindow: dashboardWindowController != nil,
                hasSettingsWindow: settingsWindowController != nil,
                hasAboutWindow: aboutWindowController != nil
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

private final class StatusMenuPanel: NSPanel {
    static let cornerRadius: CGFloat = 16

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )

        level = .popUpMenu
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        collectionBehavior = [
            .transient,
            .moveToActiveSpace,
            .fullScreenAuxiliary
        ]
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
