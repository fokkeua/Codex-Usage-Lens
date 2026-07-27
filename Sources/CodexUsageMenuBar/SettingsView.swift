import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var languageController: AppLanguageController
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @State private var showsImporter = false
    @State private var showsClearUsageConfirmation = false
    @State private var pendingConfirmation: SettingsConfirmation?
    @State private var otelState: OTelSettingsState =
        .unavailable(L10n.string("otel.checking"))

    var body: some View {
        VStack(spacing: 0) {
            if let message = store.persistenceReadOnlyMessage {
                PersistenceReadOnlyBanner(message: message)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            TabView {
                dataSettings
                    .tabItem {
                        Label("Данные", systemImage: "externaldrive")
                    }
                pricingSettings
                    .tabItem {
                        Label("Цены", systemImage: "dollarsign.circle")
                    }
                aboutSettings
                    .tabItem {
                        Label("О приложении", systemImage: "info.circle")
                    }
            }
        }
        .frame(
            minWidth: SettingsLayout.minimumWindowSize.width,
            minHeight: SettingsLayout.minimumWindowSize.height
        )
        .confirmationDialog(
            pendingConfirmation?.title ?? "",
            isPresented: pendingConfirmationIsPresented,
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { confirmation in
            Button(
                confirmation.actionTitle,
                role: confirmation.isDestructive ? .destructive : nil
            ) {
                perform(confirmation)
            }
            .disabled(!store.canMutatePersistedState)
            Button("Отмена", role: .cancel) {
                pendingConfirmation = nil
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
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
                : L10n.string("Источник данных"),
            isPresented: Binding(
                get: { store.alertMessage != nil },
                set: { if !$0 { store.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(L10n.presentation(store.alertMessage ?? ""))
        }
        .task {
            launchAtLogin.refresh()
            await refreshOTelState()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                launchAtLogin.refresh()
            }
        }
    }

    private var dataSettings: some View {
        Form {
            Section("Приложение") {
                Picker(
                    "Язык приложения",
                    selection: $languageController.selection
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName)
                            .tag(language)
                    }
                }
                .pickerStyle(.menu)
                .help("Интерфейс и форматы изменяются сразу")

                Toggle(
                    isOn: Binding(
                        get: { launchAtLogin.state.isRequested },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                ) {
                    Label(
                        L10n.string("settings.launchAtLogin.title"),
                        systemImage: "power"
                    )
                }
                .disabled(
                    launchAtLogin.isChanging
                        || launchAtLogin.state == .unavailable
                )
                .accessibilityHint(
                    L10n.string("settings.launchAtLogin.help")
                )

                launchAtLoginStatus
            }

            Section("Реальные данные Codex") {
                LabeledContent {
                    Text(store.sourceKind.title)
                } label: {
                    Label("Источник", systemImage: "cylinder")
                }
                LabeledContent {
                    Text(L10n.presentation(store.sourceSubtitle))
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Состояние")
                }
                if let note = store.lastImportNote {
                    LabeledContent("Последнее действие") {
                        Text(L10n.presentation(note))
                    }
                }

                refreshActions

                LabeledContent("Аккаунт / app-server") {
                    statusText(
                        accountSyncStatusText,
                        active: store.isSyncingAccount
                    )
                }
                LabeledContent("Детализация / sessions") {
                    statusText(store.localScanStatus, active: store.isScanningLocal)
                }

                Text(
                    L10n.string("settings.data.explanation")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Live OpenTelemetry") {
                LabeledContent("Локальный receiver") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(store.isLiveReceiverRunning ? Color.usageTeal : Color.usageOrange)
                            .frame(width: 7, height: 7)
                        Text(L10n.presentation(store.liveReceiverStatus))
                    }
                }

                otelConfigurationActions(state: otelState)

                Text(
                    L10n.string("settings.otel.explanation")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Импорт и резервные данные") {
                importAndBackupActions
            }

            Section("Поддерживаемая схема импорта") {
                Text(
                    L10n.string("settings.import.schema")
                )
                .foregroundStyle(.secondary)

                Text(
                    L10n.string("settings.import.otelSchema")
                )
                .foregroundStyle(.secondary)
            }

            Section("Приватность") {
                Label(
                    L10n.string("settings.privacy.local"),
                    systemImage: "lock.shield"
                )
                Label(
                    L10n.string("settings.privacy.sessions"),
                    systemImage: "hand.raised"
                )
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var launchAtLoginStatus: some View {
        if let errorDescription = launchAtLogin.errorDescription {
            Label {
                Text(
                    L10n.format(
                        "settings.launchAtLogin.error",
                        errorDescription
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(Color.usageOrange)
        } else {
            switch launchAtLogin.state {
            case .requiresApproval:
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        launchAtLoginApprovalNote
                        openLoginItemsSettingsButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        launchAtLoginApprovalNote
                        openLoginItemsSettingsButton
                    }
                }
            case .unavailable:
                Label {
                    Text(
                        L10n.string(
                            "settings.launchAtLogin.unavailable"
                        )
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(Color.usageOrange)
            case .disabled, .enabled:
                Text(L10n.string("settings.launchAtLogin.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var launchAtLoginApprovalNote: some View {
        Text(L10n.string("settings.launchAtLogin.requiresApproval"))
            .font(.caption)
            .foregroundStyle(Color.usageOrange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var openLoginItemsSettingsButton: some View {
        Button(L10n.string("settings.launchAtLogin.openSettings")) {
            launchAtLogin.openSystemSettings()
        }
        .buttonStyle(.link)
    }

    private var refreshActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                refreshAllButton
                syncAccountButton
                scanHistoryButton
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                refreshAllButton
                syncAccountButton
                scanHistoryButton
            }
        }
    }

    private var refreshAllButton: some View {
        Button {
            store.refreshRealData()
        } label: {
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Label("Обновить всё", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isRefreshing || !store.canMutatePersistedState)
        .accessibilityLabel("Обновить все источники данных")
        .accessibilityValue(
            store.isRefreshing
                ? L10n.string("Обновление выполняется")
                : L10n.string("Готово")
        )
    }

    private var syncAccountButton: some View {
        Button("Официальный итог") {
            store.syncAccountUsage()
        }
        .disabled(
            store.isSyncingAccount || !store.canMutatePersistedState
        )
        .accessibilityHint("Запрашивает суммарные данные через Codex app-server")
    }

    private var scanHistoryButton: some View {
        Button("Сканировать историю") {
            store.scanLocalHistory()
        }
        .disabled(
            store.isScanningLocal || !store.canMutatePersistedState
        )
        .accessibilityHint("Сканирует локальные session-файлы Codex")
    }

    private func otelConfigurationActions(state: OTelSettingsState) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                otelConfigurationButton(state: state)
                otelConfigurationNote(state)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                otelConfigurationButton(state: state)
                otelConfigurationNote(state)
            }
        }
    }

    private func otelConfigurationButton(state: OTelSettingsState) -> some View {
        Button(state.buttonTitle) {
            guard let action = state.action else { return }
            pendingConfirmation = .otel(action)
        }
        .disabled(
            state.action == nil || !store.canMutatePersistedState
        )
        .accessibilityHint(
            state.action == nil
                ? state.note
                : L10n.string(
                    "settings.otel.confirmationHint"
                )
        )
    }

    private func otelConfigurationNote(_ state: OTelSettingsState) -> some View {
        Text(state.note)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var importAndBackupActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                importButton
                demoButton
                Spacer(minLength: 0)
                clearUsageButton
            }

            VStack(alignment: .leading, spacing: 8) {
                importButton
                demoButton
                clearUsageButton
            }
        }
    }

    private var importButton: some View {
        Button("Импортировать JSON / JSONL / CSV…") {
            showsImporter = true
        }
        .disabled(!store.canMutatePersistedState)
    }

    private var demoButton: some View {
        Button("Загрузить демо") {
            store.loadDemoData()
        }
        .disabled(!store.canMutatePersistedState)
    }

    private var clearUsageButton: some View {
        Button("Очистить", role: .destructive) {
            showsClearUsageConfirmation = true
        }
        .disabled(
            store.records.isEmpty || !store.canMutatePersistedState
        )
        .accessibilityLabel("Очистить usage-данные")
        .accessibilityHint("Открывает подтверждение необратимого удаления")
        .alert(
            "Очистить usage-данные?",
            isPresented: $showsClearUsageConfirmation
        ) {
            Button("Отмена", role: .cancel) {}
            Button("Очистить данные", role: .destructive) {
                store.clearUsageData()
            }
            .disabled(!store.canMutatePersistedState)
        } message: {
            Text(
                L10n.format(
                    "settings.clearUsage.message",
                    store.records.count
                )
            )
        }
    }

    private var pricingSettings: some View {
        ScrollView(SettingsLayout.pricingScrollAxes) {
            pricingSettingsContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var pricingSettingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            pricingTitleAndActions

            HStack(alignment: .center, spacing: 8) {
                if store.isUpdatingPrices {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Color.usageBlue)
                        .accessibilityHidden(true)
                }

                Text(priceUpdateStatusText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Статус обновления цен")
            .accessibilityValue(
                priceUpdateStatusText
            )

            let warningIndex = PricePatternWarningIndex(prices: store.prices)
            if store.prices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tag.slash")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("Таблица цен пуста")
                        .font(.headline)
                    Text(
                        "Добавьте модель вручную или восстановите встроенные цены."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 132)
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            Color.primary.opacity(0.08),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                )
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(store.prices) { price in
                        priceCard(
                            price,
                            warning: warningIndex.warning(for: price.id)
                        )
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    addPriceButton
                    Spacer(minLength: 8)
                    pricingPersistenceStatus
                }

                VStack(alignment: .leading, spacing: 10) {
                    addPriceButton
                    pricingPersistenceStatus
                }
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.usageOrange)
                    .accessibilityHidden(true)
            Text(
                L10n.string("settings.pricing.disclaimer")
            )
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.usageOrange.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.usageOrange.opacity(0.18))
            )
        }
    }

    private var addPriceButton: some View {
        Button {
            store.addPrice()
        } label: {
            Label("Добавить модель", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .disabled(!store.canEditPrices)
    }

    private var pricingPersistenceStatus: some View {
        Label {
            Text(
                store.canPersist
                    ? "Изменения сохраняются автоматически"
                    : "Редактирование отключено в режиме только для чтения"
            )
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: store.canPersist ? "checkmark.circle" : "lock")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func priceCard(
        _ price: ModelPrice,
        warning: PricePatternWarning?
    ) -> some View {
        let modelName = PriceInputPolicy.accessibilityModelName(
            price.modelPattern
        )

        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 10) {
                Label("Модель / шаблон", systemImage: "cpu")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button(role: .destructive) {
                    pendingConfirmation = .removePrice(
                        id: price.id,
                        modelName: modelName
                    )
                } label: {
                    Label("Удалить", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .frame(width: 30, height: 30)
                .background(
                    Color.red.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
                .disabled(!store.canEditPrices)
                .accessibilityLabel(
                    L10n.format(
                        "settings.price.delete",
                        modelName
                    )
                )
                .accessibilityHint(
                    "Открывает подтверждение удаления строки цены"
                )
                .help(
                    L10n.format(
                        "settings.price.delete",
                        modelName
                    )
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                TextField(
                    "Например, gpt-5*",
                    text: pricePatternBinding(id: price.id)
                )
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .disabled(!store.canEditPrices)
                .accessibilityLabel("Модель или шаблон цены")
                .accessibilityHint(
                    "Звёздочка в конце означает префикс модели"
                )

                if let warning {
                    pricePatternWarning(warning)
                }
            }

            Divider()

            priceRateFields(price, modelName: modelName)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    warning == nil
                        ? Color.primary.opacity(0.08)
                        : Color.usageOrange.opacity(0.34)
                )
        )
    }

    private func priceRateFields(
        _ price: ModelPrice,
        modelName: String
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                priceField(
                    priceValueBinding(
                        id: price.id,
                        keyPath: \.inputPerMillion
                    ),
                    title: "Вход",
                    icon: "arrow.down",
                    tint: .usageBlue,
                    modelName: modelName
                )
                priceField(
                    priceValueBinding(
                        id: price.id,
                        keyPath: \.cachedInputPerMillion
                    ),
                    title: "Кэш",
                    icon: "bolt.fill",
                    tint: .usageTeal,
                    modelName: modelName
                )
                priceField(
                    priceValueBinding(
                        id: price.id,
                        keyPath: \.cacheWritePerMillion
                    ),
                    title: "Запись кэша",
                    icon: "square.and.arrow.down",
                    tint: .usageOrange,
                    modelName: modelName
                )
                priceField(
                    priceValueBinding(
                        id: price.id,
                        keyPath: \.outputPerMillion
                    ),
                    title: "Выход",
                    icon: "arrow.up",
                    tint: .usagePurple,
                    modelName: modelName
                )
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .topLeading),
                    GridItem(.flexible(), alignment: .topLeading),
                ],
                alignment: .leading,
                spacing: 11
            ) {
                priceField(
                    priceValueBinding(
                        id: price.id,
                        keyPath: \.inputPerMillion
                    ),
                    title: "Вход",
                    icon: "arrow.down",
                    tint: .usageBlue,
                    modelName: modelName
                )
                priceField(
                    priceValueBinding(
                        id: price.id,
                        keyPath: \.cachedInputPerMillion
                    ),
                    title: "Кэш",
                    icon: "bolt.fill",
                    tint: .usageTeal,
                    modelName: modelName
                )
                priceField(
                    priceValueBinding(
                        id: price.id,
                        keyPath: \.cacheWritePerMillion
                    ),
                    title: "Запись кэша",
                    icon: "square.and.arrow.down",
                    tint: .usageOrange,
                    modelName: modelName
                )
                priceField(
                    priceValueBinding(
                        id: price.id,
                        keyPath: \.outputPerMillion
                    ),
                    title: "Выход",
                    icon: "arrow.up",
                    tint: .usagePurple,
                    modelName: modelName
                )
            }
        }
    }

    private var pricingTitleAndActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                pricingTitle
                Spacer(minLength: 8)
                pricingActions
            }

            VStack(alignment: .leading, spacing: 12) {
                pricingTitle
                pricingActions
            }
        }
    }

    private var pricingTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Публичные API-цены")
                .font(.title2.bold())
            Text(
                L10n.string("settings.pricing.subtitle")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pricingActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                updatePricesButton
                officialPricingLink
                resetPricesButton
            }

            VStack(alignment: .leading, spacing: 8) {
                updatePricesButton
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        officialPricingLink
                        resetPricesButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        officialPricingLink
                        resetPricesButton
                    }
                }
            }
        }
    }

    private var officialPricingLink: some View {
        Link(destination: Pricing.officialPricingURL) {
            Label("Источник", systemImage: "arrow.up.right.square")
        }
    }

    private var updatePricesButton: some View {
        Button {
            store.updateOfficialPrices()
        } label: {
            if store.isUpdatingPrices {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
            store.isUpdatingPrices || !store.canMutatePersistedState
        )
        .accessibilityLabel("Обновить цены с OpenAI")
        .accessibilityValue(
            store.isUpdatingPrices
                ? L10n.string("Обновление выполняется")
                : L10n.string("Готово")
        )
    }

    private var resetPricesButton: some View {
        Button("Сбросить", role: .destructive) {
            pendingConfirmation = .resetPrices(count: store.prices.count)
        }
        .disabled(!store.canMutatePersistedState)
        .accessibilityHint(
            "Открывает подтверждение восстановления встроенной таблицы цен"
        )
    }

    private func pricePatternWarning(
        _ warning: PricePatternWarning
    ) -> some View {
        Label {
            Text(warning.message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption2)
        .foregroundStyle(Color.usageOrange)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(warning.accessibilityLabel)
        .accessibilityValue(warning.accessibilityValue)
    }

    private func priceField(
        _ value: Binding<Double>,
        title: String,
        icon: String,
        tint: Color,
        modelName: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(L10n.string(title), systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            TextField(
                L10n.string(title),
                value: validatedPriceBinding(value),
                format: .number.precision(.fractionLength(0...4))
            )
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .disabled(!store.canEditPrices)
            .accessibilityLabel(
                L10n.format(
                    "settings.price.field",
                    L10n.string(title),
                    modelName
                )
            )
            .accessibilityHint(
                L10n.format(
                    "settings.price.range",
                    UsageFormatting.fullTokens(
                        Int(UsageLimits.maximumPricePerMillion)
                    )
                )
            )
            .onAppear {
                guard store.canEditPrices else { return }
                let sanitized = PriceInputPolicy.sanitized(value.wrappedValue)
                if !PriceInputPolicy.isAccepted(value.wrappedValue) {
                    value.wrappedValue = sanitized
                }
            }
        }
        .frame(minWidth: 104, maxWidth: .infinity, alignment: .leading)
    }

    private func pricePatternBinding(id: UUID) -> Binding<String> {
        Binding(
            get: {
                store.prices.first(where: { $0.id == id })?.modelPattern ?? ""
            },
            set: { value in
                store.updatePricePattern(id: id, value: value)
            }
        )
    }

    private func priceValueBinding(
        id: UUID,
        keyPath: WritableKeyPath<ModelPrice, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                store.prices.first(where: { $0.id == id })?[
                    keyPath: keyPath
                ] ?? 0
            },
            set: { value in
                store.updatePriceValue(
                    id: id,
                    keyPath: keyPath,
                    value: value
                )
            }
        )
    }

    private func validatedPriceBinding(
        _ source: Binding<Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                PriceInputPolicy.sanitized(source.wrappedValue)
            },
            set: { proposedValue in
                source.wrappedValue = PriceInputPolicy.resolvedUpdate(
                    proposedValue,
                    current: source.wrappedValue
                )
            }
        )
    }

    private var aboutSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.usageBlue, .usagePurple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Codex Usage Lens")
                            .font(.title.bold())
                        Text("Локальное macOS-приложение • версия 1.2")
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Text(
                    L10n.string("settings.about.purpose")
                )

                GroupBox("Как получаются реальные числа") {
                    Text(
                        L10n.string("settings.about.realNumbers")
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        documentationLinks
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        documentationLinks
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var documentationLinks: some View {
        Link(
            "Документация Codex OTel",
            destination: URL(
                string: "https://learn.chatgpt.com/docs/config-file/config-advanced#observability-and-telemetry"
            )!
        )
        Link(
            "Сравнение API-цен",
            destination: Pricing.officialPricingURL
        )
    }

    private func statusText(_ text: String, active: Bool) -> some View {
        HStack(spacing: 7) {
            if active {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            Text(L10n.presentation(text))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.presentation(text))
    }

    private var accountSyncStatusText: String {
        if
            store.accountSyncStatus.hasPrefix("Последняя синхронизация "),
            let fetchedAt = store.accountUsage?.fetchedAt
        {
            return L10n.format(
                "status.lastSync",
                UsageFormatting.dateTime(fetchedAt)
            )
        }
        return L10n.presentation(store.accountSyncStatus)
    }

    private var priceUpdateStatusText: String {
        if
            (
                store.priceUpdateStatus.hasPrefix(
                    "Официальные цены актуальны • "
                )
                    || store.priceUpdateStatus.hasPrefix(
                        "Обновлено с developers.openai.com • "
                    )
            ),
            let lastUpdated = store.prices.compactMap(\.lastUpdated).max()
        {
            let key = store.priceUpdateStatus.hasPrefix(
                "Обновлено с developers.openai.com • "
            )
                ? "status.prices.updated"
                : "status.prices.current"
            return L10n.format(
                key,
                UsageFormatting.dateTime(lastUpdated)
            )
        }
        return L10n.presentation(store.priceUpdateStatus)
    }

    private var pendingConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    pendingConfirmation = nil
                }
            }
        )
    }

    private func perform(_ confirmation: SettingsConfirmation) {
        pendingConfirmation = nil

        switch confirmation {
        case .otel(let action):
            let currentState = OTelSettingsState.current()
            guard currentState.action == action else {
                store.alertMessage =
                    L10n.format(
                        "settings.otel.stateChanged",
                        currentState.note
                    )
                return
            }
            store.installLiveOTelConfiguration()
            Task {
                await refreshOTelState()
            }
        case .removePrice(let id, _):
            store.removePrice(id: id)
        case .resetPrices:
            store.resetPrices()
        }
    }

    private func refreshOTelState() async {
        let resolved = await Task.detached(priority: .utility) {
            OTelSettingsState.current()
        }.value
        guard !Task.isCancelled else { return }
        otelState = resolved
    }
}

enum SettingsLayout {
    static let minimumWindowSize = CGSize(width: 620, height: 460)
    static let preferredWindowSize = CGSize(width: 820, height: 620)
    static let pricingScrollAxes: Axis.Set = .vertical
}

enum PriceInputPolicy {
    static func isAccepted(_ value: Double) -> Bool {
        value.isFinite
            && value >= 0
            && value <= UsageLimits.maximumPricePerMillion
    }

    static func sanitized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(0, value), UsageLimits.maximumPricePerMillion)
    }

    static func resolvedUpdate(_ proposed: Double, current: Double) -> Double {
        guard isAccepted(proposed) else {
            return sanitized(current)
        }
        return proposed
    }

    static func accessibilityModelName(_ pattern: String) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? L10n.string("price.warning.unnamedModel")
            : trimmed
    }
}

enum PricePatternWarning: Equatable {
    case empty
    case duplicate(isFirst: Bool, count: Int)

    var message: String {
        switch self {
        case .empty:
            L10n.string("price.warning.empty")
        case .duplicate(true, let count):
            L10n.format("price.warning.duplicateFirst", count)
        case .duplicate(false, _):
            L10n.string("price.warning.duplicate")
        }
    }

    var accessibilityLabel: String {
        L10n.string("price.warning.accessibility")
    }

    var accessibilityValue: String {
        message
    }
}

enum PricePatternWarningPolicy {
    static func normalized(_ pattern: String) -> String {
        pattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }

    static func warning(
        for id: UUID,
        in prices: [ModelPrice]
    ) -> PricePatternWarning? {
        guard let rowIndex = prices.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let pattern = normalized(prices[rowIndex].modelPattern)
        guard !pattern.isEmpty else {
            return .empty
        }

        let duplicateIndices = prices.indices.filter {
            normalized(prices[$0].modelPattern) == pattern
        }
        guard duplicateIndices.count > 1 else {
            return nil
        }

        return .duplicate(
            isFirst: duplicateIndices.first == rowIndex,
            count: duplicateIndices.count
        )
    }
}

struct PricePatternWarningIndex {
    private let warningsByID: [UUID: PricePatternWarning]

    init(prices: [ModelPrice]) {
        var idsByPattern: [String: [UUID]] = [:]
        idsByPattern.reserveCapacity(prices.count)
        var warnings: [UUID: PricePatternWarning] = [:]
        warnings.reserveCapacity(prices.count)

        for price in prices {
            let pattern = PricePatternWarningPolicy.normalized(
                price.modelPattern
            )
            if pattern.isEmpty {
                warnings[price.id] = .empty
            } else {
                idsByPattern[pattern, default: []].append(price.id)
            }
        }
        for ids in idsByPattern.values where ids.count > 1 {
            for (index, id) in ids.enumerated() {
                warnings[id] = .duplicate(
                    isFirst: index == 0,
                    count: ids.count
                )
            }
        }
        warningsByID = warnings
    }

    func warning(for id: UUID) -> PricePatternWarning? {
        warningsByID[id]
    }
}

enum OTelConfigurationAction: String, Equatable {
    case install

    var confirmationTitle: String {
        L10n.string("otel.install.confirmation.title")
    }

    var confirmationButtonTitle: String {
        L10n.string("otel.install.confirmation.action")
    }

    var confirmationMessage: String {
        L10n.string("otel.install.confirmation.message")
    }
}

enum OTelSettingsState: Equatable, Sendable {
    case install
    case managedLegacy
    case existing
    case unavailable(String)

    static func current(
        at url: URL = OTelConfigManager.configURL
    ) -> OTelSettingsState {
        do {
            let status = try OTelConfigManager.configurationStatus(at: url)
            return resolve(
                status: status,
                canInstall: OTelConfigManager.canInstall(at: url)
            )
        } catch {
            return .unavailable(
                L10n.format(
                    "otel.check.failed",
                    error.localizedDescription
                )
            )
        }
    }

    static func resolve(
        status: OTelConfigurationStatus,
        canInstall: Bool
    ) -> OTelSettingsState {
        switch status {
        case .existing:
            return .existing
        case .absent:
            return canInstall
                ? .install
                : .unavailable(
                    L10n.string("otel.check.changed")
                )
        case .managedLegacy:
            return .managedLegacy
        }
    }

    var action: OTelConfigurationAction? {
        switch self {
        case .install:
            .install
        case .managedLegacy, .existing, .unavailable:
            nil
        }
    }

    var buttonTitle: String {
        switch self {
        case .install:
            L10n.string("otel.install.button")
        case .managedLegacy:
            L10n.string("otel.legacy.button")
        case .existing:
            L10n.string("otel.existing.button")
        case .unavailable:
            L10n.string("otel.unavailable.button")
        }
    }

    var note: String {
        switch self {
        case .install:
            L10n.string("otel.install.note")
        case .managedLegacy:
            L10n.string("otel.legacy.note")
        case .existing:
            L10n.string("otel.existing.note")
        case .unavailable(let message):
            message
        }
    }
}

enum SettingsConfirmation: Equatable {
    case otel(OTelConfigurationAction)
    case removePrice(id: UUID, modelName: String)
    case resetPrices(count: Int)

    var title: String {
        switch self {
        case .otel(let action):
            action.confirmationTitle
        case .removePrice:
            L10n.string("settings.removePrice.title")
        case .resetPrices:
            L10n.string("settings.resetPrices.title")
        }
    }

    var actionTitle: String {
        switch self {
        case .otel(let action):
            action.confirmationButtonTitle
        case .removePrice:
            L10n.string("settings.removePrice.action")
        case .resetPrices:
            L10n.string("settings.resetPrices.action")
        }
    }

    var message: String {
        switch self {
        case .otel(let action):
            action.confirmationMessage
        case .removePrice(_, let modelName):
            L10n.format("settings.removePrice.message", modelName)
        case .resetPrices(let count):
            L10n.format("settings.resetPrices.message", count)
        }
    }

    var isDestructive: Bool {
        switch self {
        case .otel:
            false
        case .removePrice, .resetPrices:
            true
        }
    }
}
