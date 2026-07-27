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
            hasSettingsWindow: true
        ) == .regular
    )
    #expect(
        AppDelegate.activationPolicy(
            hasDashboardWindow: true,
            hasSettingsWindow: true
        ) == .regular
    )
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
