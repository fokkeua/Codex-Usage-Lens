import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexUsageMenuBar

@Test("Контекстное меню строки меню содержит стандартные действия")
@MainActor
func statusItemContextMenuContainsStandardActions() {
    let store = UsageStore(
        storageDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true),
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    let menu = AppDelegate(store: store).makeContextMenu()

    #expect(menu.items.count == 5)
    #expect(menu.items[0].title == "Показать Codex Usage Lens")
    #expect(menu.items[1].isSeparatorItem)
    #expect(menu.items[2].title == "Настройки…")
    #expect(menu.items[2].keyEquivalent == ",")
    #expect(menu.items[3].isSeparatorItem)
    #expect(menu.items[4].title == "Завершить Codex Usage Lens")
    #expect(menu.items[4].keyEquivalent == "q")
}

@Test("Accessibility activation строки меню открывает popover без currentEvent")
@MainActor
func statusItemAccessibilityActivationDefaultsToPopover() {
    #expect(AppDelegate.statusItemAction(for: nil) == .togglePopover)
}

@Test("Тема приложения по умолчанию следует системе")
@MainActor
func applicationAppearanceDefaultsToSystem() {
    #expect(AppDelegate.previewAppearance(arguments: ["app"]) == nil)
    #expect(
        AppDelegate.previewAppearance(
            arguments: ["app", "--preview-light"]
        ) == .light
    )
    #expect(
        AppDelegate.previewAppearance(
            arguments: ["app", "--preview-dark"]
        ) == .dark
    )
}

@Test("Панель открывается справа от значка и не выходит за экран")
@MainActor
func statusPanelUsesRightSideAnchor() {
    let visibleFrame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
    let centeredButton = NSRect(x: 100, y: 760, width: 24, height: 24)
    #expect(
        AppDelegate.statusPanelOriginX(
            buttonFrame: centeredButton,
            panelWidth: 360,
            visibleFrame: visibleFrame
        ) == 130
    )

    let edgeButton = NSRect(x: 940, y: 760, width: 24, height: 24)
    #expect(
        AppDelegate.statusPanelOriginX(
            buttonFrame: edgeButton,
            panelWidth: 360,
            visibleFrame: visibleFrame
        ) == 632
    )
}

@Test("Dock отображается только пока открыто управляемое окно")
@MainActor
func dockActivationPolicyTracksManagedWindows() {
    #expect(
        AppDelegate.activationPolicy(
            hasDashboardWindow: false,
            hasSettingsWindow: false
        ) == .accessory
    )
    #expect(
        AppDelegate.activationPolicy(
            hasDashboardWindow: true,
            hasSettingsWindow: false
        ) == .regular
    )
    #expect(
        AppDelegate.activationPolicy(
            hasDashboardWindow: false,
            hasSettingsWindow: true,
            hasAboutWindow: false
        ) == .regular
    )
    #expect(
        AppDelegate.activationPolicy(
            hasDashboardWindow: true,
            hasSettingsWindow: true,
            hasAboutWindow: false
        ) == .regular
    )
    #expect(
        AppDelegate.activationPolicy(
            hasDashboardWindow: false,
            hasSettingsWindow: false,
            hasAboutWindow: true
        ) == .regular
    )
}

@Test("Ссылки About ведут на публичные страницы репозитория")
func aboutLinksUseSecureRepositoryDestinations() {
    for destination in AboutDestination.allCases {
        #expect(destination.url.scheme == "https")
        #expect(destination.url.host == "github.com")
        #expect(destination.url.path.contains("Codex-Usage-Lens"))
    }
}

@Test("Окно настроек можно уменьшать без горизонтальной прокрутки цен")
@MainActor
func settingsWindowSupportsResponsiveLayout() {
    let layout = AppDelegate.settingsWindowLayout

    #expect(layout.isResizable)
    #expect(layout.minimumSize.width < layout.preferredSize.width)
    #expect(layout.minimumSize.height < layout.preferredSize.height)
    #expect(SettingsLayout.pricingScrollAxes.contains(.vertical))
    #expect(!SettingsLayout.pricingScrollAxes.contains(.horizontal))
}
