import AppKit
import Charts
import SwiftUI

struct MenuBarView: View {
    private enum ExpandedSection {
        case plan
        case cost
    }

    @EnvironmentObject private var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var loginCoordinator =
        CodexLoginCoordinator.shared
    @State private var expandedSection: ExpandedSection?
    @State private var showsAccountConfirmation = false
    @State private var showsResetConfirmation = false
    private let onShowDashboard: (() -> Void)?
    private let onShowSettings: (() -> Void)?
    private let onShowAbout: (() -> Void)?

    private let usageURL = URL(
        string: "https://chatgpt.com/codex/settings/usage"
    )!

    init(
        onShowDashboard: (() -> Void)? = nil,
        onShowSettings: (() -> Void)? = nil,
        onShowAbout: (() -> Void)? = nil
    ) {
        self.onShowDashboard = onShowDashboard
        self.onShowSettings = onShowSettings
        self.onShowAbout = onShowAbout
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                accountHeader(now: context.date)
                menuDivider
                weeklySection(now: context.date)
                menuDivider
                resetCreditsSection(now: context.date)
                usageEstimateSection
                menuDivider
                creditsSection
                menuDivider
                expandableRows(now: context.date)
                menuDivider
                destinationRows(now: context.date)
                menuDivider
                systemRows
            }
        }
        .frame(width: 360)
        .background(.regularMaterial)
        .confirmationDialog(
            L10n.string("Сменить активный аккаунт Codex?"),
            isPresented: $showsAccountConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Продолжить вход")) {
                beginAccountLogin()
            }
            Button(L10n.string("Отмена"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "Codex хранит один активный вход. После авторизации "
                        + "новый аккаунт станет активным на этом Mac."
                )
            )
        }
        .confirmationDialog(
            L10n.string("Использовать reset credit?"),
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Сбросить текущий лимит")) {
                store.consumeRateLimitResetCredit(
                    creditID: nextResetCredit?.id
                )
            }
            Button(L10n.string("Отмена"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "Один доступный reset credit будет израсходован."
                )
            )
        }
        .alert(
            store.isReadOnly
                ? L10n.string("Локальное состояние")
                : L10n.string("Codex"),
            isPresented: Binding(
                get: { store.alertMessage != nil },
                set: { if !$0 { store.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(L10n.presentation(store.alertMessage ?? ""))
        }
        .onAppear {
            if store.serviceStatus == nil {
                store.refreshServiceStatus()
            }
        }
    }

    private func accountHeader(now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex")
                    .font(.system(size: 16, weight: .semibold))
                Text(updatedText(now: now))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 3) {
                Text(accountTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 190, alignment: .trailing)
                    .help(accountTitle)
                Text(planTitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func weeklySection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Недельный лимит"))
                .font(.system(size: 15, weight: .semibold))

            WeeklyUsageBar(
                remainingPercent: weeklyRemainingPercent,
                expectedRemainingPercent:
                    weeklyExpectedRemainingPercent(now: now)
            )
            .frame(height: 7)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        L10n.format(
                            "menubar.weekly.left",
                            weeklyRemainingPercent
                        )
                    )
                    .fontWeight(.medium)

                    if let deficit = weeklyDeficit(now: now), deficit > 0 {
                        Text(
                            L10n.format(
                                "menubar.weekly.deficit",
                                deficit
                            )
                        )
                    } else {
                        Text(L10n.string("В пределах недельного темпа"))
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(
                        weeklyResetText(now: now)
                    )
                    if let runOut = weeklyRunOutText(now: now) {
                        Text(runOut)
                    } else {
                        Text(L10n.string("Хватит до сброса"))
                    }
                }
                .multilineTextAlignment(.trailing)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func resetCreditsSection(now: Date) -> some View {
        Button {
            guard resetCreditCount > 0 else { return }
            showsResetConfirmation = true
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("Reset credits лимита"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(
                        L10n.format(
                            "menubar.resetCredits.available",
                            resetCreditCount
                        )
                    )
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(
                        resetCreditCount > 0
                            ? AnyShapeStyle(Color.primary)
                            : AnyShapeStyle(Color.secondary)
                    )
                }

                Spacer()

                if store.isConsumingResetCredit {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(
                        resetCreditTiming(now: now),
                        systemImage: "clock"
                    )
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
        .disabled(
            resetCreditCount == 0
                || store.isConsumingResetCredit
                || store.isReadOnly
        )
        .padding(.horizontal, 10)
        .padding(.top, 9)
    }

    private var usageEstimateSection: some View {
        let snapshot = store.dashboardSnapshot(days: 30)

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 24) {
                metricPair(
                    topLabel: L10n.string("Сегодня"),
                    topValue: UsageFormatting.dollars(
                        store.todaySummary.apiEquivalentCost
                    ),
                    bottomLabel: L10n.string("Последние токены"),
                    bottomValue: UsageFormatting.tokens(
                        store.todaySummary.totalTokens
                    )
                )
                metricPair(
                    topLabel: L10n.string("menubar.30days"),
                    topValue: UsageFormatting.dollars(
                        snapshot.summary.apiEquivalentCost
                    ),
                    bottomLabel: L10n.string("Токены за 30 дней"),
                    bottomValue: UsageFormatting.tokens(
                        snapshot.summary.totalTokens
                    )
                )
            }

            ZStack(alignment: .topTrailing) {
                MenuUsageChart(points: chartPoints)
                    .frame(height: 70)

                Text(
                    UsageFormatting.dollars(maximumDailyCost)
                )
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    L10n.format(
                        "menubar.topModel",
                        topModelName
                    )
                )
                Text(
                    L10n.string(
                        "Оценка по токенам · не счёт за подписку"
                    )
                )
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func metricPair(
        topLabel: String,
        topValue: String,
        bottomLabel: String,
        bottomValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            metric(label: topLabel, value: topValue)
            metric(label: bottomLabel, value: bottomValue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14.5, weight: .semibold))
                .contentTransition(.numericText())
        }
    }

    private var creditsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.string("Кредиты"))
                .font(.system(size: 15, weight: .semibold))

            ProgressView(value: creditsProgress)
                .progressViewStyle(.linear)
                .tint(.codexAccent)

            HStack {
                Text(creditsRemainingText)
                Spacer()
                Text(creditsLimitText)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))

            menuActionRow(
                title: L10n.string("Купить кредиты…"),
                systemImage: "plus.circle",
                accessibilityID: "usage-buy-credits-button"
            ) {
                open(usageURL)
            }
            .padding(.horizontal, -8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func expandableRows(now: Date) -> some View {
        VStack(spacing: 0) {
            disclosureRow(
                title: L10n.string("Использование плана"),
                isExpanded: expandedSection == .plan
            ) {
                toggle(.plan)
            }

            if expandedSection == .plan {
                planDetails(now: now)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            disclosureRow(
                title: L10n.string("Стоимость"),
                isExpanded: expandedSection == .cost
            ) {
                toggle(.cost)
            }

            if expandedSection == .cost {
                costDetails
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func disclosureRow(
        title: String,
        isExpanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
        .animation(.easeOut(duration: 0.16), value: isExpanded)
    }

    private func planDetails(now: Date) -> some View {
        VStack(spacing: 7) {
            rateLimitDetail(
                title: windowTitle(for: primaryWindow),
                window: primaryWindow,
                now: now
            )
            if secondaryWindow != nil {
                rateLimitDetail(
                    title: L10n.string("Недельное окно"),
                    window: secondaryWindow,
                    now: now
                )
            }
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 5)
    }

    private func rateLimitDetail(
        title: String,
        window: CodexRateLimitWindow?,
        now: Date
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let window {
                Text(
                    "\(max(0, 100 - window.usedPercent))% · "
                        + resetText(for: window, now: now)
                )
            } else {
                Text("—")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private var costDetails: some View {
        let week = store.dashboardSnapshot(days: 7).summary
        let month = store.dashboardSnapshot(days: 30).summary
        return VStack(spacing: 7) {
            costDetailRow(
                title: L10n.string("Сегодня"),
                value: store.todaySummary.apiEquivalentCost
            )
            costDetailRow(
                title: L10n.string("7 дней"),
                value: week.apiEquivalentCost
            )
            costDetailRow(
                title: L10n.string("30 дней"),
                value: month.apiEquivalentCost
            )
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 5)
    }

    private func costDetailRow(
        title: String,
        value: Double
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(UsageFormatting.dollars(value))
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private func destinationRows(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            menuActionRow(
                title: loginCoordinator.isRunning
                    ? L10n.string("Вход выполняется…")
                    : L10n.string("Добавить аккаунт…"),
                systemImage: "plus",
                accessibilityID: "usage-add-account-button"
            ) {
                showsAccountConfirmation = true
            }
            .disabled(loginCoordinator.isRunning)

            menuActionRow(
                title: L10n.string("Дашборд использования"),
                systemImage: "chart.xyaxis.line",
                accessibilityID: "usage-dashboard-button"
            ) {
                showDashboard()
            }

            menuActionRow(
                title: L10n.string("Страница статуса"),
                systemImage: "waveform.path.ecg",
                trailingSystemImage: "chevron.right"
            ) {
                open(OpenAIStatusClient.pageURL)
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(serviceStatusTint)
                    .frame(width: 6, height: 6)
                Text(serviceStatusText(now: now))
                    .lineLimit(1)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 7)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private var systemRows: some View {
        VStack(spacing: 0) {
            menuActionRow(
                title: store.isRefreshing
                    ? L10n.string("Обновление…")
                    : L10n.string("Обновить"),
                systemImage: "arrow.clockwise",
                shortcut: "⌘ R"
            ) {
                store.refreshRealData()
            }
            .disabled(
                store.isRefreshing
                    || store.isRefreshingServiceStatus
                    || store.isReadOnly
            )

            menuActionRow(
                title: L10n.string("Настройки…"),
                systemImage: "gearshape",
                shortcut: "⌘ ,",
                accessibilityID: "usage-settings-button"
            ) {
                showSettings()
            }

            menuActionRow(
                title: L10n.string("О Codex Usage Lens"),
                systemImage: "info.circle"
            ) {
                showAbout()
            }

            menuActionRow(
                title: L10n.string("Завершить"),
                systemImage: "xmark.square",
                shortcut: "⌘ Q"
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func menuActionRow(
        title: String,
        systemImage: String,
        trailingSystemImage: String? = nil,
        shortcut: String? = nil,
        accessibilityID: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12.5))
                    .frame(width: 17)
                Text(title)
                    .font(.system(size: 13.5))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                if let trailingSystemImage {
                    Image(systemName: trailingSystemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
        .accessibilityIdentifier(accessibilityID ?? "")
    }

    private var menuDivider: some View {
        Divider()
            .padding(.horizontal, 16)
    }

    private var rateLimitBucket: CodexRateLimitBucket? {
        store.rateLimits?.preferredBucket
    }

    private var primaryWindow: CodexRateLimitWindow? {
        rateLimitBucket?.primary
    }

    private var secondaryWindow: CodexRateLimitWindow? {
        rateLimitBucket?.secondary
    }

    private var weeklyWindow: CodexRateLimitWindow? {
        [primaryWindow, secondaryWindow]
            .compactMap { $0 }
            .max {
                ($0.windowDurationMins ?? 0)
                    < ($1.windowDurationMins ?? 0)
            }
    }

    private var weeklyRemainingPercent: Int {
        max(0, 100 - (weeklyWindow?.usedPercent ?? 0))
    }

    private func weeklyElapsedPercent(now: Date) -> Double? {
        guard
            let window = weeklyWindow,
            let minutes = window.windowDurationMins,
            let reset = window.resetDate
        else {
            return nil
        }
        let duration = TimeInterval(minutes * 60)
        let start = reset.addingTimeInterval(-duration)
        return min(
            100,
            max(0, now.timeIntervalSince(start) / duration * 100)
        )
    }

    private func weeklyDeficit(now: Date) -> Int? {
        guard
            let used = weeklyWindow?.usedPercent,
            let elapsed = weeklyElapsedPercent(now: now)
        else {
            return nil
        }
        return max(0, Int((Double(used) - elapsed).rounded()))
    }

    private func weeklyExpectedRemainingPercent(
        now: Date
    ) -> Double? {
        weeklyElapsedPercent(now: now).map {
            max(0, min(100, 100 - $0))
        }
    }

    private func weeklyRunOutText(now: Date) -> String? {
        guard
            let window = weeklyWindow,
            window.usedPercent > 0,
            let minutes = window.windowDurationMins,
            let reset = window.resetDate
        else {
            return nil
        }
        let duration = TimeInterval(minutes * 60)
        let start = reset.addingTimeInterval(-duration)
        let elapsed = max(0, now.timeIntervalSince(start))
        let remainingUsage = Double(max(0, 100 - window.usedPercent))
        let secondsToRunOut =
            elapsed * remainingUsage / Double(window.usedPercent)
        guard
            secondsToRunOut.isFinite,
            secondsToRunOut < max(0, reset.timeIntervalSince(now))
        else {
            return nil
        }
        return L10n.format(
            "menubar.weekly.runsOut",
            compactDuration(secondsToRunOut)
        )
    }

    private func weeklyResetText(now: Date) -> String {
        guard let reset = weeklyWindow?.resetDate else {
            return L10n.string("Сброс недоступен")
        }
        return L10n.format(
            "menubar.weekly.resets",
            compactDuration(reset.timeIntervalSince(now))
        )
    }

    private var resetCreditCount: Int {
        store.rateLimits?.rateLimitResetCredits?.availableCount ?? 0
    }

    private var nextResetCredit: CodexRateLimitResetCredit? {
        store.rateLimits?.rateLimitResetCredits?.credits?
            .filter { $0.status == "available" }
            .sorted {
                ($0.expiresAt ?? Int.max) < ($1.expiresAt ?? Int.max)
            }
            .first
    }

    private func resetCreditTiming(now: Date) -> String {
        let expirations = store.rateLimits?.rateLimitResetCredits?.credits?
            .filter { $0.status == "available" }
            .compactMap(\.expirationDate)
            .sorted()
            .prefix(2)
            .map { compactDuration($0.timeIntervalSince(now)) }
            ?? []
        if !expirations.isEmpty {
            return expirations.joined(separator: " · ")
        }
        if let reset = weeklyWindow?.resetDate {
            return compactDuration(reset.timeIntervalSince(now))
        }
        return "—"
    }

    private var creditsProgress: Double {
        if rateLimitBucket?.credits?.unlimited == true {
            return 1
        }
        if let remaining = rateLimitBucket?.individualLimit?.remainingPercent {
            return Double(remaining) / 100
        }
        return rateLimitBucket?.credits?.hasCredits == true ? 1 : 0
    }

    private var creditsRemainingText: String {
        if rateLimitBucket?.credits?.unlimited == true {
            return L10n.string("Без ограничений")
        }
        if let balance = rateLimitBucket?.credits?.balance {
            return L10n.format("menubar.credits.left", balance)
        }
        if
            let limit = rateLimitBucket?.individualLimit,
            limit.remainingPercent > 0
        {
            return L10n.format(
                "menubar.credits.percentLeft",
                limit.remainingPercent
            )
        }
        return L10n.string("0 осталось")
    }

    private var creditsLimitText: String {
        if let limit = rateLimitBucket?.individualLimit?.limit {
            return limit
        }
        return rateLimitBucket?.credits?.hasCredits == true
            ? L10n.string("Баланс аккаунта")
            : L10n.string("Дополнительные кредиты")
    }

    private var chartPoints: [MenuChartPoint] {
        let snapshot = store.dashboardSnapshot(days: 30)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let totals = Dictionary(
            uniqueKeysWithValues: snapshot.dailyTotals.map {
                (calendar.startOfDay(for: $0.date), $0.summary)
            }
        )
        return (0..<30).compactMap { offset in
            guard
                let date = calendar.date(
                    byAdding: .day,
                    value: offset - 29,
                    to: today
                )
            else {
                return nil
            }
            return MenuChartPoint(
                date: date,
                tokens: totals[date]?.totalTokens ?? 0,
                cost: totals[date]?.apiEquivalentCost ?? 0
            )
        }
    }

    private var maximumDailyCost: Double {
        chartPoints.map(\.cost).max() ?? 0
    }

    private var topModelName: String {
        store.dashboardSnapshot(days: 30).modelRows.first.map {
            UsageFormatting.modelDisplayName($0.model)
        } ?? "—"
    }

    private var accountTitle: String {
        if
            CommandLine.arguments.contains("--preview-menu")
                || CommandLine.arguments.contains("--redact-account")
        {
            return "user@account"
        }
        return store.accountProfile?.email
            ?? L10n.string("Аккаунт Codex")
    }

    private var planTitle: String {
        CodexPlanPresentation.displayName(
            profilePlanType: store.accountProfile?.planType,
            rateLimitPlanType: rateLimitBucket?.planType
        )
    }

    private func updatedText(now: Date) -> String {
        let date = [
            store.accountUsage?.fetchedAt,
            store.rateLimits?.fetchedAt,
        ]
        .compactMap { $0 }
        .max()
        guard let date else {
            return store.isSyncingAccount
                ? L10n.string("Обновление…")
                : L10n.string("Ожидает обновления")
        }
        return L10n.format(
            "menubar.updated",
            compactAge(now.timeIntervalSince(date))
        )
    }

    private func serviceStatusText(now: Date) -> String {
        if let status = store.serviceStatus {
            return "\(status.description) — "
                + L10n.format(
                    "menubar.updated",
                    compactAge(now.timeIntervalSince(status.updatedAt))
                )
        }
        if store.isRefreshingServiceStatus {
            return L10n.string("Проверяется статус OpenAI…")
        }
        return store.serviceStatusError
            ?? L10n.string("Статус OpenAI недоступен")
    }

    private var serviceStatusTint: Color {
        switch store.serviceStatus?.indicator {
        case "none":
            .codexAccent
        case "minor":
            .usageOrange
        case "major", "critical":
            .usageRed
        default:
            .secondary
        }
    }

    private func windowTitle(
        for window: CodexRateLimitWindow?
    ) -> String {
        guard let minutes = window?.windowDurationMins else {
            return L10n.string("Основное окно")
        }
        if minutes >= 6 * 24 * 60 {
            return L10n.string("Недельное окно")
        }
        if minutes >= 60 {
            return L10n.format(
                "menubar.window.hours",
                max(1, minutes / 60)
            )
        }
        return L10n.format("menubar.window.minutes", minutes)
    }

    private func resetText(
        for window: CodexRateLimitWindow,
        now: Date
    ) -> String {
        guard let date = window.resetDate else {
            return L10n.string("без времени сброса")
        }
        return compactDuration(date.timeIntervalSince(now))
    }

    private func compactAge(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        if value < 60 {
            return L10n.string("только что")
        }
        if value < 3_600 {
            return L10n.format(
                "menubar.minutesAgo",
                max(1, Int(value / 60))
            )
        }
        if value < 86_400 {
            return L10n.format(
                "menubar.hoursAgo",
                max(1, Int(value / 3_600))
            )
        }
        return L10n.format(
            "menubar.daysAgo",
            max(1, Int(value / 86_400))
        )
    }

    private func compactDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes % (24 * 60) / 60
        let minutes = totalMinutes % 60

        let dayUnit = L10n.language == .russian
            || L10n.language == .ukrainian ? "д" : "d"
        let hourUnit = L10n.language == .russian
            || L10n.language == .ukrainian ? "ч" : "h"
        let minuteUnit = L10n.language == .russian
            || L10n.language == .ukrainian ? "м" : "m"

        if days > 0 {
            return "\(days)\(dayUnit) \(hours)\(hourUnit)"
        }
        if hours > 0 {
            return "\(hours)\(hourUnit) \(minutes)\(minuteUnit)"
        }
        return "\(minutes)\(minuteUnit)"
    }

    private func toggle(_ section: ExpandedSection) {
        withAnimation(.easeOut(duration: 0.16)) {
            expandedSection = expandedSection == section ? nil : section
        }
    }

    private func beginAccountLogin() {
        loginCoordinator.start { result in
            switch result {
            case .success:
                store.alertMessage =
                    L10n.string("Аккаунт подключён. Данные обновляются.")
                store.refreshRealData()
            case .failure(let error):
                store.alertMessage = error.localizedDescription
            }
        }
    }

    private func open(_ url: URL) {
        guard NSWorkspace.shared.open(url) else {
            store.alertMessage =
                L10n.string("Не удалось открыть ссылку в браузере.")
            return
        }
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

    private func showAbout() {
        if let onShowAbout {
            onShowAbout()
        } else {
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

enum CodexPlanPresentation {
    static func displayName(
        profilePlanType: String?,
        rateLimitPlanType: String?
    ) -> String {
        let raw = rateLimitPlanType ?? profilePlanType
        return switch raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
        case "free":
            "Free"
        case "go":
            "Go"
        case "plus":
            "Plus"
        case "prolite":
            "Pro 5x"
        case "pro":
            "Pro 20x"
        case "team":
            "Team"
        case "business", "self_serve_business_usage_based":
            "Business"
        case "enterprise", "enterprise_cbp_usage_based":
            "Enterprise"
        case "edu":
            "Edu"
        case .some:
            L10n.string("Неизвестный план")
        case nil:
            "—"
        }
    }
}

private struct MenuChartPoint: Identifiable {
    let date: Date
    let tokens: Int
    let cost: Double

    var id: Date { date }
}

private struct MenuUsageChart: View {
    let points: [MenuChartPoint]

    var body: some View {
        Chart(points) { point in
            BarMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Tokens", point.tokens)
            )
            .foregroundStyle(Color.codexAccent.opacity(0.68))
            .cornerRadius(1.5)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot
                .background(Color.clear)
        }
        .accessibilityLabel(L10n.string("Использование за 30 дней"))
    }
}

private struct WeeklyUsageBar: View {
    let remainingPercent: Int
    let expectedRemainingPercent: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            let remainingWidth =
                width * Double(max(0, min(100, remainingPercent))) / 100

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.07))

                Capsule()
                    .fill(Color.codexAccent.opacity(0.84))
                    .frame(width: remainingWidth)

                ForEach([0.2, 0.5], id: \.self) { marker in
                    Rectangle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 2)
                        .offset(x: max(0, width * marker - 1))
                }

                if let expectedRemainingPercent {
                    Rectangle()
                        .fill(Color.usageRed)
                        .frame(width: 2, height: proxy.size.height + 2)
                        .offset(
                            x: max(
                                0,
                                min(
                                    width - 2,
                                    width
                                        * expectedRemainingPercent
                                        / 100
                                )
                            )
                        )
                }
            }
            .clipShape(Capsule())
        }
        .accessibilityLabel(L10n.string("Остаток недельного лимита"))
        .accessibilityValue("\(remainingPercent)%")
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Color.primary.opacity(0.09)
                            : Color.clear
                    )
            )
    }
}
