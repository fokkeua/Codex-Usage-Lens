import Combine
import Darwin
import Foundation

enum UsageStateLimits {
    static let maximumPrices = 4_096
    static let maximumKnownModels = 100
    static let maximumDailyUsageBuckets = 10_000
}

private enum PersistenceMutationRejection: Sendable {
    case temporarilyUnavailable
    case insufficientStorage
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var records: [UsageRecord] = [] {
        didSet {
            guard !isRevertingRejectedMutation else { return }
            if
                hasCompletedInitialization,
                isReadOnly || persistenceCandidateValidationInFlight,
                !isApplyingPersistedMutation
            {
                isRevertingRejectedMutation = true
                records = oldValue
                isRevertingRejectedMutation = false
                reportRejectedDirectMutation()
                return
            }
            recordSignatures = nil
            invalidateUsageCaches()
            noteExternalPersistedMutation()
        }
    }
    @Published var prices: [ModelPrice] = [] {
        didSet {
            guard !isRevertingRejectedMutation else { return }
            if
                hasCompletedInitialization,
                isReadOnly
                    || isUpdatingPrices
                    || persistenceCandidateValidationInFlight,
                !isApplyingPersistedMutation
            {
                isRevertingRejectedMutation = true
                prices = oldValue
                isRevertingRejectedMutation = false
                reportRejectedDirectMutation()
                return
            }
            if hasCompletedInitialization, !isApplyingPersistedMutation {
                priceOperationGeneration &+= 1
            }
            compiledPricingCatalog = nil
            invalidateUsageCaches()
            noteExternalPersistedMutation()
        }
    }
    @Published var sourceKind: UsageSourceKind = .demo {
        didSet {
            guard !isRevertingRejectedMutation else { return }
            if
                hasCompletedInitialization,
                isReadOnly || persistenceCandidateValidationInFlight,
                !isApplyingPersistedMutation
            {
                isRevertingRejectedMutation = true
                sourceKind = oldValue
                isRevertingRejectedMutation = false
                reportRejectedDirectMutation()
                return
            }
            noteExternalPersistedMutation()
        }
    }
    @Published var importedFileName: String? {
        didSet {
            guard !isRevertingRejectedMutation else { return }
            if
                hasCompletedInitialization,
                isReadOnly || persistenceCandidateValidationInFlight,
                !isApplyingPersistedMutation
            {
                isRevertingRejectedMutation = true
                importedFileName = oldValue
                isRevertingRejectedMutation = false
                reportRejectedDirectMutation()
                return
            }
            noteExternalPersistedMutation()
        }
    }
    @Published var lastImportNote: String?
    @Published var alertMessage: String?

    @Published var accountUsage: AccountUsageSnapshot? {
        didSet {
            guard !isRevertingRejectedMutation else { return }
            if
                hasCompletedInitialization,
                isReadOnly || persistenceCandidateValidationInFlight,
                !isApplyingPersistedMutation
            {
                isRevertingRejectedMutation = true
                accountUsage = oldValue
                isRevertingRejectedMutation = false
                reportRejectedDirectMutation()
                return
            }
            latestReconciliationCacheDayStart = nil
            noteExternalPersistedMutation()
        }
    }
    @Published private(set) var accountProfile: CodexAccountProfile?
    @Published private(set) var rateLimits: CodexRateLimitsSnapshot?
    @Published var knownModels: [CodexModelInfo] = [] {
        didSet {
            guard !isRevertingRejectedMutation else { return }
            if
                hasCompletedInitialization,
                isReadOnly || persistenceCandidateValidationInFlight,
                !isApplyingPersistedMutation
            {
                isRevertingRejectedMutation = true
                knownModels = oldValue
                isRevertingRejectedMutation = false
                reportRejectedDirectMutation()
                return
            }
            noteExternalPersistedMutation()
        }
    }
    @Published var accountSyncStatus = "Официальный итог ещё не запрошен"
    @Published var localScanStatus = "Локальная история ещё не просканирована"
    @Published var priceUpdateStatus = "Встроенная таблица официальных API-цен"
    @Published var liveReceiverStatus = "Live OTel запускается…"
    @Published var isSyncingAccount = false
    @Published var isScanningLocal = false
    @Published var isUpdatingPrices = false
    @Published var isLiveReceiverRunning = false
    @Published private(set) var serviceStatus: OpenAIServiceStatus?
    @Published private(set) var isRefreshingServiceStatus = false
    @Published private(set) var serviceStatusError: String?
    @Published private(set) var isConsumingResetCredit = false
    @Published private(set) var accountSyncHasError = false
    @Published private(set) var localScanHasError = false
    @Published private(set) var priceUpdateHasError = false

    private let storageDirectory: URL
    private let calendar: Calendar
    private let decoder: JSONDecoder
    private let persistenceLease: StatePersistenceLease?
    private let persistenceSetupError: StatePersistenceError?
    private let stateReadInterposition: (() -> Void)?
    private let stateDescriptorReadInterposition:
        (@Sendable () -> Void)?
    private let liveReceiver = OTelLiveReceiver()
    private let officialPricingFetcher:
        (@escaping @MainActor @Sendable (
            Result<[ModelPrice], Error>
        ) -> Void) -> Void
    private var hasCompletedInitialization = false
    private var isApplyingPersistedMutation = false
    private var isRevertingRejectedMutation = false
    private let persistenceQueue = DispatchQueue(
        label: "CodexUsageLens.Persistence",
        qos: .utility
    )
    private var subscriptions: Set<AnyCancellable> = []
    private var lastLocalScanAt: Date?
    private var dataSourceGeneration: UInt64 = 0
    private var persistenceGeneration: UInt64 = 0
    private var persistenceValidationGeneration: UInt64 = 0
    private var priceOperationGeneration: UInt64 = 0
    private var persistenceWriteInFlight = false
    private var pendingPersistedState: PersistedState?
    private var persistedStateSizeUpperBound = 0
    private var persistenceCandidateValidationInFlight = false
    private var validatingPersistedState: PersistedState?
    private var deferredPersistenceMutations:
        [@MainActor @Sendable () -> Void] = []
    private var recordSignatures: Set<UsageRecordSignature>?
    private var compiledPricingCatalog: CompiledPricingCatalog?
    // Runtime-only value observations. They intentionally contain no raw
    // thread/event identifiers and are not persisted, so restart begins a
    // fresh reconciliation session. Keeping dropped live values lets a later
    // out-of-order callback rematch the whole window instead of freezing an
    // arrival-order-dependent local/live pairing.
    private var crossSourceLiveObservations: Set<UsageRecordSignature> = []
    private var dashboardCache: [Int: DashboardCacheEntry] = [:]
    private var menuSummaryCache: MenuSummaryCache?
    private var latestReconciliationCacheDayStart: Date?
    private var cachedLatestReconciliation: (date: Date, value: UsageReconciliation)?

    nonisolated private static let maximumStateFileSize = 64 * 1024 * 1024
    private static let maximumDeferredPersistenceMutations = 1_024
    private static let crossSourceDedupeWindow: TimeInterval = 10

    private var stateURL: URL {
        storageDirectory.appendingPathComponent("state.json")
    }

    init(
        storageDirectory: URL? = nil,
        calendar: Calendar = .current,
        seedDemoIfNeeded: Bool = true,
        autoRefreshRealData: Bool = true,
        beforeStateLoad: (() -> Void)? = nil,
        stateReadInterposition: (() -> Void)? = nil,
        stateDescriptorReadInterposition:
            (@Sendable () -> Void)? = nil,
        officialPricingFetcher:
            @escaping (
                @escaping @MainActor @Sendable (
                    Result<[ModelPrice], Error>
                ) -> Void
            ) -> Void = OfficialPricingCatalog.fetch
    ) {
        self.calendar = calendar
        self.officialPricingFetcher = officialPricingFetcher
        self.stateReadInterposition = stateReadInterposition
        self.stateDescriptorReadInterposition =
            stateDescriptorReadInterposition
        self.storageDirectory = storageDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("CodexUsageMenuBar", isDirectory: true)

        let stateDecoder = JSONDecoder()
        stateDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self), seconds.isFinite {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            guard let date = DateParsing.parse(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO8601 date"
                )
            }
            return date
        }
        decoder = stateDecoder

        do {
            persistenceLease = try StatePersistenceLease.acquire(
                storageDirectory: self.storageDirectory
            )
            persistenceSetupError = nil
        } catch let error as StatePersistenceError {
            persistenceLease = nil
            persistenceSetupError = error
        } catch {
            persistenceLease = nil
            persistenceSetupError = .unavailable(error.localizedDescription)
        }

        let loadResult: StateLoadResult
        if
            let persistenceSetupError,
            !persistenceSetupError.allowsReadOnlyStateAccess
        {
            loadResult = .corrupt(
                reason: persistenceSetupError.localizedDescription,
                backupName: nil
            )
        } else {
            beforeStateLoad?()
            loadResult = loadState()
        }

        switch loadResult {
        case .loaded:
            break
        case .missing:
            prices = Pricing.defaultPrices
            if seedDemoIfNeeded, persistenceLease != nil {
                records = (try? DemoUsageSource(calendar: calendar).load()) ?? []
                sourceKind = .demo
                saveStateSynchronously()
            } else {
                sourceKind = .empty
            }
        case .corrupt(let reason, let backupName):
            prices = Pricing.defaultPrices
            sourceKind = .empty
            lastImportNote = "Повреждённое состояние не загружено"
            let backupDescription = backupName.map {
                " Резервная копия: \($0)."
            } ?? " Исходный state.json оставлен без изменений."
            alertMessage =
                "Локальное состояние повреждено или небезопасно: \(reason)."
                + backupDescription
        }
        if
            let persistenceSetupError,
            case .concurrentWriter = persistenceSetupError
        {
            alertMessage =
                "Локальные настройки открыты только для чтения: "
                + persistenceSetupError.localizedDescription
        }

        Publishers.CombineLatest(
            Publishers.CombineLatest4($records, $prices, $sourceKind, $importedFileName),
            Publishers.CombineLatest($accountUsage, $knownModels)
        )
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveStateAsynchronously()
            }
            .store(in: &subscriptions)

        persistedStateSizeUpperBound = Self.conservativeEncodedSize(
            of: persistedState()
        )
        hasCompletedInitialization = true
        guard autoRefreshRealData else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.canPersist {
                self.startLiveReceiver()
                self.refreshRealData()
            } else {
                self.refreshServiceStatus()
            }
        }
    }

    deinit {
        liveReceiver.stop()
    }

    var isRefreshing: Bool {
        isSyncingAccount
            || isScanningLocal
            || isUpdatingPrices
            || isConsumingResetCredit
    }

    var canPersist: Bool {
        persistenceLease != nil
    }

    var isReadOnly: Bool {
        !canPersist
    }

    var canMutatePersistedState: Bool {
        canPersist && !persistenceCandidateValidationInFlight
    }

    var persistenceReadOnlyMessage: String? {
        guard isReadOnly else { return nil }
        let reason = persistenceSetupError?.localizedDescription
            ?? "writer lease недоступен"
        return
            "Изменения в этом экземпляре отключены: \(reason)."
    }

    var canEditPrices: Bool {
        canMutatePersistedState
            && !isUpdatingPrices
    }

    var hasRefreshError: Bool {
        accountSyncHasError || localScanHasError || priceUpdateHasError
    }

    var sourceSubtitle: String {
        switch sourceKind {
        case .empty:
            lastImportNote ?? "Импортируйте файл или просканируйте историю"
        case .demo:
            "Локальный пример — не реальные данные"
        case .importedFile:
            importedFileName ?? "Импортированный файл"
        case .codexLocal:
            lastImportNote ?? "Детализация из ~/.codex/sessions"
        case .otelLive:
            "Live token events через localhost"
        }
    }

    var todaySummary: UsageSummary {
        menuSummaries().today
    }

    var weekSummary: UsageSummary {
        menuSummaries().week
    }

    var officialTodayTokens: Int? {
        accountUsage?.tokens(on: Date(), calendar: calendar)
    }

    var officialWeekTokens: Int? {
        guard
            let interval = calendar.dateInterval(of: .weekOfYear, for: Date()),
            let buckets = accountUsage?.dailyUsageBuckets
        else {
            return nil
        }
        return buckets.reduce(0) { total, bucket in
            guard let date = bucket.date, interval.contains(date) else { return total }
            return UsageLimits.saturatingAdd(total, bucket.tokens)
        }
    }

    func reconciliation(on date: Date = Date()) -> UsageReconciliation? {
        guard
            let official = accountUsage?.tokens(on: date, calendar: calendar),
            let interval = calendar.dateInterval(of: .day, for: date)
        else {
            return nil
        }
        return UsageReconciliation(
            officialTokens: official,
            detailedTokens: totalTokens(in: interval)
        )
    }

    var latestReconciliation: (date: Date, value: UsageReconciliation)? {
        latestReconciliation(asOf: Date())
    }

    func latestReconciliation(
        asOf now: Date
    ) -> (date: Date, value: UsageReconciliation)? {
        let startOfToday = calendar.startOfDay(for: now)
        if latestReconciliationCacheDayStart == startOfToday {
            return cachedLatestReconciliation
        }

        let completedDates = accountUsage?.dailyUsageBuckets?
            .compactMap(\.date)
            .filter { $0 < startOfToday } ?? []
        let result: (date: Date, value: UsageReconciliation)?
        if
            let date = completedDates.max(),
            let value = reconciliation(on: date)
        {
            result = (date, value)
        } else {
            result = nil
        }
        cachedLatestReconciliation = result
        latestReconciliationCacheDayStart = startOfToday
        return result
    }

    func refreshRealData() {
        refreshServiceStatus()
        guard requireWritablePersistence() else { return }
        syncAccountUsage()
        scanLocalHistory()
        updateOfficialPrices(force: false)
    }

    func refreshServiceStatus() {
        guard !isRefreshingServiceStatus else { return }
        isRefreshingServiceStatus = true
        serviceStatusError = nil
        OpenAIStatusClient.fetch { [weak self] result in
            guard let self else { return }
            self.isRefreshingServiceStatus = false
            switch result {
            case .success(let status):
                self.serviceStatus = status
            case .failure(let error):
                self.serviceStatusError = error.localizedDescription
            }
        }
    }

    func consumeRateLimitResetCredit(creditID: String? = nil) {
        guard requireWritablePersistence() else { return }
        guard !isConsumingResetCredit else { return }
        isConsumingResetCredit = true
        CodexResetCreditClient.consume(
            creditID: creditID
        ) { [weak self] result in
            guard let self else { return }
            self.isConsumingResetCredit = false
            switch result {
            case .success(.reset):
                self.alertMessage =
                    "Reset credit применён. Лимит Codex обновляется."
                self.syncAccountUsage()
            case .success(.alreadyRedeemed):
                self.alertMessage =
                    "Этот reset credit уже был применён."
                self.syncAccountUsage()
            case .success(.nothingToReset):
                self.alertMessage =
                    "Сейчас нет окна лимита, которое можно сбросить."
            case .success(.noCredit):
                self.alertMessage =
                    "Доступных reset credits больше нет."
            case .failure(let error):
                self.alertMessage =
                    "Не удалось применить reset credit: "
                    + error.localizedDescription
            }
        }
    }

    func syncAccountUsage() {
        guard requireWritablePersistence() else { return }
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.syncAccountUsage()
        }) {
            return
        }
        guard !isSyncingAccount else { return }
        isSyncingAccount = true
        accountSyncHasError = false
        accountSyncStatus = "Запрашивается через Codex app-server…"
        CodexAppServerClient.fetch { [weak self] result in
            self?.applyAccountSyncResult(result)
        }
    }

    func applyAccountSyncResult(
        _ result: Result<CodexAccountResult, Error>
    ) {
        guard requireWritablePersistence() else { return }
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.applyAccountSyncResult(result)
        }, onQueueFull: { [weak self] in
            guard let self else { return }
            self.isSyncingAccount = false
            self.accountSyncHasError = true
            self.accountSyncStatus =
                "Результат account sync отклонён: очередь операций заполнена."
        }) {
            return
        }
        switch result {
        case .success(let value):
            let lifetime = value.usage.summary.lifetimeTokens.map(
                UsageFormatting.fullTokens
            ) ?? "нет данных"
            var candidate = persistedState()
            candidate.accountUsage = value.usage
            candidate.knownModels = value.models
            accountSyncStatus =
                "Ответ получен, проверяется размер состояния…"
            commitOrValidatePersistedMutation(
                candidate: candidate,
                safeUpperBound: Self.saturatingStateSizeAdd(
                    persistedStateSizeUpperBound,
                    Self.conservativeAccountStateSize(
                        value.usage,
                        models: value.models
                    )
                ),
                failurePrefix: "Официальные данные не применены",
                retry: { [weak self] in
                    self?.applyAccountSyncResult(result)
                },
                failure: { [weak self] message in
                    guard let self else { return }
                    self.isSyncingAccount = false
                    self.accountSyncHasError = true
                    self.accountSyncStatus = message
                },
                commit: { [weak self] in
                    guard let self else { return }
                    self.accountUsage = value.usage
                    self.knownModels = value.models
                    self.accountProfile = value.profile
                    self.rateLimits = value.rateLimits
                    self.isSyncingAccount = false
                    self.accountSyncHasError = false
                    self.accountSyncStatus =
                        "Получено официально • lifetime \(lifetime)"
                    self.alertMessage = nil
                }
            )
        case .failure(let error):
            isSyncingAccount = false
            accountSyncHasError = true
            accountSyncStatus = "Ошибка: \(error.localizedDescription)"
        }
    }

    func scanLocalHistory() {
        guard requireWritablePersistence() else { return }
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.scanLocalHistory()
        }) {
            return
        }
        guard !isScanningLocal else { return }
        isScanningLocal = true
        localScanHasError = false
        localScanStatus = "Сканируется ~/.codex/sessions без чтения текстов запросов…"
        let scanStartedAt = Date()
        let incrementalAfter = sourceKind == .codexLocal ? lastLocalScanAt : nil
        let generation = beginDataSourceOperation()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try CodexLocalSessionSource.scan(modifiedAfter: incrementalAfter)
                DispatchQueue.main.async { [weak self] in
                    self?.applyLocalScanResult(
                        result,
                        incrementalAfter: incrementalAfter,
                        scanStartedAt: scanStartedAt,
                        generation: generation
                    )
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isScanningLocal = false
                    guard self.dataSourceGeneration == generation else { return }
                    self.localScanHasError = true
                    self.localScanStatus = "Ошибка: \(error.localizedDescription)"
                }
            }
        }
    }

    private func applyLocalScanResult(
        _ result: LocalScanResult,
        incrementalAfter: Date?,
        scanStartedAt: Date,
        generation: UInt64
    ) {
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.applyLocalScanResult(
                result,
                incrementalAfter: incrementalAfter,
                scanStartedAt: scanStartedAt,
                generation: generation
            )
        }, onQueueFull: { [weak self] in
            guard let self else { return }
            self.isScanningLocal = false
            self.localScanHasError = true
            self.localScanStatus =
                "Результат scan отклонён: очередь операций заполнена."
        }) {
            localScanStatus =
                "Scan завершён и ожидает проверки локального состояния…"
            return
        }
        guard dataSourceGeneration == generation else {
            isScanningLocal = false
            localScanStatus =
                "Результат scan пропущен: источник данных уже изменён"
            return
        }
        let live = records.filter { $0.source == "otel-live" }
        let previous = incrementalAfter == nil
            ? []
            : records.filter { $0.source == "codex-local-rollout" }
        let reconciliation = reconciledCrossSourceRecords(
            result.records + previous + live
        )
        var candidate = persistedState()
        candidate.records = reconciliation.records
        candidate.sourceKind = .codexLocal
        candidate.importedFileName = nil
        candidate.lastLocalScanAt = scanStartedAt
        let importNote =
            "\(result.records.count) реальных ответов • "
            + "\(result.filesScanned) файлов"
        let successStatus =
            (incrementalAfter == nil ? "Полный scan" : "Incremental")
            + " • \(result.tokenEvents) событий • дублей "
            + "\(result.duplicatesRemoved)"
            + (result.missingModel > 0
                ? " • без модели \(result.missingModel)"
                : "")
        localScanStatus = "Scan завершён, проверяется размер состояния…"
        commitOrValidatePersistedMutation(
            candidate: candidate,
            failurePrefix: "Локальный scan не применён",
            retry: { [weak self] in
                self?.applyLocalScanResult(
                    result,
                    incrementalAfter: incrementalAfter,
                    scanStartedAt: scanStartedAt,
                    generation: generation
                )
            },
            failure: { [weak self] message in
                guard let self else { return }
                self.isScanningLocal = false
                self.localScanHasError = true
                self.localScanStatus = message
            },
            commit: { [weak self] in
                guard
                    let self,
                    self.dataSourceGeneration == generation
                else {
                    return
                }
                self.crossSourceLiveObservations =
                    reconciliation.observations
                self.lastLocalScanAt = scanStartedAt
                self.records = reconciliation.records
                self.recordSignatures =
                    reconciliation.recordSignatures
                self.sourceKind = .codexLocal
                self.importedFileName = nil
                self.lastImportNote = importNote
                self.localScanHasError = false
                self.localScanStatus = successStatus
                self.isScanningLocal = false
                self.alertMessage = nil
            }
        )
    }

    func updateOfficialPrices(force: Bool = true) {
        guard requireWritablePersistence() else { return }
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.updateOfficialPrices(force: force)
        }) {
            return
        }
        guard !isUpdatingPrices else { return }
        if
            !force,
            let lastUpdated = prices.compactMap(\.lastUpdated).max(),
            Date().timeIntervalSince(lastUpdated) < 6 * 60 * 60
        {
            priceUpdateHasError = false
            priceUpdateStatus =
                "Официальные цены актуальны • \(lastUpdated.formatted(date: .abbreviated, time: .shortened))"
            return
        }
        isUpdatingPrices = true
        priceOperationGeneration &+= 1
        let operationGeneration = priceOperationGeneration
        priceUpdateHasError = false
        priceUpdateStatus = "Загрузка официальных страниц моделей…"
        officialPricingFetcher { [weak self] result in
            self?.applyOfficialPriceResult(
                result,
                operationGeneration: operationGeneration
            )
        }
    }

    private func applyOfficialPriceResult(
        _ result: Result<[ModelPrice], Error>,
        operationGeneration: UInt64
    ) {
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.applyOfficialPriceResult(
                result,
                operationGeneration: operationGeneration
            )
        }, onQueueFull: { [weak self] in
            guard let self else { return }
            self.priceOperationGeneration &+= 1
            self.isUpdatingPrices = false
            self.priceUpdateHasError = true
            self.priceUpdateStatus =
                "Результат цен отклонён: очередь операций заполнена."
        }) {
            priceUpdateStatus =
                "Цены получены и ожидают проверки локального состояния…"
            return
        }
        guard priceOperationGeneration == operationGeneration else {
            return
        }
        switch result {
        case .success(let fetched):
            var mergedPrices = prices
            mergedPrices.removeAll(where: isUnmodifiedLegacyOfficialPrice)
            var reachedPriceLimit = false
            for price in fetched {
                if let index = mergedPrices.firstIndex(where: {
                    $0.modelPattern == price.modelPattern
                }) {
                    var updated = price
                    updated.id = mergedPrices[index].id
                    mergedPrices[index] = updated
                } else {
                    guard
                        mergedPrices.count < UsageStateLimits.maximumPrices
                    else {
                        reachedPriceLimit = true
                        continue
                    }
                    mergedPrices.append(price)
                }
            }
            var candidate = persistedState()
            candidate.prices = mergedPrices
            priceUpdateStatus =
                "Цены получены, проверяется размер состояния…"
            commitOrValidatePersistedMutation(
                candidate: candidate,
                safeUpperBound: Self.saturatingStateSizeAdd(
                    persistedStateSizeUpperBound,
                    Self.conservativePricesSize(fetched) + 1_024
                ),
                failurePrefix: "Обновление цен не применено",
                retry: { [weak self] in
                    self?.applyOfficialPriceResult(
                        result,
                        operationGeneration: operationGeneration
                    )
                },
                failure: { [weak self] message in
                    guard let self else { return }
                    self.priceOperationGeneration &+= 1
                    self.isUpdatingPrices = false
                    self.priceUpdateHasError = true
                    self.priceUpdateStatus = message
                },
                commit: { [weak self] in
                    guard
                        let self,
                        self.priceOperationGeneration == operationGeneration
                    else {
                        return
                    }
                    self.prices = mergedPrices
                    self.priceOperationGeneration &+= 1
                    self.isUpdatingPrices = false
                    if reachedPriceLimit {
                        self.priceUpdateHasError = true
                        self.priceUpdateStatus =
                            "Не все цены сохранены: максимум "
                            + "\(UsageStateLimits.maximumPrices)."
                        self.alertMessage = self.priceUpdateStatus
                    } else {
                        self.priceUpdateHasError = false
                        self.priceUpdateStatus =
                            "Обновлено с developers.openai.com • "
                            + Date().formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        self.alertMessage = nil
                    }
                }
            )
        case .failure(let error):
            priceOperationGeneration &+= 1
            isUpdatingPrices = false
            priceUpdateHasError = true
            priceUpdateStatus = error.localizedDescription
        }
    }

    func startLiveReceiver() {
        guard canPersist else {
            liveReceiverStatus =
                "OTel receiver не запущен: локальное состояние открыто только для чтения"
            isLiveReceiverRunning = false
            return
        }
        do {
            let capabilityToken = try OTelCapabilityStore.loadOrCreate(
                in: storageDirectory
            )
            liveReceiver.start(
                capabilityToken: capabilityToken,
                onRecords: { [weak self] records, completion in
                    guard let self else {
                        completion(.temporarilyUnavailable)
                        return
                    }
                    self.mergeLiveRecords(
                        records,
                        completion: completion
                    )
                },
                onStatus: { [weak self] status, running in
                    self?.liveReceiverStatus = status
                    self?.isLiveReceiverRunning = running
                }
            )
        } catch {
            liveReceiverStatus =
                "OTel receiver не запущен: \(error.localizedDescription)"
            isLiveReceiverRunning = false
        }
    }

    func installLiveOTelConfiguration() {
        guard requireWritablePersistence() else { return }
        do {
            let capabilityToken = try OTelCapabilityStore.loadOrCreate(
                in: storageDirectory
            )
            try OTelConfigManager.install(
                capabilityToken: capabilityToken
            )
            startLiveReceiver()
            alertMessage =
                "Защищённый Live OTel добавлен в ~/.codex/config.toml. Полностью перезапустите Codex, "
                + "чтобы новые ответы начали поступать. Тексты запросов отключены."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func importFile(_ url: URL) {
        guard requireWritablePersistence() else { return }
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.importFile(url)
        }) {
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        let generation = beginDataSourceOperation()
        lastImportNote = "Импортируется \(url.lastPathComponent)…"

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<ImportResult, Error>
            do {
                let imported = try UsageImporter.importFile(url)
                guard !imported.records.isEmpty else {
                    throw UsageImportError.noRecords
                }
                result = .success(imported)
            } catch {
                result = .failure(error)
            }

            if accessed {
                url.stopAccessingSecurityScopedResource()
            }

            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    self.dataSourceGeneration == generation
                else {
                    return
                }
                switch result {
                case .success(let imported):
                    self.commitImportedResult(
                        imported,
                        fileName: url.lastPathComponent,
                        generation: generation
                    )
                case .failure(let error):
                    self.lastImportNote =
                        "Импорт \(url.lastPathComponent) не выполнен: "
                        + error.localizedDescription
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func commitImportedResult(
        _ imported: ImportResult,
        fileName: String,
        generation: UInt64
    ) {
        guard dataSourceGeneration == generation else { return }
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.commitImportedResult(
                imported,
                fileName: fileName,
                generation: generation
            )
        }, onQueueFull: { [weak self] in
            self?.lastImportNote =
                "Импорт не применён: очередь операций заполнена."
        }) {
            lastImportNote = "Импорт проверяется перед сохранением…"
            return
        }

        var candidate = persistedState()
        candidate.records = imported.records
        candidate.sourceKind = .importedFile
        candidate.importedFileName = fileName
        candidate.lastLocalScanAt = nil
        lastImportNote = "Импорт проверяется перед сохранением…"
        commitOrValidatePersistedMutation(
            candidate: candidate,
            failurePrefix: "Импорт не применён",
            retry: { [weak self] in
                self?.commitImportedResult(
                    imported,
                    fileName: fileName,
                    generation: generation
                )
            },
            failure: { [weak self] message in
                self?.lastImportNote = message
            },
            commit: { [weak self] in
                guard
                    let self,
                    self.dataSourceGeneration == generation
                else {
                    return
                }
                self.crossSourceLiveObservations.removeAll(
                    keepingCapacity: true
                )
                self.records = imported.records
                self.sourceKind = .importedFile
                self.importedFileName = fileName
                self.lastLocalScanAt = nil
                self.lastImportNote =
                    "\(imported.records.count) записей • \(imported.format)"
                    + (imported.skippedRows > 0
                        ? " • пропущено: \(imported.skippedRows)"
                        : "")
                self.alertMessage = nil
            }
        )
    }

    func loadDemoData() {
        guard requireWritablePersistence() else { return }
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.loadDemoData()
        }) {
            return
        }
        let generation = beginDataSourceOperation()
        let demoRecords =
            (try? DemoUsageSource(calendar: calendar).load()) ?? []
        var candidate = persistedState()
        candidate.records = demoRecords
        candidate.sourceKind = .demo
        candidate.importedFileName = nil
        candidate.lastLocalScanAt = nil
        commitOrValidatePersistedMutation(
            candidate: candidate,
            failurePrefix: "Демо-набор не применён",
            retry: { [weak self] in
                self?.loadDemoData()
            },
            failure: { [weak self] message in
                self?.lastImportNote = message
            },
            commit: { [weak self] in
                guard
                    let self,
                    self.dataSourceGeneration == generation
                else {
                    return
                }
                self.crossSourceLiveObservations.removeAll(
                    keepingCapacity: true
                )
                self.records = demoRecords
                self.sourceKind = .demo
                self.importedFileName = nil
                self.lastLocalScanAt = nil
                self.lastImportNote = "Демо-набор обновлён"
                self.alertMessage = nil
            }
        )
    }

    func clearUsageData() {
        guard requireWritablePersistence() else { return }
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.clearUsageData()
        }) {
            return
        }
        let generation = beginDataSourceOperation()
        var candidate = persistedState()
        candidate.records = []
        candidate.sourceKind = .empty
        candidate.importedFileName = nil
        candidate.lastLocalScanAt = nil
        commitOrValidatePersistedMutation(
            candidate: candidate,
            safeUpperBound: persistedStateSizeUpperBound,
            failurePrefix: "Очистка данных не применена",
            retry: { [weak self] in
                self?.clearUsageData()
            },
            failure: { [weak self] message in
                self?.lastImportNote = message
            },
            commit: { [weak self] in
                guard
                    let self,
                    self.dataSourceGeneration == generation
                else {
                    return
                }
                self.crossSourceLiveObservations.removeAll(
                    keepingCapacity: true
                )
                self.records = []
                self.sourceKind = .empty
                self.importedFileName = nil
                self.lastLocalScanAt = nil
                self.lastImportNote =
                    "Детализированные данные очищены"
                self.alertMessage = nil
            }
        )
    }

    func resetPrices() {
        guard requireWritablePersistence() else { return }
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.resetPrices()
        }) {
            return
        }
        guard canEditPrices else {
            alertMessage = "Дождитесь завершения обновления таблицы цен."
            return
        }
        let nextPrices = Pricing.defaultPrices
        commitPriceMutation(
            nextPrices,
            safeAdditionalBytes: Self.conservativePricesSize(nextPrices),
            failurePrefix: "Сброс цен не применён",
            retry: { [weak self] in
                self?.resetPrices()
            }
        ) { [weak self] in
            self?.priceUpdateHasError = false
            self?.priceUpdateStatus =
                "Восстановлена встроенная таблица"
            self?.alertMessage = nil
        }
    }

    func addPrice() {
        guard requireWritablePersistence() else { return }
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.addPrice()
        }) {
            return
        }
        guard canEditPrices else {
            alertMessage = "Дождитесь завершения обновления таблицы цен."
            return
        }
        guard prices.count < UsageStateLimits.maximumPrices else {
            alertMessage =
                "Достигнут максимум: \(UsageStateLimits.maximumPrices) цен."
            return
        }
        let addedPrice = ModelPrice(
            modelPattern: "new-model",
            inputPerMillion: 0,
            cachedInputPerMillion: 0,
            cacheWritePerMillion: 0,
            outputPerMillion: 0
        )
        var nextPrices = prices
        nextPrices.append(addedPrice)
        commitPriceMutation(
            nextPrices,
            safeAdditionalBytes:
                Self.conservativePricesSize([addedPrice]) + 64,
            failurePrefix: "Цена не добавлена",
            retry: { [weak self] in
                self?.addPrice()
            }
        )
    }

    func removePrice(id: UUID) {
        guard requireWritablePersistence() else { return }
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.removePrice(id: id)
        }) {
            return
        }
        guard canEditPrices else {
            alertMessage = "Дождитесь завершения обновления таблицы цен."
            return
        }
        var nextPrices = prices
        nextPrices.removeAll { $0.id == id }
        guard nextPrices.count != prices.count else { return }
        commitPriceMutation(
            nextPrices,
            safeAdditionalBytes: 0,
            failurePrefix: "Цена не удалена",
            retry: { [weak self] in
                self?.removePrice(id: id)
            }
        )
    }

    func updatePricePattern(id: UUID, value: String) {
        guard requireWritablePersistence() else { return }
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.updatePricePattern(id: id, value: value)
        }) {
            return
        }
        guard canEditPrices else {
            alertMessage = "Дождитесь завершения обновления таблицы цен."
            return
        }
        guard let index = prices.firstIndex(where: { $0.id == id }) else {
            return
        }
        var nextPrices = prices
        nextPrices[index].modelPattern = value
        commitPriceMutation(
            nextPrices,
            safeAdditionalBytes:
                Self.escapedJSONStringUpperBound(
                    nextPrices[index].modelPattern
                ) + 64,
            failurePrefix: "Шаблон цены не изменён",
            retry: { [weak self] in
                self?.updatePricePattern(id: id, value: value)
            }
        )
    }

    func updatePriceValue(
        id: UUID,
        keyPath: WritableKeyPath<ModelPrice, Double>,
        value: Double
    ) {
        guard requireWritablePersistence() else { return }
        if deferPersistenceMutationIfNeeded({ [weak self] in
            self?.updatePriceValue(id: id, keyPath: keyPath, value: value)
        }) {
            return
        }
        guard canEditPrices else {
            alertMessage = "Дождитесь завершения обновления таблицы цен."
            return
        }
        guard let index = prices.firstIndex(where: { $0.id == id }) else {
            return
        }
        var nextPrices = prices
        nextPrices[index][keyPath: keyPath] = value
        commitPriceMutation(
            nextPrices,
            safeAdditionalBytes: 64,
            failurePrefix: "Цена не изменена",
            retry: { [weak self] in
                self?.updatePriceValue(
                    id: id,
                    keyPath: keyPath,
                    value: value
                )
            }
        )
    }

    private func commitPriceMutation(
        _ nextPrices: [ModelPrice],
        safeAdditionalBytes: Int,
        failurePrefix: String,
        retry: @escaping @MainActor @Sendable () -> Void,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        var candidate = persistedState()
        candidate.prices = nextPrices
        commitOrValidatePersistedMutation(
            candidate: candidate,
            safeUpperBound: Self.saturatingStateSizeAdd(
                persistedStateSizeUpperBound,
                safeAdditionalBytes
            ),
            failurePrefix: failurePrefix,
            retry: retry,
            commit: { [weak self] in
                guard let self else { return }
                self.prices = nextPrices
                self.priceOperationGeneration &+= 1
                completion?()
            }
        )
    }

    private func totalTokens(in interval: DateInterval) -> Int {
        var total = 0
        for record in records where interval.contains(record.timestamp) {
            total = UsageLimits.saturatingAdd(total, record.totalTokens)
        }
        return total
    }

    func recentInterval(days: Int, now: Date = Date()) -> DateInterval {
        let end = now.addingTimeInterval(1)
        let startOfToday = calendar.startOfDay(for: now)
        let start = calendar.date(
            byAdding: .day,
            value: -(max(1, days) - 1),
            to: startOfToday
        ) ?? startOfToday
        return DateInterval(start: start, end: end)
    }

    func dashboardSnapshot(days: Int, now: Date = Date()) -> DashboardSnapshot {
        let normalizedDays = max(1, days)
        let interval = recentInterval(days: normalizedDays, now: now)
        if
            let cached = dashboardCache[normalizedDays],
            cached.snapshot.interval.start == interval.start,
            interval.end >= cached.snapshot.interval.end,
            cached.nextFutureRecordTimestamp.map({ interval.end < $0 }) ?? true
        {
            return cached.snapshot.withInterval(interval)
        }

        var total = UsageSummary()
        var byDayAndModel: [DayModelKey: UsageSummary] = [:]
        var byModel: [String: UsageSummary] = [:]
        var byDay: [Date: UsageSummary] = [:]
        var resolvedPrices: [String: ModelPrice] = [:]
        var unpricedModels = Set<String>()
        var nextFutureRecordTimestamp: Date?

        for record in records {
            if
                record.timestamp >= interval.end,
                nextFutureRecordTimestamp.map({ record.timestamp < $0 }) ?? true
            {
                nextFutureRecordTimestamp = record.timestamp
            }
            guard interval.contains(record.timestamp) else { continue }
            let price = resolvedPrice(
                for: record.model,
                cache: &resolvedPrices,
                unpricedModels: &unpricedModels
            )

            var contribution = UsageSummary()
            contribution.add(
                record,
                cost: price.map { Pricing.cost(for: record, price: $0) }
            )
            total.add(contribution)

            let day = calendar.startOfDay(for: record.timestamp)
            byDayAndModel[
                DayModelKey(day: day, model: record.model),
                default: UsageSummary()
            ].add(contribution)
            byModel[record.model, default: UsageSummary()].add(contribution)
            byDay[day, default: UsageSummary()].add(contribution)
        }

        let dailyRows = byDayAndModel.map { key, summary in
            DailyUsage(date: key.day, model: key.model, summary: summary)
        }
        .sorted {
            if $0.date == $1.date { return $0.model < $1.model }
            return $0.date < $1.date
        }

        var chartSegments: [DailyChartSegment] = []
        chartSegments.reserveCapacity(dailyRows.count)
        var segmentDay: Date?
        var lowerBound = 0
        for row in dailyRows {
            if segmentDay != row.date {
                segmentDay = row.date
                lowerBound = 0
            }
            let upperBound = UsageLimits.saturatingAdd(
                lowerBound,
                row.summary.totalTokens
            )
            chartSegments.append(
                DailyChartSegment(
                    row: row,
                    lowerBound: lowerBound,
                    upperBound: upperBound
                )
            )
            lowerBound = upperBound
        }

        let snapshot = DashboardSnapshot(
            interval: interval,
            summary: total,
            dailyRows: dailyRows,
            modelRows: byModel.map { ModelUsage(model: $0.key, summary: $0.value) }
                .sorted {
                    if $0.summary.totalTokens == $1.summary.totalTokens {
                        return $0.model < $1.model
                    }
                    return $0.summary.totalTokens > $1.summary.totalTokens
                },
            chartSegments: chartSegments,
            dailyTotals: byDay.map { (date: $0.key, summary: $0.value) }
                .sorted { $0.date > $1.date }
        )
        dashboardCache[normalizedDays] = DashboardCacheEntry(
            snapshot: snapshot,
            nextFutureRecordTimestamp: nextFutureRecordTimestamp
        )
        return snapshot
    }

    func mergeLiveRecords(
        _ newRecords: [UsageRecord],
        completion: (
            @Sendable (OTelRecordAcceptance) -> Void
        )? = nil
    ) {
        guard requireWritablePersistence() else {
            completion?(.temporarilyUnavailable)
            return
        }
        if deferPersistenceMutationIfNeeded({ [weak self] in
            guard let self else {
                completion?(.temporarilyUnavailable)
                return
            }
            self.mergeLiveRecords(
                newRecords,
                completion: completion
            )
        }, onQueueFull: {
            completion?(.temporarilyUnavailable)
        }) {
            return
        }
        guard !newRecords.isEmpty else {
            completion?(.accepted)
            return
        }
        let previousObservationCount = crossSourceLiveObservations.count
        let previousMenuSummaryCache = menuSummaryCache
        let previousSignatures =
            recordSignatures
            ?? Set(records.lazy.map(\.exactUsageSignature))
        let reconciliation = reconciledCrossSourceRecords(
            records,
            addingLiveRecords: newRecords,
            assumeInputDeduplicatedAndSorted: true,
            previousRecordSignatures: previousSignatures
        )
        let reconciledSignatures = reconciliation.recordSignatures
        let additions = reconciliation.addedRecords
        let candidateSource: UsageSourceKind =
            sourceKind == .codexLocal ? .codexLocal : .otelLive
        var candidate = persistedState()
        candidate.records = reconciliation.records
        candidate.sourceKind = candidateSource
        let safeUpperBound = Self.saturatingStateSizeAdd(
            persistedStateSizeUpperBound,
            Self.conservativeRecordsSize(newRecords) + 1_024
        )
        let observed = max(
            0,
            reconciliation.observations.count - previousObservationCount
        )
        let note = "Получено live OTel: \(max(observed, additions.count))"
        commitOrValidatePersistedMutation(
            candidate: candidate,
            safeUpperBound: safeUpperBound,
            failurePrefix: "Live OTel не применён",
            retry: { [weak self] in
                guard let self else {
                    completion?(.temporarilyUnavailable)
                    return
                }
                self.mergeLiveRecords(
                    newRecords,
                    completion: completion
                )
            },
            failure: { [weak self] message in
                self?.lastImportNote = message
            },
            rejection: { rejection in
                switch rejection {
                case .temporarilyUnavailable:
                    completion?(.temporarilyUnavailable)
                case .insufficientStorage:
                    completion?(.insufficientStorage)
                }
            },
            requiresDurableWrite: completion != nil,
            commit: { [weak self] in
                guard let self else {
                    completion?(.temporarilyUnavailable)
                    return
                }
                self.crossSourceLiveObservations =
                    reconciliation.observations
                self.records = reconciliation.records
                self.sourceKind = candidateSource
                if
                    !additions.isEmpty,
                    previousSignatures.isSubset(of: reconciledSignatures)
                {
                    self.menuSummaryCache = self.updatedMenuSummaryCache(
                        previousMenuSummaryCache,
                        adding: additions
                    )
                }
                self.recordSignatures = reconciledSignatures
                self.lastImportNote = note
                self.alertMessage = nil
                completion?(.accepted)
            }
        )
    }

    private func reconciledCrossSourceRecords(
        _ input: [UsageRecord],
        addingLiveRecords: [UsageRecord] = [],
        assumeInputDeduplicatedAndSorted: Bool = false,
        previousRecordSignatures: Set<UsageRecordSignature>? = nil
    ) -> CrossSourceReconciliation {
        var observations = crossSourceLiveObservations
        observations.reserveCapacity(
            min(
                UsageLimits.maximumRetainedRecords,
                observations.count + input.count + addingLiveRecords.count
            )
        )
        for record in input where record.source == "otel-live" {
            observations.insert(record.exactUsageSignature)
        }
        for record in addingLiveRecords {
            observations.insert(record.exactUsageSignature)
        }
        if observations.count > UsageLimits.maximumRetainedRecords {
            observations = Set(
                observations
                    .sorted(by: newestSignaturePreference)
                    .prefix(UsageLimits.maximumRetainedRecords)
            )
        }

        var baseSignatures = Set<UsageRecordSignature>()
        let baseRecords: [UsageRecord]
        if assumeInputDeduplicatedAndSorted {
            baseRecords = input.filter { $0.source != "otel-live" }
            baseSignatures = Set(baseRecords.lazy.map(\.exactUsageSignature))
        } else {
            var unique: [UsageRecord] = []
            unique.reserveCapacity(input.count)
            for record in input
                .filter({ $0.source != "otel-live" })
                .sorted(by: exactDedupePreference)
            {
                if baseSignatures.insert(record.exactUsageSignature).inserted {
                    unique.append(record)
                }
            }
            baseRecords = unique.sorted(by: newestRecordPreference)
        }

        let exactMatchedObservations = observations.intersection(baseSignatures)
        let exactMatchedLocalKeys: Set<CrossSourceLocalMatchKey> = Set(
            baseRecords.compactMap {
                record -> CrossSourceLocalMatchKey? in
                guard
                    record.source == "codex-local-rollout",
                    exactMatchedObservations.contains(
                        record.exactUsageSignature
                    )
                else {
                    return nil
                }
                return CrossSourceLocalMatchKey(record: record)
            }
        )
        let fuzzyCandidates = observations
            .subtracting(exactMatchedObservations)
            .map(liveRecord(from:))
            .sorted(by: newestRecordPreference)
        let fuzzyMatches = matchedLiveRecords(
            in: fuzzyCandidates,
            localRecords: baseRecords,
            excludingLocalKeys: exactMatchedLocalKeys,
            excludingLiveSignatures: []
        )
        let fuzzyMatchedIndices = Set(fuzzyMatches.map(\.liveIndex))
        let unmatchedLive = fuzzyCandidates.indices.compactMap { index in
            fuzzyMatchedIndices.contains(index) ? nil : fuzzyCandidates[index]
        }
        let merged = mergeNewestFirst(
            unmatchedLive.sorted(by: newestRecordPreference),
            baseRecords
        )
        let limited = limitedNewestRecords(merged)

        var retainedBaseSignatures = Set<UsageRecordSignature>()
        var retainedLiveSignatures = Set<UsageRecordSignature>()
        var retainedRecordSignatures = Set<UsageRecordSignature>()
        var retainedLocalKeys = Set<CrossSourceLocalMatchKey>()
        var addedRecords: [UsageRecord] = []
        retainedRecordSignatures.reserveCapacity(limited.count)
        if previousRecordSignatures != nil {
            addedRecords.reserveCapacity(addingLiveRecords.count)
        }
        for record in limited {
            let signature = record.exactUsageSignature
            retainedRecordSignatures.insert(signature)
            if
                let previousRecordSignatures,
                !previousRecordSignatures.contains(signature)
            {
                addedRecords.append(record)
            }
            if record.source == "otel-live" {
                retainedLiveSignatures.insert(signature)
            } else {
                retainedBaseSignatures.insert(signature)
                if record.source == "codex-local-rollout" {
                    retainedLocalKeys.insert(
                        CrossSourceLocalMatchKey(record: record)
                    )
                }
            }
        }
        var matchedSignaturesByLocal:
            [CrossSourceLocalMatchKey: UsageRecordSignature] = [:]
        matchedSignaturesByLocal.reserveCapacity(fuzzyMatches.count)
        for match in fuzzyMatches {
            matchedSignaturesByLocal[match.localKey] =
                fuzzyCandidates[match.liveIndex].exactUsageSignature
        }
        let retainedFuzzySignatures = Set(
            matchedSignaturesByLocal.compactMap { localKey, signature in
                retainedLocalKeys.contains(localKey) ? signature : nil
            }
        )
        var retainedObservations = observations.filter { signature in
            retainedLiveSignatures.contains(signature)
                || retainedFuzzySignatures.contains(signature)
                || (
                    exactMatchedObservations.contains(signature)
                        && retainedBaseSignatures.contains(signature)
                )
        }
        if retainedObservations.count > UsageLimits.maximumRetainedRecords {
            retainedObservations = Set(
                retainedObservations
                    .sorted(by: newestSignaturePreference)
                    .prefix(UsageLimits.maximumRetainedRecords)
            )
        }
        return CrossSourceReconciliation(
            records: limited,
            observations: retainedObservations,
            recordSignatures: retainedRecordSignatures,
            addedRecords: addedRecords
        )
    }

    private func liveRecord(
        from signature: UsageRecordSignature
    ) -> UsageRecord {
        UsageRecord(
            timestamp: signature.timestamp,
            model: signature.model,
            inputTokens: signature.inputTokens,
            cachedInputTokens: signature.cachedInputTokens,
            cacheWriteTokens: signature.cacheWriteTokens,
            outputTokens: signature.outputTokens,
            source: "otel-live",
            reasoningOutputTokens: signature.reasoningOutputTokens,
            serviceTier: signature.serviceTier
        )
    }

    private func newestSignaturePreference(
        _ left: UsageRecordSignature,
        _ right: UsageRecordSignature
    ) -> Bool {
        newestRecordPreference(
            liveRecord(from: left),
            liveRecord(from: right)
        )
    }

    @discardableResult
    private func loadState() -> StateLoadResult {
        var openedIdentity: StateFileIdentity?
        do {
            let opened: StateFileRead
            if let persistenceLease {
                opened = try Self.readStateData(
                    in: persistenceLease.directoryDescriptor,
                    hardenPermissions: true,
                    interposition: stateDescriptorReadInterposition
                )
            } else {
                opened = try Self.readStateData(
                    at: stateURL,
                    hardenPermissions: false,
                    interposition: stateDescriptorReadInterposition
                )
            }
            openedIdentity = opened.identity
            let data = opened.data
            stateReadInterposition?()
            var state = try decoder.decode(PersistedState.self, from: data)
            internStrings(in: &state.records)
            let loadedRecords = recordsAreSortedNewestFirst(state.records)
                ? state.records
                : state.records.sorted { $0.timestamp > $1.timestamp }
            records = limitedNewestRecords(loadedRecords)
            prices = state.prices
            sourceKind = state.sourceKind
            importedFileName = state.importedFileName
            accountUsage = state.accountUsage
            knownModels = state.knownModels ?? []
            lastLocalScanAt = (state.schemaVersion ?? 1) >= 2
                ? state.lastLocalScanAt
                : nil
            if let fetchedAt = accountUsage?.fetchedAt {
                accountSyncStatus =
                    "Последняя синхронизация "
                    + fetchedAt.formatted(date: .abbreviated, time: .shortened)
            }
            return .loaded
        } catch StatePersistenceError.posix(let code)
            where code == ENOENT
        {
            return .missing
        } catch {
            return .corrupt(
                reason: error.localizedDescription,
                backupName: quarantineCorruptState(
                    expectedIdentity: openedIdentity
                )
            )
        }
    }

    private func saveStateSynchronously() {
        guard let persistenceLease else {
            reportPersistenceUnavailable()
            return
        }
        do {
            try Self.write(
                persistedState(),
                lease: persistenceLease
            )
        } catch {
            alertMessage = "Не удалось сохранить локальные настройки: \(error.localizedDescription)"
        }
    }

    private func saveStateAsynchronously() {
        guard persistenceLease != nil else {
            reportPersistenceUnavailable()
            return
        }
        guard !persistenceCandidateValidationInFlight else { return }
        pendingPersistedState = persistedState()
        guard !persistenceWriteInFlight else { return }
        startNextStateWrite()
    }

    private func startNextStateWrite() {
        guard let state = pendingPersistedState else {
            persistenceWriteInFlight = false
            return
        }
        pendingPersistedState = nil
        persistenceWriteInFlight = true
        let generation = persistenceGeneration
        guard let persistenceLease else {
            persistenceWriteInFlight = false
            reportPersistenceUnavailable()
            return
        }
        persistenceQueue.async {
            let errorMessage: String?
            do {
                try Self.write(
                    state,
                    lease: persistenceLease
                )
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            DispatchQueue.main.async { [weak self] in
                self?.stateWriteDidFinish(
                    generation: generation,
                    errorMessage: errorMessage
                )
            }
        }
    }

    private func stateWriteDidFinish(
        generation: UInt64,
        errorMessage: String?
    ) {
        guard generation == persistenceGeneration else { return }
        persistenceWriteInFlight = false
        if let errorMessage {
            alertMessage =
                "Не удалось сохранить локальные настройки: \(errorMessage)"
        }
        if pendingPersistedState != nil {
            startNextStateWrite()
        }
    }

    func flushState() {
        persistenceGeneration &+= 1
        pendingPersistedState = nil
        guard let persistenceLease else {
            persistenceWriteInFlight = false
            reportPersistenceUnavailable()
            return
        }
        if persistenceCandidateValidationInFlight {
            // The validation job itself owns the exact encode + atomic write.
            // Wait for that durable work, but do not publish an unchecked
            // candidate or begin deferred mutations during termination.
            persistenceQueue.sync {}
            deferredPersistenceMutations.removeAll(keepingCapacity: false)
            return
        }
        let state = persistedState()
        var saveError: Error?
        persistenceQueue.sync {
            do {
                try Self.write(
                    state,
                    lease: persistenceLease
                )
            } catch {
                saveError = error
            }
        }
        persistenceWriteInFlight = false
        if let saveError {
            alertMessage =
                "Не удалось сохранить локальные настройки: \(saveError.localizedDescription)"
        }
    }

    private func persistedState() -> PersistedState {
        PersistedState(
            schemaVersion: 4,
            records: limitedNewestRecords(records),
            prices: prices,
            sourceKind: sourceKind,
            importedFileName: importedFileName,
            accountUsage: accountUsage,
            knownModels: knownModels,
            lastLocalScanAt: lastLocalScanAt
        )
    }

    private func noteExternalPersistedMutation() {
        guard hasCompletedInitialization, !isApplyingPersistedMutation else {
            return
        }
        persistedStateSizeUpperBound = Self.conservativeEncodedSize(
            of: persistedState()
        )
    }

    private func reportRejectedDirectMutation() {
        if isReadOnly {
            reportPersistenceUnavailable()
        } else {
            alertMessage =
                "Изменение не применено: завершается проверка размера "
                + "локального состояния."
        }
    }

    private func applyPersistedMutation(
        encodedSizeUpperBound: Int,
        _ mutation: () -> Void
    ) {
        isApplyingPersistedMutation = true
        mutation()
        isApplyingPersistedMutation = false
        persistedStateSizeUpperBound = min(
            encodedSizeUpperBound,
            Self.maximumStateFileSize + 1
        )
    }

    private func deferPersistenceMutationIfNeeded(
        _ mutation: @escaping @MainActor @Sendable () -> Void,
        onQueueFull: (@MainActor @Sendable () -> Void)? = nil
    ) -> Bool {
        guard persistenceCandidateValidationInFlight else { return false }
        guard
            deferredPersistenceMutations.count
                < Self.maximumDeferredPersistenceMutations
        else {
            alertMessage =
                "Изменение не поставлено в очередь: слишком много операций "
                + "ожидают проверки локального состояния."
            onQueueFull?()
            return true
        }
        deferredPersistenceMutations.append(mutation)
        return true
    }

    private func drainDeferredPersistenceMutations() {
        while
            !persistenceCandidateValidationInFlight,
            !deferredPersistenceMutations.isEmpty
        {
            let next = deferredPersistenceMutations.removeFirst()
            next()
        }
    }

    private func validatePersistAndCommit(
        _ candidate: PersistedState,
        failurePrefix: String,
        failure: (@MainActor @Sendable (String) -> Void)? = nil,
        rejection: (
            @MainActor @Sendable (PersistenceMutationRejection) -> Void
        )? = nil,
        commit: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let persistenceLease else {
            reportPersistenceUnavailable()
            return
        }
        persistenceCandidateValidationInFlight = true
        validatingPersistedState = candidate
        persistenceValidationGeneration &+= 1
        let validationGeneration = persistenceValidationGeneration
        persistenceGeneration &+= 1
        pendingPersistedState = nil
        persistenceWriteInFlight = true

        persistenceQueue.async {
            let encodedSize: Int?
            let errorMessage: String?
            let rejectionKind: PersistenceMutationRejection?
            do {
                let data = try Self.encodedStateData(candidate)
                try Self.writeStateDataAtomically(
                    data,
                    lease: persistenceLease
                )
                encodedSize = data.count
                errorMessage = nil
                rejectionKind = nil
            } catch {
                encodedSize = nil
                errorMessage = error.localizedDescription
                rejectionKind = Self.persistenceRejection(for: error)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard
                    self.persistenceValidationGeneration
                        == validationGeneration,
                    self.persistenceCandidateValidationInFlight
                else {
                    return
                }
                self.persistenceWriteInFlight = false
                self.validatingPersistedState = nil
                var validationFailureMessage: String?
                if let encodedSize {
                    self.applyPersistedMutation(
                        encodedSizeUpperBound: encodedSize,
                        commit
                    )
                } else {
                    let message =
                        "\(failurePrefix): \(errorMessage ?? "неизвестная ошибка")"
                    self.alertMessage = message
                    validationFailureMessage = message
                    failure?(message)
                    rejection?(
                        rejectionKind ?? .temporarilyUnavailable
                    )
                }
                self.persistenceCandidateValidationInFlight = false
                self.drainDeferredPersistenceMutations()
                if
                    let validationFailureMessage,
                    self.alertMessage == nil
                {
                    self.alertMessage = validationFailureMessage
                }
            }
        }
    }

    private func commitOrValidatePersistedMutation(
        candidate: PersistedState,
        safeUpperBound: Int? = nil,
        failurePrefix: String,
        retry: @escaping @MainActor @Sendable () -> Void,
        failure: (@MainActor @Sendable (String) -> Void)? = nil,
        rejection: (
            @MainActor @Sendable (PersistenceMutationRejection) -> Void
        )? = nil,
        requiresDurableWrite: Bool = false,
        commit: @escaping @MainActor @Sendable () -> Void
    ) {
        if deferPersistenceMutationIfNeeded(retry) {
            return
        }
        do {
            try candidate.validateForPersistence()
        } catch {
            let message =
                "\(failurePrefix): \(error.localizedDescription)"
            alertMessage = message
            failure?(message)
            rejection?(Self.persistenceRejection(for: error))
            return
        }
        let upperBound =
            safeUpperBound ?? Self.conservativeEncodedSize(of: candidate)
        if
            upperBound <= Self.maximumStateFileSize,
            !requiresDurableWrite
        {
            applyPersistedMutation(
                encodedSizeUpperBound: upperBound,
                commit
            )
            return
        }
        validatePersistAndCommit(
            candidate,
            failurePrefix: failurePrefix,
            failure: failure,
            rejection: rejection,
            commit: commit
        )
    }

    nonisolated private static func persistenceRejection(
        for error: Error
    ) -> PersistenceMutationRejection {
        guard let stateError = error as? StatePersistenceError else {
            return .temporarilyUnavailable
        }
        switch stateError {
        case .stateTooLarge:
            return .insufficientStorage
        case .posix(let code) where code == ENOSPC || code == EDQUOT:
            return .insufficientStorage
        default:
            return .temporarilyUnavailable
        }
    }

    nonisolated private static func write(
        _ state: PersistedState,
        lease: StatePersistenceLease
    ) throws {
        let data = try encodedStateData(state)
        try writeStateDataAtomically(data, lease: lease)
    }

    nonisolated private static func encodedStateData(
        _ state: PersistedState
    ) throws -> Data {
        try state.validateForPersistence()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(state)
        guard data.count <= maximumStateFileSize else {
            throw StatePersistenceError.stateTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumStateFileSize
            )
        }
        return data
    }

    nonisolated private static func conservativeEncodedSize(
        of state: PersistedState
    ) -> Int {
        let ceiling = maximumStateFileSize + 1
        var total = 4_096

        func add(_ amount: Int) {
            guard total < ceiling, amount > 0 else { return }
            if amount >= ceiling - total {
                total = ceiling
            } else {
                total += amount
            }
        }

        for record in state.records {
            add(320)
            add(escapedJSONStringUpperBound(record.model))
            add(escapedJSONStringUpperBound(record.source))
            if let serviceTier = record.serviceTier {
                add(escapedJSONStringUpperBound(serviceTier))
            }
        }
        for price in state.prices {
            add(512)
            add(escapedJSONStringUpperBound(price.modelPattern))
            if let sourceURL = price.sourceURL {
                add(escapedJSONStringUpperBound(sourceURL))
            }
        }
        add(escapedJSONStringUpperBound(state.sourceKind.rawValue))
        if let importedFileName = state.importedFileName {
            add(escapedJSONStringUpperBound(importedFileName))
        }
        if let accountUsage = state.accountUsage {
            add(1_024)
            if let executable = accountUsage.codexExecutable {
                add(escapedJSONStringUpperBound(executable))
            }
            for bucket in accountUsage.dailyUsageBuckets ?? [] {
                add(192)
                add(escapedJSONStringUpperBound(bucket.startDate))
            }
        }
        for model in state.knownModels ?? [] {
            add(256)
            for value in [model.id, model.model, model.displayName]
                .compactMap({ $0 })
            {
                add(escapedJSONStringUpperBound(value))
            }
        }
        return total
    }

    nonisolated private static func conservativeRecordsSize(
        _ records: [UsageRecord]
    ) -> Int {
        var total = 0
        for record in records {
            total = saturatingStateSizeAdd(total, 320)
            total = saturatingStateSizeAdd(
                total,
                escapedJSONStringUpperBound(record.model)
            )
            total = saturatingStateSizeAdd(
                total,
                escapedJSONStringUpperBound(record.source)
            )
            if let serviceTier = record.serviceTier {
                total = saturatingStateSizeAdd(
                    total,
                    escapedJSONStringUpperBound(serviceTier)
                )
            }
        }
        return total
    }

    nonisolated private static func conservativeAccountStateSize(
        _ accountUsage: AccountUsageSnapshot,
        models: [CodexModelInfo]
    ) -> Int {
        var total = 1_024
        if let executable = accountUsage.codexExecutable {
            total = saturatingStateSizeAdd(
                total,
                escapedJSONStringUpperBound(executable)
            )
        }
        for bucket in accountUsage.dailyUsageBuckets ?? [] {
            total = saturatingStateSizeAdd(total, 192)
            total = saturatingStateSizeAdd(
                total,
                escapedJSONStringUpperBound(bucket.startDate)
            )
        }
        for model in models {
            total = saturatingStateSizeAdd(total, 256)
            for value in [model.id, model.model, model.displayName]
                .compactMap({ $0 })
            {
                total = saturatingStateSizeAdd(
                    total,
                    escapedJSONStringUpperBound(value)
                )
            }
        }
        return total
    }

    nonisolated private static func conservativePricesSize(
        _ prices: [ModelPrice]
    ) -> Int {
        var total = 0
        for price in prices {
            total = saturatingStateSizeAdd(total, 512)
            total = saturatingStateSizeAdd(
                total,
                escapedJSONStringUpperBound(price.modelPattern)
            )
            if let sourceURL = price.sourceURL {
                total = saturatingStateSizeAdd(
                    total,
                    escapedJSONStringUpperBound(sourceURL)
                )
            }
        }
        return total
    }

    nonisolated private static func saturatingStateSizeAdd(
        _ left: Int,
        _ right: Int
    ) -> Int {
        let ceiling = maximumStateFileSize + 1
        guard left < ceiling, right > 0 else {
            return min(left, ceiling)
        }
        guard right < ceiling - left else { return ceiling }
        return left + right
    }

    nonisolated private static func escapedJSONStringUpperBound(
        _ value: String
    ) -> Int {
        var count = 0
        for scalar in value.unicodeScalars {
            let scalarValue = scalar.value
            let increment: Int
            if
                scalarValue <= 0x1F
                    || scalarValue == 0x22
                    || scalarValue == 0x2F
                    || scalarValue == 0x5C
                    || scalarValue == 0x2028
                    || scalarValue == 0x2029
            {
                increment = 6
            } else {
                increment = scalar.utf8.count
            }
            if count >= maximumStateFileSize + 1 - increment {
                return maximumStateFileSize + 1
            }
            count += increment
        }
        return count
    }

    nonisolated private static func writeStateDataAtomically(
        _ data: Data,
        lease: StatePersistenceLease
    ) throws {
        let temporaryName =
            ".state.json.tmp-\(UUID().uuidString.lowercased())"
        let descriptor = openat(
            lease.directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw StatePersistenceError.posix(code: errno)
        }

        var renamed = false
        defer {
            Darwin.close(descriptor)
            if !renamed {
                _ = unlinkat(
                    lease.directoryDescriptor,
                    temporaryName,
                    0
                )
            }
        }

        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: written),
                    buffer.count - written
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw StatePersistenceError.posix(code: errno)
                }
                written += count
            }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw StatePersistenceError.posix(code: errno)
        }
        guard fsync(descriptor) == 0 else {
            throw StatePersistenceError.posix(code: errno)
        }
        guard
            renameat(
                lease.directoryDescriptor,
                temporaryName,
                lease.directoryDescriptor,
                "state.json"
            ) == 0
        else {
            throw StatePersistenceError.posix(code: errno)
        }
        renamed = true
        guard fsync(lease.directoryDescriptor) == 0 else {
            throw StatePersistenceError.posix(code: errno)
        }
    }

    private func reportPersistenceUnavailable() {
        let reason = persistenceSetupError?.localizedDescription
            ?? "writer lease недоступен"
        alertMessage =
            "Не удалось сохранить локальные настройки: \(reason)"
    }

    @discardableResult
    private func requireWritablePersistence() -> Bool {
        guard canPersist else {
            reportPersistenceUnavailable()
            return false
        }
        return true
    }

    private func beginDataSourceOperation() -> UInt64 {
        dataSourceGeneration &+= 1
        return dataSourceGeneration
    }

    private func invalidateUsageCaches() {
        dashboardCache.removeAll(keepingCapacity: true)
        menuSummaryCache = nil
        latestReconciliationCacheDayStart = nil
    }

    private func menuSummaries(
        now: Date = Date()
    ) -> (today: UsageSummary, week: UsageSummary) {
        guard
            let dayInterval = calendar.dateInterval(of: .day, for: now),
            let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now)
        else {
            return (UsageSummary(), UsageSummary())
        }
        if
            let cached = menuSummaryCache,
            cached.dayStart == dayInterval.start,
            cached.weekStart == weekInterval.start
        {
            return (cached.today, cached.week)
        }

        var today = UsageSummary()
        var week = UsageSummary()
        var resolvedPrices: [String: ModelPrice] = [:]
        var unpricedModels = Set<String>()
        for record in records {
            let isToday = dayInterval.contains(record.timestamp)
            let isThisWeek = weekInterval.contains(record.timestamp)
            guard isToday || isThisWeek else { continue }
            var contribution = UsageSummary()
            contribution.add(
                record,
                cost: resolvedPrice(
                    for: record.model,
                    cache: &resolvedPrices,
                    unpricedModels: &unpricedModels
                ).map { Pricing.cost(for: record, price: $0) }
            )
            if isToday {
                today.add(contribution)
            }
            if isThisWeek {
                week.add(contribution)
            }
        }
        menuSummaryCache = MenuSummaryCache(
            dayStart: dayInterval.start,
            weekStart: weekInterval.start,
            today: today,
            week: week
        )
        return (today, week)
    }

    private func updatedMenuSummaryCache(
        _ cached: MenuSummaryCache?,
        adding records: [UsageRecord],
        now: Date = Date()
    ) -> MenuSummaryCache? {
        guard
            var cached,
            let dayInterval = calendar.dateInterval(of: .day, for: now),
            let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now),
            cached.dayStart == dayInterval.start,
            cached.weekStart == weekInterval.start
        else {
            return nil
        }

        var resolvedPrices: [String: ModelPrice] = [:]
        var unpricedModels = Set<String>()
        for record in records {
            let isToday = dayInterval.contains(record.timestamp)
            let isThisWeek = weekInterval.contains(record.timestamp)
            guard isToday || isThisWeek else { continue }
            var contribution = UsageSummary()
            contribution.add(
                record,
                cost: resolvedPrice(
                    for: record.model,
                    cache: &resolvedPrices,
                    unpricedModels: &unpricedModels
                ).map { Pricing.cost(for: record, price: $0) }
            )
            if isToday {
                cached.today.add(contribution)
            }
            if isThisWeek {
                cached.week.add(contribution)
            }
        }
        return cached
    }

    private func resolvedPrice(
        for model: String,
        cache: inout [String: ModelPrice],
        unpricedModels: inout Set<String>
    ) -> ModelPrice? {
        let normalizedModel = model.lowercased()
        if let cached = cache[normalizedModel] {
            return cached
        }
        if unpricedModels.contains(normalizedModel) {
            return nil
        }
        if compiledPricingCatalog == nil {
            compiledPricingCatalog = Pricing.compiledCatalog(from: prices)
        }
        guard
            let price = compiledPricingCatalog?.price(for: model)
        else {
            unpricedModels.insert(normalizedModel)
            return nil
        }
        cache[normalizedModel] = price
        return price
    }

    private func recordsAreSortedNewestFirst(_ records: [UsageRecord]) -> Bool {
        guard records.count > 1 else { return true }
        for index in 1..<records.count
            where records[index - 1].timestamp < records[index].timestamp
        {
            return false
        }
        return true
    }

    private func mergeNewestFirst(
        _ first: [UsageRecord],
        _ second: [UsageRecord]
    ) -> [UsageRecord] {
        var merged: [UsageRecord] = []
        merged.reserveCapacity(first.count + second.count)
        var firstIndex = 0
        var secondIndex = 0
        while firstIndex < first.count, secondIndex < second.count {
            if first[firstIndex].timestamp >= second[secondIndex].timestamp {
                merged.append(first[firstIndex])
                firstIndex += 1
            } else {
                merged.append(second[secondIndex])
                secondIndex += 1
            }
        }
        if firstIndex < first.count {
            merged.append(contentsOf: first[firstIndex...])
        }
        if secondIndex < second.count {
            merged.append(contentsOf: second[secondIndex...])
        }
        return merged
    }

    private func internStrings(in records: inout [UsageRecord]) {
        var strings: [String: String] = [:]
        strings.reserveCapacity(min(records.count, 4_096))

        func intern(_ value: String) -> String {
            guard value.utf8.count > 15 else { return value }
            if let existing = strings[value] {
                return existing
            }
            strings[value] = value
            return value
        }

        func intern(_ value: String?) -> String? {
            value.map { intern($0) }
        }

        for index in records.indices {
            records[index].model = intern(records[index].model)
            records[index].source = intern(records[index].source)
            records[index].serviceTier = intern(records[index].serviceTier)
        }
    }

    private func limitedNewestRecords(_ input: [UsageRecord]) -> [UsageRecord] {
        guard input.count > UsageLimits.maximumRetainedRecords else {
            return input
        }
        return Array(
            input
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(UsageLimits.maximumRetainedRecords)
        )
    }

    private func crossSourceLocalMatchKeys(
        in records: [UsageRecord]
    ) -> Set<CrossSourceLocalMatchKey> {
        var keys = Set<CrossSourceLocalMatchKey>()
        keys.reserveCapacity(
            min(records.count, UsageLimits.maximumRetainedRecords)
        )
        for record in records
        where record.source == "codex-local-rollout"
        {
            keys.insert(CrossSourceLocalMatchKey(record: record))
        }
        return keys
    }

    private func crossSourceLocalKeyPreference(
        _ left: CrossSourceLocalMatchKey,
        _ right: CrossSourceLocalMatchKey
    ) -> Bool {
        if left.timestamp != right.timestamp {
            return left.timestamp > right.timestamp
        }
        if left.usage.model != right.usage.model {
            return left.usage.model < right.usage.model
        }
        if left.usage.serviceTier != right.usage.serviceTier {
            return left.usage.serviceTier < right.usage.serviceTier
        }
        if left.usage.inputTokens != right.usage.inputTokens {
            return left.usage.inputTokens < right.usage.inputTokens
        }
        if
            left.usage.cachedInputTokens
                != right.usage.cachedInputTokens
        {
            return left.usage.cachedInputTokens
                < right.usage.cachedInputTokens
        }
        if
            left.usage.cacheWriteTokens
                != right.usage.cacheWriteTokens
        {
            return left.usage.cacheWriteTokens
                < right.usage.cacheWriteTokens
        }
        if left.usage.outputTokens != right.usage.outputTokens {
            return left.usage.outputTokens < right.usage.outputTokens
        }
        return left.usage.reasoningOutputTokens
            < right.usage.reasoningOutputTokens
    }

    private func matchedLiveRecords(
        in candidates: [UsageRecord],
        localRecords: [UsageRecord],
        excludingLocalKeys: Set<CrossSourceLocalMatchKey>,
        excludingLiveSignatures: Set<UsageRecordSignature>
    ) -> [CrossSourceMatch] {
        var localTimestampsByUsage:
            [CrossSourceUsageKey: Set<TimeInterval>] = [:]
        localTimestampsByUsage.reserveCapacity(
            min(localRecords.count, 4_096)
        )
        for record in localRecords
        where record.source == "codex-local-rollout"
        {
            let localKey = CrossSourceLocalMatchKey(record: record)
            guard !excludingLocalKeys.contains(localKey) else {
                continue
            }
            localTimestampsByUsage[
                localKey.usage,
                default: []
            ].insert(localKey.timestamp)
        }

        var liveCandidatesByUsage:
            [CrossSourceUsageKey: [CrossSourceLiveCandidate]] = [:]
        liveCandidatesByUsage.reserveCapacity(
            min(candidates.count, 4_096)
        )
        for (index, record) in candidates.enumerated()
        where record.source == "otel-live"
        {
            guard
                !excludingLiveSignatures.contains(
                    record.exactUsageSignature
                )
            else {
                continue
            }
            liveCandidatesByUsage[
                CrossSourceUsageKey(record: record),
                default: []
            ].append(
                CrossSourceLiveCandidate(
                    index: index,
                    timestamp: record.timestamp.timeIntervalSince1970
                )
            )
        }

        var matches: [CrossSourceMatch] = []
        matches.reserveCapacity(
            min(candidates.count, localRecords.count)
        )
        for (key, unsortedLiveCandidates) in liveCandidatesByUsage {
            guard let localTimestampSet = localTimestampsByUsage[key] else {
                continue
            }
            let localTimestamps = localTimestampSet.sorted()
            let liveCandidates = unsortedLiveCandidates.sorted {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp < $1.timestamp
                }
                return newestRecordPreference(
                    candidates[$0.index],
                    candidates[$1.index]
                )
            }

            var localIndex = 0
            var liveIndex = 0
            // On sorted points with a shared radius, pairing the earliest
            // feasible pair is a maximum-cardinality interval matching.
            while
                localIndex < localTimestamps.count,
                liveIndex < liveCandidates.count
            {
                let localTimestamp = localTimestamps[localIndex]
                let liveCandidate = liveCandidates[liveIndex]
                if
                    localTimestamp
                        < liveCandidate.timestamp - Self.crossSourceDedupeWindow
                {
                    localIndex += 1
                } else if
                    liveCandidate.timestamp
                        < localTimestamp - Self.crossSourceDedupeWindow
                {
                    liveIndex += 1
                } else {
                    matches.append(
                        CrossSourceMatch(
                            liveIndex: liveCandidate.index,
                            localKey: CrossSourceLocalMatchKey(
                                usage: key,
                                timestamp: localTimestamp
                            )
                        )
                    )
                    localIndex += 1
                    liveIndex += 1
                }
            }
        }
        return matches.sorted { left, right in
            if left.localKey != right.localKey {
                return crossSourceLocalKeyPreference(
                    left.localKey,
                    right.localKey
                )
            }
            return newestRecordPreference(
                candidates[left.liveIndex],
                candidates[right.liveIndex]
            )
        }
    }

    private func exactDedupePreference(
        _ left: UsageRecord,
        _ right: UsageRecord
    ) -> Bool {
        let leftPriority = sourcePriority(left.source)
        let rightPriority = sourcePriority(right.source)
        if leftPriority != rightPriority {
            return leftPriority < rightPriority
        }
        return newestRecordPreference(left, right)
    }

    private func newestRecordPreference(
        _ left: UsageRecord,
        _ right: UsageRecord
    ) -> Bool {
        if left.timestamp != right.timestamp {
            return left.timestamp > right.timestamp
        }
        if left.source != right.source {
            return left.source < right.source
        }
        if left.model != right.model {
            return left.model < right.model
        }
        let leftTier = left.serviceTier ?? "default"
        let rightTier = right.serviceTier ?? "default"
        if leftTier != rightTier {
            return leftTier < rightTier
        }
        if left.inputTokens != right.inputTokens {
            return left.inputTokens < right.inputTokens
        }
        if left.cachedInputTokens != right.cachedInputTokens {
            return left.cachedInputTokens < right.cachedInputTokens
        }
        if left.cacheWriteTokens != right.cacheWriteTokens {
            return left.cacheWriteTokens < right.cacheWriteTokens
        }
        if left.outputTokens != right.outputTokens {
            return left.outputTokens < right.outputTokens
        }
        let leftReasoning = left.reasoningOutputTokens ?? 0
        let rightReasoning = right.reasoningOutputTokens ?? 0
        if leftReasoning != rightReasoning {
            return leftReasoning < rightReasoning
        }
        return left.id.uuidString < right.id.uuidString
    }

    private func sourcePriority(_ source: String) -> Int {
        switch source {
        case "codex-local-rollout":
            0
        case "otel-live":
            2
        default:
            1
        }
    }

    private func quarantineCorruptState(
        expectedIdentity: StateFileIdentity?
    ) -> String? {
        guard
            let persistenceLease,
            let expectedIdentity
        else {
            return nil
        }
        var currentMetadata = stat()
        guard
            fstatat(
                persistenceLease.directoryDescriptor,
                "state.json",
                &currentMetadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            currentMetadata.st_mode & S_IFMT == S_IFREG,
            currentMetadata.st_dev == expectedIdentity.device,
            currentMetadata.st_ino == expectedIdentity.inode
        else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let backupName =
            "state.corrupt-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).json"
        guard
            renameat(
                persistenceLease.directoryDescriptor,
                "state.json",
                persistenceLease.directoryDescriptor,
                backupName
            ) == 0
        else {
            return nil
        }

        let backupDescriptor = openat(
            persistenceLease.directoryDescriptor,
            backupName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        if backupDescriptor >= 0 {
            var metadata = stat()
            if
                fstat(backupDescriptor, &metadata) == 0,
                metadata.st_mode & S_IFMT == S_IFREG,
                metadata.st_nlink == 1
            {
                _ = fchmod(
                    backupDescriptor,
                    S_IRUSR | S_IWUSR
                )
            }
            Darwin.close(backupDescriptor)
        }
        _ = fsync(persistenceLease.directoryDescriptor)
        return backupName
    }

    nonisolated private static func readStateData(
        at url: URL,
        hardenPermissions: Bool,
        interposition: (@Sendable () -> Void)?
    ) throws -> StateFileRead {
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw StatePersistenceError.posix(code: errno)
        }
        return try readStateData(
            from: descriptor,
            hardenPermissions: hardenPermissions,
            interposition: interposition
        )
    }

    nonisolated private static func readStateData(
        in directoryDescriptor: Int32,
        hardenPermissions: Bool,
        interposition: (@Sendable () -> Void)?
    ) throws -> StateFileRead {
        let descriptor = openat(
            directoryDescriptor,
            "state.json",
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw StatePersistenceError.posix(code: errno)
        }
        return try readStateData(
            from: descriptor,
            hardenPermissions: hardenPermissions,
            interposition: interposition
        )
    }

    nonisolated private static func readStateData(
        from descriptor: Int32,
        hardenPermissions: Bool,
        interposition: (@Sendable () -> Void)?
    ) throws -> StateFileRead {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw StatePersistenceError.posix(code: code)
        }
        guard
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_nlink == 1
        else {
            Darwin.close(descriptor)
            throw StatePersistenceError.notRegularFile
        }
        if hardenPermissions {
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw StatePersistenceError.posix(code: code)
            }
            guard fstat(descriptor, &metadata) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw StatePersistenceError.posix(code: code)
            }
        }
        guard
            metadata.st_size >= 0,
            metadata.st_size <= off_t(maximumStateFileSize)
        else {
            Darwin.close(descriptor)
            throw StatePersistenceError.stateTooLarge(
                actualBytes: Int(max(0, metadata.st_size)),
                maximumBytes: maximumStateFileSize
            )
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var data = Data()
        while true {
            let remainingAllowance = maximumStateFileSize - data.count
            let requestedBytes = min(128 * 1024, remainingAllowance + 1)
            guard
                let chunk = try handle.read(upToCount: requestedBytes),
                !chunk.isEmpty
            else {
                break
            }
            data.append(chunk)
            guard data.count <= maximumStateFileSize else {
                throw StatePersistenceError.stateTooLarge(
                    actualBytes: data.count,
                    maximumBytes: maximumStateFileSize
                )
            }
        }
        interposition?()
        var finalMetadata = stat()
        guard fstat(descriptor, &finalMetadata) == 0 else {
            throw StatePersistenceError.posix(code: errno)
        }
        guard
            finalMetadata.st_mode & S_IFMT == S_IFREG,
            finalMetadata.st_nlink == 1,
            finalMetadata.st_dev == metadata.st_dev,
            finalMetadata.st_ino == metadata.st_ino,
            finalMetadata.st_size == metadata.st_size,
            finalMetadata.st_size == off_t(data.count),
            finalMetadata.st_mtimespec.tv_sec
                == metadata.st_mtimespec.tv_sec,
            finalMetadata.st_mtimespec.tv_nsec
                == metadata.st_mtimespec.tv_nsec,
            finalMetadata.st_ctimespec.tv_sec
                == metadata.st_ctimespec.tv_sec,
            finalMetadata.st_ctimespec.tv_nsec
                == metadata.st_ctimespec.tv_nsec
        else {
            throw StatePersistenceError.stateChangedDuringRead
        }
        return StateFileRead(
            data: data,
            identity: StateFileIdentity(
                device: metadata.st_dev,
                inode: metadata.st_ino
            )
        )
    }

    nonisolated private static func posixDescription(_ code: Int32) -> String {
        String(validatingCString: strerror(code))
            ?? "POSIX error \(code)"
    }

    private func isUnmodifiedLegacyOfficialPrice(_ price: ModelPrice) -> Bool {
        guard price.sourceURL == nil else { return false }
        let legacy: [String: (Double, Double, Double, Double)] = [
            "gpt-5.6-sol": (5, 0.5, 6.25, 30),
            "gpt-5.6-terra": (2.5, 0.25, 3.125, 15),
            "gpt-5.6-luna": (1, 0.1, 1.25, 6),
        ]
        guard let expected = legacy[price.modelPattern] else { return false }
        return price.inputPerMillion == expected.0
            && price.cachedInputPerMillion == expected.1
            && price.cacheWritePerMillion == expected.2
            && price.outputPerMillion == expected.3
    }
}

struct DashboardSnapshot {
    let interval: DateInterval
    let summary: UsageSummary
    let dailyRows: [DailyUsage]
    let modelRows: [ModelUsage]
    let chartSegments: [DailyChartSegment]
    let dailyTotals: [(date: Date, summary: UsageSummary)]

    func withInterval(_ interval: DateInterval) -> DashboardSnapshot {
        DashboardSnapshot(
            interval: interval,
            summary: summary,
            dailyRows: dailyRows,
            modelRows: modelRows,
            chartSegments: chartSegments,
            dailyTotals: dailyTotals
        )
    }
}

private struct DashboardCacheEntry {
    let snapshot: DashboardSnapshot
    let nextFutureRecordTimestamp: Date?
}

private struct MenuSummaryCache {
    let dayStart: Date
    let weekStart: Date
    var today: UsageSummary
    var week: UsageSummary
}

private struct PersistedState: Codable, Sendable {
    var schemaVersion: Int?
    var records: [UsageRecord]
    var prices: [ModelPrice]
    var sourceKind: UsageSourceKind
    var importedFileName: String?
    var accountUsage: AccountUsageSnapshot?
    var knownModels: [CodexModelInfo]?
    var lastLocalScanAt: Date?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case records
        case prices
        case sourceKind
        case importedFileName
        case accountUsage
        case knownModels
        case lastLocalScanAt
    }

    init(
        schemaVersion: Int?,
        records: [UsageRecord],
        prices: [ModelPrice],
        sourceKind: UsageSourceKind,
        importedFileName: String?,
        accountUsage: AccountUsageSnapshot?,
        knownModels: [CodexModelInfo]?,
        lastLocalScanAt: Date?
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
        self.prices = prices
        self.sourceKind = sourceKind
        self.importedFileName = importedFileName
        self.accountUsage = accountUsage
        self.knownModels = knownModels
        self.lastLocalScanAt = lastLocalScanAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        )
        guard
            schemaVersion.map({ (1...4).contains($0) }) ?? true
        else {
            throw StatePersistenceError.invalidState(
                "неподдерживаемая версия schemaVersion"
            )
        }
        records = try container.decodeBoundedArray(
            PersistedUsageRecord.self,
            forKey: .records,
            maximum: UsageLimits.maximumRetainedRecords,
            label: "records"
        ).map(\.record)
        prices = try container.decodeBoundedArray(
            ModelPrice.self,
            forKey: .prices,
            maximum: UsageStateLimits.maximumPrices,
            label: "prices"
        )
        guard Set(prices.map(\.id)).count == prices.count else {
            throw StatePersistenceError.invalidState(
                "prices содержит повторяющиеся UUID"
            )
        }
        sourceKind = try container.decode(
            UsageSourceKind.self,
            forKey: .sourceKind
        )
        importedFileName = try container.decodeIfPresent(
            String.self,
            forKey: .importedFileName
        )
        guard
            importedFileName.map({
                $0.utf8.count <= UsageLimits.maximumGenericStringBytes
            }) ?? true
        else {
            throw StatePersistenceError.invalidState(
                "importedFileName превышает допустимую длину"
            )
        }
        accountUsage = try container.decodeIfPresent(
            PersistedAccountUsage.self,
            forKey: .accountUsage
        )?.snapshot
        knownModels = try container.decodeBoundedArrayIfPresent(
            PersistedCodexModelInfo.self,
            forKey: .knownModels,
            maximum: UsageStateLimits.maximumKnownModels,
            label: "knownModels"
        )?.map(\.model)
        lastLocalScanAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastLocalScanAt
        )
        guard
            lastLocalScanAt.map({
                UsageLimits.isPlausibleTimestamp($0)
            }) ?? true
        else {
            throw StatePersistenceError.invalidState(
                "lastLocalScanAt содержит неправдоподобную дату"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(schemaVersion, forKey: .schemaVersion)
        try container.encode(records, forKey: .records)
        try container.encode(prices, forKey: .prices)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encodeIfPresent(
            importedFileName,
            forKey: .importedFileName
        )
        try container.encodeIfPresent(accountUsage, forKey: .accountUsage)
        try container.encodeIfPresent(knownModels, forKey: .knownModels)
        try container.encodeIfPresent(lastLocalScanAt, forKey: .lastLocalScanAt)
    }

    func validateForPersistence() throws {
        guard
            schemaVersion.map({ (1...4).contains($0) }) ?? true
        else {
            throw StatePersistenceError.invalidState(
                "неподдерживаемая версия schemaVersion"
            )
        }
        try Self.validateCount(
            records.count,
            maximum: UsageLimits.maximumRetainedRecords,
            label: "records"
        )
        try Self.validateCount(
            prices.count,
            maximum: UsageStateLimits.maximumPrices,
            label: "prices"
        )
        if let knownModels {
            try Self.validateCount(
                knownModels.count,
                maximum: UsageStateLimits.maximumKnownModels,
                label: "knownModels"
            )
        }
        if let dailyUsageBuckets = accountUsage?.dailyUsageBuckets {
            try Self.validateCount(
                dailyUsageBuckets.count,
                maximum: UsageStateLimits.maximumDailyUsageBuckets,
                label: "accountUsage.dailyUsageBuckets"
            )
        }
        guard Set(prices.map(\.id)).count == prices.count else {
            throw StatePersistenceError.invalidState(
                "prices содержит повторяющиеся UUID"
            )
        }
        for price in prices {
            guard
                price.modelPattern.utf8.count
                    <= UsageLimits.maximumModelBytes,
                price.sourceURL.map({
                    $0.utf8.count
                        <= UsageLimits.maximumPriceSourceURLBytes
                }) ?? true,
                price.lastUpdated.map({
                    UsageLimits.isPlausibleTimestamp($0)
                }) ?? true
            else {
                throw StatePersistenceError.invalidState(
                    "prices содержит некорректные поля"
                )
            }
        }
        guard
            importedFileName.map({
                $0.utf8.count <= UsageLimits.maximumGenericStringBytes
            }) ?? true,
            lastLocalScanAt.map({
                UsageLimits.isPlausibleTimestamp($0)
            }) ?? true
        else {
            throw StatePersistenceError.invalidState(
                "метаданные state содержат некорректные поля"
            )
        }
        if let accountUsage {
            try Self.validateAccountUsage(accountUsage)
        }
        for model in knownModels ?? [] {
            guard
                [model.id, model.model, model.displayName]
                    .compactMap({ $0 })
                    .allSatisfy({
                        $0.utf8.count
                            <= UsageLimits.maximumGenericStringBytes
                    })
            else {
                throw StatePersistenceError.invalidState(
                    "knownModels содержит слишком длинную строку"
                )
            }
        }
    }

    private static func validateAccountUsage(
        _ snapshot: AccountUsageSnapshot
    ) throws {
        let counters = [
            snapshot.summary.lifetimeTokens,
            snapshot.summary.peakDailyTokens,
            snapshot.summary.longestRunningTurnSec,
            snapshot.summary.currentStreakDays,
            snapshot.summary.longestStreakDays,
        ].compactMap({ $0 })
        guard
            counters.allSatisfy({
                (0...UsageLimits.maximumTokenCount).contains($0)
            }),
            UsageLimits.isPlausibleTimestamp(snapshot.fetchedAt),
            snapshot.codexExecutable.map({
                !$0.isEmpty
                    && $0.utf8.count
                        <= UsageLimits.maximumGenericStringBytes
            }) ?? true
        else {
            throw StatePersistenceError.invalidState(
                "accountUsage содержит некорректные поля"
            )
        }
        var dates = Set<Date>()
        for bucket in snapshot.dailyUsageBuckets ?? [] {
            guard
                let date = bucket.date,
                UsageLimits.isPlausibleTimestamp(date),
                (0...UsageLimits.maximumTokenCount)
                    .contains(bucket.tokens),
                dates.insert(date).inserted
            else {
                throw StatePersistenceError.invalidState(
                    "accountUsage.dailyUsageBuckets содержит "
                        + "некорректную или повторяющуюся дату"
                )
            }
        }
    }

    private static func validateCount(
        _ actual: Int,
        maximum: Int,
        label: String
    ) throws {
        guard actual <= maximum else {
            throw StatePersistenceError.tooManyStateItems(
                name: label,
                actual: actual,
                maximum: maximum
            )
        }
    }
}

private struct PersistedUsageRecord: Decodable {
    let record: UsageRecord

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case model
        case inputTokens
        case cachedInputTokens
        case cacheWriteTokens
        case outputTokens
        case source
        case reasoningOutputTokens
        case serviceTier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timestamp = try container.decode(Date.self, forKey: .timestamp)
        let model = try container.decode(String.self, forKey: .model)
        let inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        let outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        let source = try container.decode(String.self, forKey: .source)
        let cachedInputTokens = try container.decodeIfPresent(
            Int.self,
            forKey: .cachedInputTokens
        ) ?? 0
        let cacheWriteTokens = try container.decodeIfPresent(
            Int.self,
            forKey: .cacheWriteTokens
        ) ?? 0
        let reasoningOutputTokens = try container.decodeIfPresent(
            Int.self,
            forKey: .reasoningOutputTokens
        )
        let serviceTier = try container.decodeIfPresent(
            String.self,
            forKey: .serviceTier
        )

        guard
            UsageLimits.isPlausibleTimestamp(timestamp),
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            model.utf8.count <= UsageLimits.maximumModelBytes,
            (0...UsageLimits.maximumTokenCount).contains(inputTokens),
            (0...UsageLimits.maximumTokenCount).contains(outputTokens),
            (0...inputTokens).contains(cachedInputTokens),
            (0...(inputTokens - cachedInputTokens)).contains(cacheWriteTokens),
            source.utf8.count <= UsageLimits.maximumSourceBytes,
            !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (reasoningOutputTokens.map {
                (0...outputTokens).contains($0)
            } ?? true),
            (serviceTier.map {
                $0.utf8.count <= UsageLimits.maximumServiceTierBytes
            } ?? true)
        else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Persisted usage record has invalid required fields"
                )
            )
        }

        record = UsageRecord(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            timestamp: timestamp,
            model: model,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteTokens: cacheWriteTokens,
            outputTokens: outputTokens,
            source: source,
            reasoningOutputTokens: reasoningOutputTokens,
            serviceTier: serviceTier
        )
    }
}

private struct PersistedAccountUsage: Decodable {
    let snapshot: AccountUsageSnapshot

    private enum CodingKeys: String, CodingKey {
        case summary
        case dailyUsageBuckets
        case fetchedAt
        case codexExecutable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let summary = try container.decode(
            PersistedAccountUsageSummary.self,
            forKey: .summary
        ).summary
        let persistedBuckets =
            try container.decodeBoundedArrayIfPresent(
                PersistedAccountUsageBucket.self,
                forKey: .dailyUsageBuckets,
                maximum: UsageStateLimits.maximumDailyUsageBuckets,
                label: "accountUsage.dailyUsageBuckets"
            )
        let buckets = persistedBuckets?.map(\.bucket)
        if let buckets {
            let dates = buckets.compactMap(\.date)
            guard
                dates.count == buckets.count,
                Set(dates).count == dates.count
            else {
                throw StatePersistenceError.invalidState(
                    "accountUsage.dailyUsageBuckets содержит "
                        + "повторяющиеся даты"
                )
            }
        }
        let fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        let codexExecutable = try container.decodeIfPresent(
            String.self,
            forKey: .codexExecutable
        )
        guard
            UsageLimits.isPlausibleTimestamp(fetchedAt),
            codexExecutable.map({
                !$0.isEmpty
                    && $0.utf8.count
                        <= UsageLimits.maximumGenericStringBytes
            }) ?? true
        else {
            throw StatePersistenceError.invalidState(
                "accountUsage содержит некорректные метаданные"
            )
        }
        snapshot = AccountUsageSnapshot(
            summary: summary,
            dailyUsageBuckets: buckets,
            fetchedAt: fetchedAt,
            codexExecutable: codexExecutable
        )
    }
}

private struct PersistedAccountUsageSummary: Decodable {
    let summary: AccountUsageSummary

    private enum CodingKeys: String, CodingKey {
        case lifetimeTokens
        case peakDailyTokens
        case longestRunningTurnSec
        case currentStreakDays
        case longestStreakDays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lifetimeTokens = try container.decodeIfPresent(
            Int.self,
            forKey: .lifetimeTokens
        )
        let peakDailyTokens = try container.decodeIfPresent(
            Int.self,
            forKey: .peakDailyTokens
        )
        let longestRunningTurnSec = try container.decodeIfPresent(
            Int.self,
            forKey: .longestRunningTurnSec
        )
        let currentStreakDays = try container.decodeIfPresent(
            Int.self,
            forKey: .currentStreakDays
        )
        let longestStreakDays = try container.decodeIfPresent(
            Int.self,
            forKey: .longestStreakDays
        )
        guard
            [
                lifetimeTokens,
                peakDailyTokens,
                longestRunningTurnSec,
                currentStreakDays,
                longestStreakDays,
            ]
            .compactMap({ $0 })
            .allSatisfy({
                (0...UsageLimits.maximumTokenCount).contains($0)
            })
        else {
            throw StatePersistenceError.invalidState(
                "accountUsage.summary содержит некорректный счётчик"
            )
        }
        summary = AccountUsageSummary(
            lifetimeTokens: lifetimeTokens,
            peakDailyTokens: peakDailyTokens,
            longestRunningTurnSec: longestRunningTurnSec,
            currentStreakDays: currentStreakDays,
            longestStreakDays: longestStreakDays
        )
    }
}

private struct PersistedAccountUsageBucket: Decodable {
    let bucket: AccountUsageDailyBucket

    private enum CodingKeys: String, CodingKey {
        case startDate
        case tokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let startDate = try container.decode(
            String.self,
            forKey: .startDate
        )
        let tokens = try container.decode(Int.self, forKey: .tokens)
        guard
            startDate.utf8.count <= UsageLimits.maximumGenericStringBytes,
            let date = DateParsing.parse(startDate),
            UsageLimits.isPlausibleTimestamp(date),
            (0...UsageLimits.maximumTokenCount).contains(tokens)
        else {
            throw StatePersistenceError.invalidState(
                "accountUsage.dailyUsageBuckets содержит некорректную запись"
            )
        }
        bucket = AccountUsageDailyBucket(
            startDate: startDate,
            tokens: tokens
        )
    }
}

private struct PersistedCodexModelInfo: Decodable {
    let model: CodexModelInfo

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case displayName
        case hidden
        case isDefault
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(String.self, forKey: .id)
        let modelName = try container.decodeIfPresent(
            String.self,
            forKey: .model
        )
        let displayName = try container.decodeIfPresent(
            String.self,
            forKey: .displayName
        )
        guard
            [id, modelName, displayName]
                .compactMap({ $0 })
                .allSatisfy({
                    $0.utf8.count
                        <= UsageLimits.maximumGenericStringBytes
                })
        else {
            throw StatePersistenceError.invalidState(
                "knownModels содержит слишком длинную строку"
            )
        }
        model = CodexModelInfo(
            id: id,
            model: modelName,
            displayName: displayName,
            hidden: try container.decodeIfPresent(
                Bool.self,
                forKey: .hidden
            ),
            isDefault: try container.decodeIfPresent(
                Bool.self,
                forKey: .isDefault
            )
        )
    }
}

private extension KeyedDecodingContainer {
    func decodeBoundedArray<Element: Decodable>(
        _ type: Element.Type,
        forKey key: Key,
        maximum: Int,
        label: String
    ) throws -> [Element] {
        var values = try nestedUnkeyedContainer(forKey: key)
        if let count = values.count, count > maximum {
            throw StatePersistenceError.tooManyStateItems(
                name: label,
                actual: count,
                maximum: maximum
            )
        }

        var result: [Element] = []
        result.reserveCapacity(min(values.count ?? 0, maximum))
        while !values.isAtEnd {
            guard result.count < maximum else {
                throw StatePersistenceError.tooManyStateItems(
                    name: label,
                    actual: result.count + 1,
                    maximum: maximum
                )
            }
            result.append(try values.decode(type))
        }
        return result
    }

    func decodeBoundedArrayIfPresent<Element: Decodable>(
        _ type: Element.Type,
        forKey key: Key,
        maximum: Int,
        label: String
    ) throws -> [Element]? {
        guard contains(key), try !decodeNil(forKey: key) else {
            return nil
        }
        return try decodeBoundedArray(
            type,
            forKey: key,
            maximum: maximum,
            label: label
        )
    }
}

private enum StateLoadResult {
    case missing
    case loaded
    case corrupt(reason: String, backupName: String?)
}

private struct StateFileIdentity: Sendable {
    let device: dev_t
    let inode: ino_t
}

private struct StateFileRead: Sendable {
    let data: Data
    let identity: StateFileIdentity
}

private enum StatePersistenceError: LocalizedError {
    case unsafeStorageDirectory
    case unsafeLockFile
    case concurrentWriter
    case notRegularFile
    case stateChangedDuringRead
    case posix(code: Int32)
    case stateTooLarge(actualBytes: Int, maximumBytes: Int)
    case tooManyStateItems(name: String, actual: Int, maximum: Int)
    case invalidState(String)
    case unavailable(String)

    var allowsReadOnlyStateAccess: Bool {
        if case .concurrentWriter = self {
            return true
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .unsafeStorageDirectory:
            "каталог локального состояния не является безопасным обычным каталогом"
        case .unsafeLockFile:
            "файл writer lease не является безопасным обычным файлом"
        case .concurrentWriter:
            "другой экземпляр приложения уже сохраняет настройки; закройте его и перезапустите этот экземпляр"
        case .notRegularFile:
            "state.json не является обычным файлом"
        case .stateChangedDuringRead:
            "state.json изменился во время безопасного чтения"
        case .posix(let code):
            String(validatingCString: strerror(code))
                ?? "POSIX error \(code)"
        case .stateTooLarge(let actualBytes, let maximumBytes):
            "state.json слишком велик (\(actualBytes) байт; максимум \(maximumBytes))"
        case .tooManyStateItems(let name, let actual, let maximum):
            "\(name) содержит \(actual) элементов; максимум \(maximum)"
        case .invalidState(let description):
            "state.json содержит недопустимые данные: \(description)"
        case .unavailable(let description):
            description
        }
    }
}

private final class StatePersistenceLease: @unchecked Sendable {
    let directoryDescriptor: Int32
    private let lockDescriptor: Int32

    private init(
        directoryDescriptor: Int32,
        lockDescriptor: Int32
    ) {
        self.directoryDescriptor = directoryDescriptor
        self.lockDescriptor = lockDescriptor
    }

    deinit {
        _ = flock(lockDescriptor, LOCK_UN)
        Darwin.close(lockDescriptor)
        Darwin.close(directoryDescriptor)
    }

    static func acquire(storageDirectory: URL) throws -> StatePersistenceLease {
        let directoryDescriptor: Int32
        do {
            directoryDescriptor = try DescriptorDirectory.openOrCreate(
                at: storageDirectory
            )
        } catch DescriptorDirectoryError.invalidAbsolutePath {
            throw StatePersistenceError.unsafeStorageDirectory
        } catch DescriptorDirectoryError.unsafeComponent {
            throw StatePersistenceError.unsafeStorageDirectory
        } catch DescriptorDirectoryError.missing {
            throw StatePersistenceError.unsafeStorageDirectory
        } catch DescriptorDirectoryError.posix(let code) {
            throw StatePersistenceError.posix(code: code)
        }

        do {
            var directoryMetadata = stat()
            guard
                fstat(directoryDescriptor, &directoryMetadata) == 0
            else {
                throw StatePersistenceError.posix(code: errno)
            }
            guard directoryMetadata.st_mode & S_IFMT == S_IFDIR else {
                throw StatePersistenceError.unsafeStorageDirectory
            }

            let lockDescriptor = openat(
                directoryDescriptor,
                ".state.lock",
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                S_IRUSR | S_IWUSR
            )
            guard lockDescriptor >= 0 else {
                if errno == ELOOP {
                    throw StatePersistenceError.unsafeLockFile
                }
                throw StatePersistenceError.posix(code: errno)
            }

            do {
                var lockMetadata = stat()
                guard fstat(lockDescriptor, &lockMetadata) == 0 else {
                    throw StatePersistenceError.posix(code: errno)
                }
                guard
                    lockMetadata.st_mode & S_IFMT == S_IFREG,
                    lockMetadata.st_nlink == 1
                else {
                    throw StatePersistenceError.unsafeLockFile
                }
                guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                    if errno == EWOULDBLOCK || errno == EAGAIN {
                        throw StatePersistenceError.concurrentWriter
                    }
                    throw StatePersistenceError.posix(code: errno)
                }
                guard
                    fchmod(
                        directoryDescriptor,
                        S_IRWXU
                    ) == 0
                else {
                    throw StatePersistenceError.posix(code: errno)
                }
                guard
                    fchmod(
                        lockDescriptor,
                        S_IRUSR | S_IWUSR
                    ) == 0
                else {
                    throw StatePersistenceError.posix(code: errno)
                }
                return StatePersistenceLease(
                    directoryDescriptor: directoryDescriptor,
                    lockDescriptor: lockDescriptor
                )
            } catch {
                _ = flock(lockDescriptor, LOCK_UN)
                Darwin.close(lockDescriptor)
                throw error
            }
        } catch {
            Darwin.close(directoryDescriptor)
            throw error
        }
    }
}

private struct CrossSourceUsageKey: Hashable {
    let model: String
    let serviceTier: String
    let inputTokens: Int
    let cachedInputTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int

    init(record: UsageRecord) {
        model = record.model.lowercased()
        serviceTier = (record.serviceTier ?? "default").lowercased()
        inputTokens = record.inputTokens
        cachedInputTokens = record.cachedInputTokens
        cacheWriteTokens = record.cacheWriteTokens
        outputTokens = record.outputTokens
        reasoningOutputTokens = record.reasoningOutputTokens ?? 0
    }
}

private struct CrossSourceLocalMatchKey: Hashable {
    let usage: CrossSourceUsageKey
    let timestamp: TimeInterval

    init(record: UsageRecord) {
        usage = CrossSourceUsageKey(record: record)
        timestamp = record.timestamp.timeIntervalSince1970
    }

    init(usage: CrossSourceUsageKey, timestamp: TimeInterval) {
        self.usage = usage
        self.timestamp = timestamp
    }
}

private struct CrossSourceLiveCandidate {
    let index: Int
    let timestamp: TimeInterval
}

private struct CrossSourceMatch {
    let liveIndex: Int
    let localKey: CrossSourceLocalMatchKey
}

private struct CrossSourceReconciliation {
    let records: [UsageRecord]
    let observations: Set<UsageRecordSignature>
    let recordSignatures: Set<UsageRecordSignature>
    let addedRecords: [UsageRecord]
}

private struct DayModelKey: Hashable {
    let day: Date
    let model: String
}
