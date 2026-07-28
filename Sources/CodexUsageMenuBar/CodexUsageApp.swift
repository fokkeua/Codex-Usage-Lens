import SwiftUI

@main
struct CodexUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var languageController =
        AppLanguageController.shared

    var body: some Scene {
        Settings {
            LocalizedAppRoot(languageController: languageController) {
                SettingsView()
                    .environmentObject(appDelegate.store)
            }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.string("О Codex Usage Lens")) {
                    appDelegate.showAbout()
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(L10n.string("settings.command")) {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
