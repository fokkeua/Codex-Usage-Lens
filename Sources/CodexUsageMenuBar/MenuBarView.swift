import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @State private var showsImporter = false
    private let onShowDashboard: (() -> Void)?
    private let onShowSettings: (() -> Void)?

    init(
        onShowDashboard: (() -> Void)? = nil,
        onShowSettings: (() -> Void)? = nil
    ) {
        self.onShowDashboard = onShowDashboard
        self.onShowSettings = onShowSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let message = store.persistenceReadOnlyMessage {
                PersistenceReadOnlyBanner(
                    message: message,
                    compact: true
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            HStack(spacing: 10) {
                compactMetric(
                    title: "Сегодня",
                    summary: store.todaySummary,
                    tint: .usageBlue
                )
                compactMetric(
                    title: "Неделя",
                    summary: store.weekSummary,
                    tint: .usageTeal
                )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Divider()

            VStack(spacing: 8) {
                primaryButton
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        importButton
                        settingsButton
                    }
                    VStack(spacing: 8) {
                        importButton
                        settingsButton
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(14)

            Divider()

            HStack {
                Label(
                    L10n.presentation(store.sourceSubtitle),
                    systemImage: sourceIcon
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(L10n.presentation(store.sourceSubtitle))
                Spacer()
                Button("Завершить") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 360)
        .background(.regularMaterial)
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.json, .commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    store.importFile(url)
                }
            case .failure(let error):
                store.alertMessage = error.localizedDescription
            }
        }
        .alert(
            store.isReadOnly
                ? L10n.string("Локальное состояние")
                : L10n.string("Импорт usage"),
            isPresented: Binding(
                get: { store.alertMessage != nil },
                set: { if !$0 { store.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(L10n.presentation(store.alertMessage ?? ""))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.usageBlue, .usagePurple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Usage Lens")
                    .font(.headline)
                Text("Личная оценка API-equivalent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.refreshRealData()
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing || !store.canPersist)
            .accessibilityLabel("Обновить реальные данные и официальные цены")
            .accessibilityValue(
                store.isRefreshing
                    ? L10n.string("Обновление выполняется")
                    : (store.hasRefreshError
                        ? L10n.string(
                            "Последнее обновление завершилось с ошибками"
                        )
                        : L10n.string("Готово"))
            )
            .help("Обновить реальные данные и официальные цены")
            Circle()
                .fill(sourceStatusTint)
                .frame(width: 8, height: 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Источник данных")
                .accessibilityValue(sourceStatusDescription)
                .help(sourceStatusDescription)
        }
        .padding(14)
    }

    private func compactMetric(
        title: String,
        summary: UsageSummary,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.string(title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }
            Text(UsageFormatting.tokens(summary.totalTokens))
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            HStack {
                Text("токенов")
                Spacer()
                Text(UsageFormatting.dollars(summary.apiEquivalentCost))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06))
        )
    }

    private var primaryButton: some View {
        Button {
            showDashboard()
        } label: {
            HStack {
                Label("Открыть дашборд", systemImage: "rectangle.3.group")
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .frame(minHeight: 34)
        .accessibilityIdentifier("usage-dashboard-button")
        .buttonStyle(.borderedProminent)
        .tint(.usageBlue)
    }

    private var importButton: some View {
        Button {
            showsImporter = true
        } label: {
            Label("Импорт", systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .disabled(!store.canPersist)
        .accessibilityIdentifier("usage-import-button")
    }

    private var settingsButton: some View {
        Button {
            showSettings()
        } label: {
            Label("Настройки", systemImage: "gearshape")
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .accessibilityIdentifier("usage-settings-button")
    }

    private var sourceIcon: String {
        switch store.sourceKind {
        case .empty: "tray"
        case .demo: "sparkles"
        case .importedFile, .codexLocal, .otelLive: "doc.text"
        }
    }

    private var sourceStatusTint: Color {
        if store.isReadOnly {
            return .usageOrange
        }
        if store.hasRefreshError {
            return .usageRed
        }
        switch store.sourceKind {
        case .empty, .demo:
            return .usageOrange
        case .importedFile, .codexLocal, .otelLive:
            return .usageTeal
        }
    }

    private var sourceStatusDescription: String {
        if store.isReadOnly {
            return L10n.format(
                "menubar.source.readOnly",
                store.sourceKind.title
            )
        }
        return store.hasRefreshError
            ? L10n.format(
                "menubar.source.refreshError",
                store.sourceKind.title
            )
            : store.sourceKind.title
    }

    private func showDashboard() {
        if let onShowDashboard {
            onShowDashboard()
        } else {
            openWindow(id: "dashboard")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func showSettings() {
        if let onShowSettings {
            onShowSettings()
        } else {
            openWindow(id: "settings")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
