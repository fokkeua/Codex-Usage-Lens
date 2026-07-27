import Foundation
import Testing
@testable import CodexUsageMenuBar

@Test("Повреждённый state сохраняется отдельно и не заменяется demo-данными")
@MainActor
func corruptStateIsQuarantinedWithoutOverwrite() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: storage,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: storage) }
    let stateURL = storage.appendingPathComponent("state.json")
    try Data("{not-json".utf8).write(to: stateURL)

    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: true,
        autoRefreshRealData: false
    )

    #expect(store.records.isEmpty)
    #expect(store.sourceKind == .empty)
    #expect(store.alertMessage?.contains("повреждено") == true)
    #expect(!FileManager.default.fileExists(atPath: stateURL.path))
    let backups = try FileManager.default.contentsOfDirectory(
        at: storage,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("state.corrupt-") }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: backups[0]) == Data("{not-json".utf8))
}

@Test("Primary state load остаётся привязан к directory lease")
@MainActor
func primaryStateLoadUsesPinnedDirectoryDescriptor() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = root.appendingPathComponent("storage", isDirectory: true)
    let detached = root.appendingPathComponent("detached", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: storage,
        withIntermediateDirectories: true
    )
    let oldRecord =
        #"{"timestamp":1785052800,"model":"pinned-old","inputTokens":3,"outputTokens":1,"source":"test"}"#
    let replacementRecord =
        #"{"timestamp":1785052800,"model":"replacement","inputTokens":4,"outputTokens":1,"source":"test"}"#
    try Data(
        qaStateDocument(records: "[\(oldRecord)]").utf8
    ).write(to: storage.appendingPathComponent("state.json"))

    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false,
        beforeStateLoad: {
            try! FileManager.default.moveItem(
                at: storage,
                to: detached
            )
            try! FileManager.default.createDirectory(
                at: storage,
                withIntermediateDirectories: true
            )
            try! Data(
                qaStateDocument(records: "[\(replacementRecord)]").utf8
            ).write(to: storage.appendingPathComponent("state.json"))
        }
    )

    #expect(store.records.first?.model == "pinned-old")
    let replacementData = try Data(
        contentsOf: storage.appendingPathComponent("state.json")
    )
    #expect(String(decoding: replacementData, as: UTF8.self).contains("replacement"))
}

@Test("Quarantine не переименовывает state с новым inode")
@MainActor
func quarantineRequiresOpenedStateIdentity() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    try FileManager.default.createDirectory(
        at: storage,
        withIntermediateDirectories: true
    )
    let stateURL = storage.appendingPathComponent("state.json")
    try Data("{broken".utf8).write(to: stateURL)
    let replacement = Data(qaStateDocument().utf8)

    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false,
        stateReadInterposition: {
            try! FileManager.default.removeItem(at: stateURL)
            try! replacement.write(to: stateURL)
        }
    )

    #expect(store.records.isEmpty)
    #expect(try Data(contentsOf: stateURL) == replacement)
    #expect(
        try FileManager.default.contentsOfDirectory(
            atPath: storage.path
        ).allSatisfy { !$0.hasPrefix("state.corrupt-") }
    )
    #expect(
        store.alertMessage?.contains("оставлен без изменений") == true
    )
}

@Test("State loader отклоняет same-inode mutation во время чтения")
@MainActor
func stateLoadDetectsConcurrentSameInodeMutation() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    try FileManager.default.createDirectory(
        at: storage,
        withIntermediateDirectories: true
    )
    let stateURL = storage.appendingPathComponent("state.json")
    let firstRecord =
        #"{"timestamp":1785052800,"model":"aaaa","inputTokens":3,"outputTokens":1,"source":"test"}"#
    let secondRecord =
        #"{"timestamp":1785052800,"model":"bbbb","inputTokens":3,"outputTokens":1,"source":"test"}"#
    let first = Data(
        qaStateDocument(records: "[\(firstRecord)]").utf8
    )
    let second = Data(
        qaStateDocument(records: "[\(secondRecord)]").utf8
    )
    #expect(first.count == second.count)
    try first.write(to: stateURL)

    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false,
        stateDescriptorReadInterposition: {
            try! second.write(to: stateURL)
        }
    )

    #expect(store.records.isEmpty)
    #expect(
        store.alertMessage?.contains("изменился во время") == true
    )
    #expect(try Data(contentsOf: stateURL) == second)
}

@Test("Persisted usage требует обязательные поля, но принимает старые optional")
@MainActor
func persistedUsageRecordUsesStrictRequiredFields() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let corruptStorage = root.appendingPathComponent(
        "missing-required",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: corruptStorage,
        withIntermediateDirectories: true
    )
    try Data(qaStateDocument(records: "[{}]").utf8).write(
        to: corruptStorage.appendingPathComponent("state.json")
    )
    let corrupt = UsageStore(
        storageDirectory: corruptStorage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    #expect(corrupt.records.isEmpty)
    #expect(corrupt.alertMessage?.contains("повреждено") == true)
    #expect(
        try FileManager.default.contentsOfDirectory(
            atPath: corruptStorage.path
        ).contains { $0.hasPrefix("state.corrupt-") }
    )

    let compatibleStorage = root.appendingPathComponent(
        "optional-omitted",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: compatibleStorage,
        withIntermediateDirectories: true
    )
    let legacyRecord =
        #"{"timestamp":1785052800,"model":"legacy","inputTokens":3,"outputTokens":1,"source":"old"}"#
    try Data(
        qaStateDocument(records: "[\(legacyRecord)]").utf8
    ).write(to: compatibleStorage.appendingPathComponent("state.json"))
    let compatible = UsageStore(
        storageDirectory: compatibleStorage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    #expect(compatible.records.count == 1)
    #expect(compatible.records.first?.cachedInputTokens == 0)
    #expect(compatible.records.first?.reasoningOutputTokens == nil)
}

@Test("State quarantines malformed persisted metadata")
@MainActor
func persistedStateRejectsMalformedMetadata() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let huge = String(repeating: "x", count: 4_097)
    let priceID = UUID().uuidString
    let duplicatePrice =
        #"{"id":"\#(priceID)","modelPattern":"m","inputPerMillion":1,"cachedInputPerMillion":0,"outputPerMillion":1}"#
    let cases: [(String, String)] = [
        (
            "schema",
            qaStateDocument(schemaVersion: "5")
        ),
        (
            "filename",
            qaStateDocument(importedFileName: "\"\(huge)\"")
        ),
        (
            "scan-date",
            qaStateDocument(lastLocalScanAt: "1")
        ),
        (
            "duplicate-price-id",
            qaStateDocument(
                prices: "[\(duplicatePrice),\(duplicatePrice)]"
            )
        ),
        (
            "known-model-string",
            qaStateDocument(
                knownModels: #"[{"id":"\#(huge)"}]"#
            )
        ),
        (
            "negative-account",
            qaStateDocument(
                accountUsage:
                    #"{"summary":{"lifetimeTokens":-1},"dailyUsageBuckets":[],"fetchedAt":1785052800}"#
            )
        ),
        (
            "duplicate-account-date",
            qaStateDocument(
                accountUsage:
                    #"{"summary":{},"dailyUsageBuckets":[{"startDate":"2026-07-26","tokens":1},{"startDate":"2026-07-26","tokens":2}],"fetchedAt":1785052800}"#
            )
        ),
        (
            "account-executable",
            qaStateDocument(
                accountUsage:
                    #"{"summary":{},"dailyUsageBuckets":[],"fetchedAt":1785052800,"codexExecutable":"\#(huge)"}"#
            )
        ),
    ]

    for (name, document) in cases {
        let storage = root.appendingPathComponent(
            name,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: true
        )
        try Data(document.utf8).write(
            to: storage.appendingPathComponent("state.json")
        )
        let store = UsageStore(
            storageDirectory: storage,
            seedDemoIfNeeded: false,
            autoRefreshRealData: false
        )
        #expect(
            store.alertMessage?.contains("повреждено") == true,
            "case \(name)"
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: storage.path
            ).contains { $0.hasPrefix("state.corrupt-") },
            "case \(name)"
        )
    }
}

@Test("Пустой store и очистка используют честное состояние без источника")
@MainActor
func emptyStoreUsesEmptySourceKind() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )

    #expect(store.sourceKind == .empty)
    #expect(store.records.isEmpty)

    store.loadDemoData()
    #expect(store.sourceKind == .demo)
    #expect(!store.records.isEmpty)
    store.clearUsageData()

    #expect(store.sourceKind == .empty)
    #expect(store.sourceSubtitle == "Детализированные данные очищены")
    #expect(store.records.isEmpty)
}

@Test("Ошибка повторной синхронизации явно помечает сохранённый account snapshot устаревшим")
@MainActor
func failedAccountRefreshMarksRetainedSnapshotStale() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    let snapshot = AccountUsageSnapshot(
        summary: AccountUsageSummary(
            lifetimeTokens: 42,
            peakDailyTokens: nil,
            longestRunningTurnSec: nil,
            currentStreakDays: nil,
            longestStreakDays: nil
        ),
        dailyUsageBuckets: [],
        fetchedAt: Date(),
        codexExecutable: nil
    )
    store.applyAccountSyncResult(.success(
        CodexAccountResult(usage: snapshot, models: [])
    ))
    #expect(store.accountSyncHasError == false)
    #expect(store.accountUsage?.summary.lifetimeTokens == 42)

    store.applyAccountSyncResult(.failure(CodexAppServerError.timeout))

    #expect(store.accountSyncHasError)
    #expect(store.hasRefreshError)
    #expect(store.accountUsage?.summary.lifetimeTokens == 42)
    #expect(store.accountSyncStatus.contains("Ошибка"))
}

@Test("Некорректный account result не заменяет последнее валидное состояние")
@MainActor
func invalidAccountResultRollsBack() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    let valid = AccountUsageSnapshot(
        summary: AccountUsageSummary(
            lifetimeTokens: 42,
            peakDailyTokens: nil,
            longestRunningTurnSec: nil,
            currentStreakDays: nil,
            longestStreakDays: nil
        ),
        dailyUsageBuckets: [],
        fetchedAt: Date(timeIntervalSince1970: 1_785_052_800),
        codexExecutable: nil
    )
    store.applyAccountSyncResult(
        .success(CodexAccountResult(usage: valid, models: []))
    )
    let invalid = AccountUsageSnapshot(
        summary: AccountUsageSummary(
            lifetimeTokens: -1,
            peakDailyTokens: nil,
            longestRunningTurnSec: nil,
            currentStreakDays: nil,
            longestStreakDays: nil
        ),
        dailyUsageBuckets: [],
        fetchedAt: valid.fetchedAt,
        codexExecutable: nil
    )

    store.applyAccountSyncResult(
        .success(CodexAccountResult(usage: invalid, models: []))
    )

    #expect(store.accountUsage == valid)
    #expect(store.accountSyncHasError)
    #expect(store.accountSyncStatus.contains("не применены"))
}

@Test("Неудачный импорт завершает статус вместо вечного «Импортируется»")
@MainActor
func failedImportUpdatesLastActionStatus() async throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let input = storage.appendingPathComponent("broken.json")
    try FileManager.default.createDirectory(
        at: storage,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: storage) }
    try Data("{broken".utf8).write(to: input)
    let store = UsageStore(
        storageDirectory: storage.appendingPathComponent("state"),
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )

    store.importFile(input)
    for _ in 0..<100 {
        if store.lastImportNote?.contains("не выполнен") == true {
            break
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(store.lastImportNote?.contains("не выполнен") == true)
    #expect(store.lastImportNote?.contains("Импортируется") == false)
    #expect(store.alertMessage != nil)
}

@Test("State записывается с приватными POSIX permissions")
@MainActor
func persistedStateUsesPrivatePermissions() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    store.records = [
        UsageRecord(
            timestamp: Date(),
            model: "model-a",
            inputTokens: 10,
            outputTokens: 2,
            source: "test"
        )
    ]
    store.flushState()

    let directoryAttributes = try FileManager.default.attributesOfItem(
        atPath: storage.path
    )
    let stateAttributes = try FileManager.default.attributesOfItem(
        atPath: storage.appendingPathComponent("state.json").path
    )
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((stateAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test("State loader не следует symbolic link")
@MainActor
func persistedStateRejectsSymbolicLink() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = root.appendingPathComponent("storage", isDirectory: true)
    let outside = root.appendingPathComponent("outside.json")
    try FileManager.default.createDirectory(
        at: storage,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = Data("{\"sentinel\":true}".utf8)
    try sentinel.write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: storage.appendingPathComponent("state.json"),
        withDestinationURL: outside
    )

    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: true,
        autoRefreshRealData: false
    )

    #expect(store.records.isEmpty)
    #expect(try Data(contentsOf: outside) == sentinel)
    #expect(store.alertMessage?.contains("небезопасно") == true)
}

@Test("Live OTel и local rollout одного ответа дедуплицируются по окну")
@MainActor
func liveAndRolloutRecordsUseCrossSourceDedupeWindow() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let timestamp = try #require(DateParsing.parse("2026-07-26T08:00:00Z"))
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    store.records = [
        UsageRecord(
            timestamp: timestamp,
            model: "gpt-test",
            inputTokens: 1_200,
            cachedInputTokens: 400,
            outputTokens: 300,
            source: "codex-local-rollout",
            reasoningOutputTokens: 40,
            serviceTier: "default"
        )
    ]

    store.mergeLiveRecords([
        UsageRecord(
            timestamp: timestamp.addingTimeInterval(6),
            model: "gpt-test",
            inputTokens: 1_200,
            cachedInputTokens: 400,
            outputTokens: 300,
            source: "otel-live",
            reasoningOutputTokens: 40,
            serviceTier: "default"
        )
    ])
    #expect(store.records.count == 1)
    #expect(store.records[0].source == "codex-local-rollout")

    store.mergeLiveRecords([
        UsageRecord(
            timestamp: timestamp.addingTimeInterval(11),
            model: "gpt-test",
            inputTokens: 1_200,
            cachedInputTokens: 400,
            outputTokens: 300,
            source: "otel-live",
            reasoningOutputTokens: 40,
            serviceTier: "default"
        )
    ])
    #expect(store.records.count == 2)
}

@Test("Одна local-запись поглощает не более одной похожей live-записи")
@MainActor
func crossSourceDedupeIsOneToOne() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let timestamp = try #require(DateParsing.parse("2026-07-26T08:00:00Z"))
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    store.records = [
        UsageRecord(
            timestamp: timestamp,
            model: "gpt-test",
            inputTokens: 1_200,
            cachedInputTokens: 400,
            outputTokens: 300,
            source: "codex-local-rollout"
        )
    ]

    store.mergeLiveRecords([
        UsageRecord(
            timestamp: timestamp.addingTimeInterval(1),
            model: "gpt-test",
            inputTokens: 1_200,
            cachedInputTokens: 400,
            outputTokens: 300,
            source: "otel-live"
        ),
        UsageRecord(
            timestamp: timestamp.addingTimeInterval(2),
            model: "gpt-test",
            inputTokens: 1_200,
            cachedInputTokens: 400,
            outputTokens: 300,
            source: "otel-live"
        ),
    ])

    #expect(store.records.count == 2)
    #expect(store.records.filter { $0.source == "otel-live" }.count == 1)
}

@Test("Runtime ledger сохраняет one-to-one между отдельными live callback")
@MainActor
func crossSourceDedupeTracksSequentialMatchesAndReplays() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let timestamp = try #require(
        DateParsing.parse("2026-07-26T08:00:00Z")
    )
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    store.records = [
        UsageRecord(
            timestamp: timestamp,
            model: "gpt-test",
            inputTokens: 1_200,
            cachedInputTokens: 400,
            outputTokens: 300,
            source: "codex-local-rollout"
        ),
    ]

    func liveRecord(offset: TimeInterval) -> UsageRecord {
        UsageRecord(
            timestamp: timestamp.addingTimeInterval(offset),
            model: "gpt-test",
            inputTokens: 1_200,
            cachedInputTokens: 400,
            outputTokens: 300,
            source: "otel-live"
        )
    }

    store.mergeLiveRecords([liveRecord(offset: 1)])
    #expect(store.records.count == 1)
    #expect(store.records.first?.source == "codex-local-rollout")

    store.mergeLiveRecords([liveRecord(offset: 2)])
    #expect(store.records.count == 2)
    let retainedLive = store.records.filter { $0.source == "otel-live" }
    #expect(retainedLive.count == 1)
    #expect(
        retainedLive.first?.timestamp
            == timestamp.addingTimeInterval(2)
    )

    // A new UUID for the paired value is still the same resend. This ledger
    // is intentionally scoped to one process lifetime, not persisted state.
    store.mergeLiveRecords([liveRecord(offset: 1)])
    #expect(store.records.count == 2)
    #expect(
        store.records.filter { $0.source == "otel-live" }
            .map(\.timestamp)
            == [timestamp.addingTimeInterval(2)]
    )
}

@Test("Runtime ledger расходует каждую local-запись отдельно")
@MainActor
func crossSourceDedupeTracksMultipleLocalMatchesAcrossCallbacks() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let timestamp = try #require(
        DateParsing.parse("2026-07-26T08:00:00Z")
    )
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )

    func record(offset: TimeInterval, source: String) -> UsageRecord {
        UsageRecord(
            timestamp: timestamp.addingTimeInterval(offset),
            model: "gpt-test",
            inputTokens: 1_200,
            outputTokens: 300,
            source: source
        )
    }

    store.records = [
        record(offset: 0, source: "codex-local-rollout"),
        record(offset: 20, source: "codex-local-rollout"),
    ]
    store.mergeLiveRecords([record(offset: 5, source: "otel-live")])
    store.mergeLiveRecords([record(offset: 25, source: "otel-live")])
    #expect(store.records.count == 2)
    #expect(
        store.records.allSatisfy {
            $0.source == "codex-local-rollout"
        }
    )

    store.mergeLiveRecords([record(offset: 6, source: "otel-live")])
    #expect(store.records.count == 3)
    #expect(
        store.records.filter { $0.source == "otel-live" }
            .map(\.timestamp)
            == [timestamp.addingTimeInterval(6)]
    )
}

@Test("Очистка records сбрасывает runtime cross-source ledger")
@MainActor
func clearingRecordsPrunesCrossSourceMatchLedger() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let timestamp = try #require(
        DateParsing.parse("2026-07-26T08:00:00Z")
    )
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )

    func record(offset: TimeInterval, source: String) -> UsageRecord {
        UsageRecord(
            timestamp: timestamp.addingTimeInterval(offset),
            model: "gpt-test",
            inputTokens: 1_200,
            outputTokens: 300,
            source: source
        )
    }

    store.records = [record(offset: 0, source: "codex-local-rollout")]
    store.mergeLiveRecords([record(offset: 5, source: "otel-live")])
    #expect(store.records.count == 1)

    store.clearUsageData()
    store.records = [record(offset: 0, source: "codex-local-rollout")]
    store.mergeLiveRecords([record(offset: 6, source: "otel-live")])
    #expect(store.records.count == 1)

    store.mergeLiveRecords([record(offset: 7, source: "otel-live")])
    #expect(store.records.count == 2)
    #expect(
        store.records.filter { $0.source == "otel-live" }
            .map(\.timestamp)
            == [timestamp.addingTimeInterval(7)]
    )
}

@Test("Cross-source matching максимален и не зависит от порядка live batch")
@MainActor
func crossSourceDedupeIsMaximumAndPermutationInvariant() throws {
    let base = try #require(DateParsing.parse("2026-07-26T08:00:00Z"))

    func retainedLiveCount(for liveRecords: [UsageRecord]) -> Int {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let store = UsageStore(
            storageDirectory: storage,
            seedDemoIfNeeded: false,
            autoRefreshRealData: false
        )
        store.records = [0.0, 10.0].map { offset in
            UsageRecord(
                timestamp: base.addingTimeInterval(offset),
                model: "gpt-test",
                inputTokens: 1_200,
                cachedInputTokens: 400,
                outputTokens: 300,
                source: "codex-local-rollout"
            )
        }
        store.mergeLiveRecords(liveRecords)
        #expect(
            store.records.filter {
                $0.source == "codex-local-rollout"
            }.count == 2
        )
        return store.records.filter { $0.source == "otel-live" }.count
    }

    let liveRecords = [9.0, 19.0].map { offset in
        UsageRecord(
            timestamp: base.addingTimeInterval(offset),
            model: "gpt-test",
            inputTokens: 1_200,
            cachedInputTokens: 400,
            outputTokens: 300,
            source: "otel-live"
        )
    }
    // Nearest-first greedily pairs +9 with +10, stranding +19.
    // The maximum matching is (+9 ↔ 0) and (+19 ↔ +10).
    let forward = retainedLiveCount(for: liveRecords)
    let reversed = retainedLiveCount(for: Array(liveRecords.reversed()))
    #expect(forward == 0)
    #expect(reversed == 0)
}

@Test("Cross-source matching не зависит от порядка отдельных callback")
@MainActor
func crossSourceDedupeIsInvariantAcrossCallbackOrder() throws {
    let base = try #require(DateParsing.parse("2026-07-26T08:00:00Z"))

    func retainedSources(for offsets: [TimeInterval]) -> [String] {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let store = UsageStore(
            storageDirectory: storage,
            seedDemoIfNeeded: false,
            autoRefreshRealData: false
        )
        store.records = [0.0, 10.0].map { offset in
            UsageRecord(
                timestamp: base.addingTimeInterval(offset),
                model: "gpt-ambiguous",
                inputTokens: 100,
                outputTokens: 10,
                source: "codex-local-rollout"
            )
        }
        for offset in offsets {
            store.mergeLiveRecords([
                UsageRecord(
                    timestamp: base.addingTimeInterval(offset),
                    model: "gpt-ambiguous",
                    inputTokens: 100,
                    outputTokens: 10,
                    source: "otel-live"
                )
            ])
        }
        return store.records.map(\.source)
    }

    let forward = retainedSources(for: [9, -1])
    let reverse = retainedSources(for: [-1, 9])
    #expect(forward == reverse)
    #expect(forward == ["codex-local-rollout", "codex-local-rollout"])
}

@Test("Exact cross-source duplicate сохраняет authoritative local запись")
@MainActor
func exactCrossSourceDedupeStillPrefersLocal() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let timestamp = try #require(DateParsing.parse("2026-07-26T08:00:00Z"))
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    store.records = [
        UsageRecord(
            timestamp: timestamp,
            model: "gpt-test",
            inputTokens: 1_200,
            outputTokens: 300,
            source: "codex-local-rollout"
        ),
    ]
    let duplicate = UsageRecord(
        timestamp: timestamp,
        model: "gpt-test",
        inputTokens: 1_200,
        outputTokens: 300,
        source: "otel-live"
    )

    store.mergeLiveRecords([duplicate, duplicate])

    #expect(store.records.count == 1)
    #expect(store.records.first?.source == "codex-local-rollout")

    store.mergeLiveRecords([
        UsageRecord(
            timestamp: timestamp.addingTimeInterval(1),
            model: "gpt-test",
            inputTokens: 1_200,
            outputTokens: 300,
            source: "otel-live"
        ),
    ])
    #expect(store.records.count == 2)
    #expect(store.records.filter { $0.source == "otel-live" }.count == 1)
}

@Test("OTel capability создаётся один раз и хранится приватно")
func otelCapabilityIsStableAndPrivate() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }

    let first = try OTelCapabilityStore.loadOrCreate(in: storage)
    let second = try OTelCapabilityStore.loadOrCreate(in: storage)

    #expect(first == second)
    #expect(first.utf8.count == 64)
    #expect(first.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
    })
    let attributes = try FileManager.default.attributesOfItem(
        atPath: storage.appendingPathComponent("otel-capability").path
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test("Concurrent OTel capability creation публикует один полный token")
func concurrentOTelCapabilityCreationIsAtomic() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for attempt in 0..<32 {
        let storage = root.appendingPathComponent(
            String(attempt),
            isDirectory: true
        )
        let tokens = try await withThrowingTaskGroup(
            of: String.self,
            returning: [String].self
        ) { group in
            for _ in 0..<32 {
                group.addTask {
                    try OTelCapabilityStore.loadOrCreate(in: storage)
                }
            }

            var values: [String] = []
            for try await token in group {
                values.append(token)
            }
            return values
        }

        #expect(tokens.count == 32)
        #expect(Set(tokens).count == 1)
        #expect(tokens.allSatisfy { $0.utf8.count == 64 })
        let storageItems = try FileManager.default.contentsOfDirectory(
            atPath: storage.path
        )
        #expect(storageItems == ["otel-capability"])
    }
}

@Test("OTel capability store не следует symbolic link")
func otelCapabilityRejectsSymbolicLink() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = root.appendingPathComponent("storage", isDirectory: true)
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(
        at: storage,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(String(repeating: "a", count: 64).utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: storage.appendingPathComponent("otel-capability"),
        withDestinationURL: outside
    )

    #expect(throws: OTelCapabilityError.self) {
        try OTelCapabilityStore.loadOrCreate(in: storage)
    }
    #expect(try Data(contentsOf: outside) == Data(String(repeating: "a", count: 64).utf8))
}

@Test("State отклоняет oversized semantic arrays до загрузки")
@MainActor
func persistedStateRejectsOversizedSemanticArrays() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let oversizedCases: [(name: String, document: String)] = [
        (
            "records",
            qaStateDocument(
                records: qaRepeatedJSONArray(
                    "{}",
                    count: UsageLimits.maximumRetainedRecords + 1
                )
            )
        ),
        (
            "prices",
            qaStateDocument(
                prices: qaRepeatedJSONArray(
                    "{}",
                    count: UsageStateLimits.maximumPrices + 1
                )
            )
        ),
        (
            "knownModels",
            qaStateDocument(
                knownModels: qaRepeatedJSONArray(
                    "{}",
                    count: UsageStateLimits.maximumKnownModels + 1
                )
            )
        ),
        (
            "dailyUsageBuckets",
            qaStateDocument(
                accountUsage:
                    """
                    {
                      "summary": {},
                      "dailyUsageBuckets": \(qaRepeatedJSONArray(
                          #"{"startDate":"2026-07-26","tokens":1}"#,
                          count: UsageStateLimits.maximumDailyUsageBuckets + 1
                      )),
                      "fetchedAt": 1785052800
                    }
                    """
            )
        ),
    ]

    for oversizedCase in oversizedCases {
        let storage = root.appendingPathComponent(
            oversizedCase.name,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: true
        )
        try Data(oversizedCase.document.utf8).write(
            to: storage.appendingPathComponent("state.json")
        )

        let store = UsageStore(
            storageDirectory: storage,
            seedDemoIfNeeded: false,
            autoRefreshRealData: false
        )

        #expect(store.records.isEmpty)
        #expect(store.sourceKind == .empty)
        #expect(store.alertMessage?.contains("повреждено") == true)
        #expect(store.alertMessage?.contains("максимум") == true)
        let backups = try FileManager.default.contentsOfDirectory(
            at: storage,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("state.corrupt-") }
        #expect(backups.count == 1)
    }
}

@Test("Writer не следует storage и lock symlink и не пишет в обычный файл")
@MainActor
func persistenceRejectsUnsafeStorageAndLockTargets() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = Data("do-not-modify".utf8)

    let outsideDirectory = root.appendingPathComponent(
        "outside",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: outsideDirectory,
        withIntermediateDirectories: true
    )
    let storageLink = root.appendingPathComponent("storage-link")
    try FileManager.default.createSymbolicLink(
        at: storageLink,
        withDestinationURL: outsideDirectory
    )
    let symlinkStore = UsageStore(
        storageDirectory: storageLink,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    symlinkStore.records = [qaPersistenceRecord(model: "symlink")]
    symlinkStore.flushState()
    #expect(
        !FileManager.default.fileExists(
            atPath: outsideDirectory.appendingPathComponent("state.json").path
        )
    )
    #expect(
        !FileManager.default.fileExists(
            atPath: outsideDirectory.appendingPathComponent(".state.lock").path
        )
    )
    #expect(symlinkStore.alertMessage?.contains("каталог") == true)

    let regularStorage = root.appendingPathComponent("regular-storage")
    try sentinel.write(to: regularStorage)
    let regularFileStore = UsageStore(
        storageDirectory: regularStorage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    regularFileStore.records = [qaPersistenceRecord(model: "regular-file")]
    regularFileStore.flushState()
    #expect(try Data(contentsOf: regularStorage) == sentinel)
    #expect(regularFileStore.alertMessage?.contains("каталог") == true)

    let lockStorage = root.appendingPathComponent(
        "lock-storage",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: lockStorage,
        withIntermediateDirectories: true
    )
    let outsideLock = root.appendingPathComponent("outside-lock")
    try sentinel.write(to: outsideLock)
    try FileManager.default.createSymbolicLink(
        at: lockStorage.appendingPathComponent(".state.lock"),
        withDestinationURL: outsideLock
    )
    let unsafeLockStore = UsageStore(
        storageDirectory: lockStorage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    unsafeLockStore.records = [qaPersistenceRecord(model: "lock-link")]
    unsafeLockStore.flushState()
    #expect(try Data(contentsOf: outsideLock) == sentinel)
    #expect(
        !FileManager.default.fileExists(
            atPath: lockStorage.appendingPathComponent("state.json").path
        )
    )
    #expect(unsafeLockStore.alertMessage?.contains("writer lease") == true)
}

@Test("Второй store остаётся read-only и не теряет запись первого")
@MainActor
func concurrentStoresDoNotSilentlyOverwriteState() async throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let primary = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    primary.records = [qaPersistenceRecord(model: "primary")]
    try await Task.sleep(for: .milliseconds(300))
    primary.flushState()

    let stateURL = storage.appendingPathComponent("state.json")
    let lockURL = storage.appendingPathComponent(".state.lock")
    let initialLockAttributes =
        try FileManager.default.attributesOfItem(atPath: lockURL.path)
    #expect(
        initialLockAttributes[.type] as? FileAttributeType == .typeRegular
    )
    #expect(
        (initialLockAttributes[.posixPermissions] as? NSNumber)?.intValue
            == 0o600
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: storage.path
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: lockURL.path
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: stateURL.path
    )
    let stateBeforeSecondary = try Data(contentsOf: stateURL)
    let entriesBeforeSecondary = try FileManager.default.contentsOfDirectory(
        atPath: storage.path
    ).sorted()
    let secondary = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    #expect(secondary.records.first?.model == "primary")
    #expect(secondary.alertMessage?.contains("другой экземпляр") == true)
    #expect(secondary.alertMessage?.contains("перезапуст") == true)

    secondary.records = [qaPersistenceRecord(model: "secondary")]
    secondary.startLiveReceiver()
    secondary.flushState()

    #expect(try Data(contentsOf: stateURL) == stateBeforeSecondary)
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: storage.path).sorted()
            == entriesBeforeSecondary
    )
    let directoryAttributes =
        try FileManager.default.attributesOfItem(atPath: storage.path)
    let lockAttributes =
        try FileManager.default.attributesOfItem(atPath: lockURL.path)
    let stateAttributes =
        try FileManager.default.attributesOfItem(atPath: stateURL.path)
    #expect(
        (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
            == 0o755
    )
    #expect(
        (lockAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o644
    )
    #expect(
        (stateAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o644
    )
    #expect(secondary.alertMessage?.contains("другой экземпляр") == true)

    let corruptSentinel = Data("{broken-state".utf8)
    try corruptSentinel.write(to: stateURL)
    let readerWithCorruptState = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: true,
        autoRefreshRealData: false
    )
    readerWithCorruptState.flushState()
    #expect(try Data(contentsOf: stateURL) == corruptSentinel)
    let corruptBackups = try FileManager.default.contentsOfDirectory(
        atPath: storage.path
    ).filter { $0.hasPrefix("state.corrupt-") }
    #expect(corruptBackups.isEmpty)
    #expect(
        readerWithCorruptState.alertMessage?.contains("другой экземпляр")
            == true
    )

    try FileManager.default.removeItem(at: stateURL)
    let readerWithMissingState = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: true,
        autoRefreshRealData: false
    )
    readerWithMissingState.flushState()
    #expect(readerWithMissingState.records.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: stateURL.path))
    #expect(
        readerWithMissingState.alertMessage?.contains("другой экземпляр")
            == true
    )
}

@Test("Secondary store стабильно read-only и блокирует все мутации")
@MainActor
func secondaryStoreGuardsAllPersistentMutations() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = root.appendingPathComponent("storage", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let primary = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    primary.records = [qaPersistenceRecord(model: "primary")]
    primary.prices = [
        ModelPrice(
            modelPattern: "primary-price",
            inputPerMillion: 1,
            cachedInputPerMillion: 2,
            outputPerMillion: 3
        )
    ]
    primary.sourceKind = .codexLocal
    let initialAccountUsage = AccountUsageSnapshot(
        summary: AccountUsageSummary(
            lifetimeTokens: 42,
            peakDailyTokens: 12,
            longestRunningTurnSec: 8,
            currentStreakDays: 2,
            longestStreakDays: 4
        ),
        dailyUsageBuckets: [],
        fetchedAt: Date(timeIntervalSince1970: 1_785_052_800),
        codexExecutable: "/usr/local/bin/codex"
    )
    primary.applyAccountSyncResult(
        .success(
            CodexAccountResult(
                usage: initialAccountUsage,
                models: [
                    CodexModelInfo(
                        id: "primary-model",
                        model: "primary-model",
                        displayName: "Primary model",
                        hidden: false,
                        isDefault: true
                    )
                ]
            )
        )
    )
    primary.flushState()

    let stateURL = storage.appendingPathComponent("state.json")
    let stateBeforeMutations = try Data(contentsOf: stateURL)
    let secondary = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: true,
        autoRefreshRealData: false
    )

    #expect(primary.canPersist)
    #expect(!primary.isReadOnly)
    #expect(primary.persistenceReadOnlyMessage == nil)
    #expect(!secondary.canPersist)
    #expect(secondary.isReadOnly)
    let readOnlyMessage = try #require(
        secondary.persistenceReadOnlyMessage
    )
    #expect(readOnlyMessage.contains("Изменения"))
    #expect(readOnlyMessage.contains("другой экземпляр"))

    let initialRecords = secondary.records
    let initialPrices = secondary.prices
    let initialSourceKind = secondary.sourceKind
    let initialImportedFileName = secondary.importedFileName
    let initialLastImportNote = secondary.lastImportNote
    let initialAccount = secondary.accountUsage
    let initialModels = secondary.knownModels
    let initialAccountStatus = secondary.accountSyncStatus
    let initialLocalStatus = secondary.localScanStatus
    let initialPriceStatus = secondary.priceUpdateStatus

    secondary.alertMessage = nil
    secondary.records = [qaPersistenceRecord(model: "direct")]
    secondary.prices = []
    secondary.sourceKind = .demo
    secondary.importedFileName = "direct.csv"
    secondary.accountUsage = nil
    secondary.knownModels = []
    secondary.loadDemoData()
    secondary.clearUsageData()
    secondary.resetPrices()
    secondary.addPrice()
    if let priceID = secondary.prices.first?.id {
        secondary.removePrice(id: priceID)
    }
    secondary.mergeLiveRecords([qaPersistenceRecord(model: "live")])
    secondary.importFile(root.appendingPathComponent("import.json"))
    secondary.scanLocalHistory()
    secondary.updateOfficialPrices()
    secondary.syncAccountUsage()
    secondary.refreshRealData()
    secondary.applyAccountSyncResult(
        .success(
            CodexAccountResult(
                usage: AccountUsageSnapshot(
                    summary: AccountUsageSummary(
                        lifetimeTokens: 999,
                        peakDailyTokens: nil,
                        longestRunningTurnSec: nil,
                        currentStreakDays: nil,
                        longestStreakDays: nil
                    ),
                    dailyUsageBuckets: nil,
                    fetchedAt: Date(),
                    codexExecutable: nil
                ),
                models: []
            )
        )
    )
    secondary.installLiveOTelConfiguration()
    secondary.startLiveReceiver()
    secondary.flushState()

    #expect(secondary.isReadOnly)
    #expect(secondary.persistenceReadOnlyMessage == readOnlyMessage)
    #expect(secondary.records == initialRecords)
    #expect(secondary.prices == initialPrices)
    #expect(secondary.sourceKind == initialSourceKind)
    #expect(secondary.importedFileName == initialImportedFileName)
    #expect(secondary.lastImportNote == initialLastImportNote)
    #expect(secondary.accountUsage == initialAccount)
    #expect(secondary.knownModels == initialModels)
    #expect(secondary.accountSyncStatus == initialAccountStatus)
    #expect(secondary.localScanStatus == initialLocalStatus)
    #expect(secondary.priceUpdateStatus == initialPriceStatus)
    #expect(!secondary.isSyncingAccount)
    #expect(!secondary.isScanningLocal)
    #expect(!secondary.isUpdatingPrices)
    #expect(!secondary.isLiveReceiverRunning)
    #expect(
        secondary.liveReceiverStatus.contains("только для чтения")
    )
    #expect(
        secondary.alertMessage?.contains("другой экземпляр") == true
    )
    #expect(try Data(contentsOf: stateURL) == stateBeforeMutations)
}

@Test("Secondary auto-refresh не запускает write-path и сохраняет причину read-only")
@MainActor
func secondaryAutoRefreshIsSilent() async throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let primary = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    #expect(primary.canPersist)
    let secondary = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: true
    )
    let initialAlert = secondary.alertMessage

    await Task.yield()
    await Task.yield()

    #expect(!secondary.canPersist)
    #expect(secondary.alertMessage == initialAlert)
    #expect(secondary.alertMessage?.contains("другой экземпляр") == true)
    #expect(!secondary.isRefreshing)
    #expect(
        secondary.liveReceiverStatus == "Live OTel запускается…"
    )
}

@Test("Primary store остаётся доступен для мутаций")
@MainActor
func primaryStoreRemainsWritableAfterReadOnlyGuards() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )

    #expect(store.canPersist)
    #expect(!store.isReadOnly)
    #expect(store.persistenceReadOnlyMessage == nil)

    store.loadDemoData()
    #expect(!store.records.isEmpty)
    #expect(store.sourceKind == .demo)

    store.clearUsageData()
    #expect(store.records.isEmpty)
    #expect(store.sourceKind == .empty)

    let originalPriceCount = store.prices.count
    store.addPrice()
    #expect(store.prices.count == originalPriceCount + 1)
    let addedPriceID = try #require(store.prices.last?.id)
    store.removePrice(id: addedPriceID)
    #expect(store.prices.count == originalPriceCount)

    let accountUsage = AccountUsageSnapshot(
        summary: AccountUsageSummary(
            lifetimeTokens: 77,
            peakDailyTokens: nil,
            longestRunningTurnSec: nil,
            currentStreakDays: nil,
            longestStreakDays: nil
        ),
        dailyUsageBuckets: nil,
        fetchedAt: Date(),
        codexExecutable: nil
    )
    store.applyAccountSyncResult(
        .success(CodexAccountResult(usage: accountUsage, models: []))
    )
    #expect(store.accountUsage == accountUsage)

    store.mergeLiveRecords([qaPersistenceRecord(model: "live-primary")])
    #expect(store.records.map(\.model) == ["live-primary"])
}

@Test("Пустой каталог цен сохраняется как осознанно пустой")
@MainActor
func emptyPriceCatalogRoundTripsWithoutDefaults() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let writer = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    writer.prices = []
    writer.flushState()

    let stateData = try Data(
        contentsOf: storage.appendingPathComponent("state.json")
    )
    let stateObject = try #require(
        JSONSerialization.jsonObject(with: stateData) as? [String: Any]
    )
    #expect((stateObject["prices"] as? [Any])?.isEmpty == true)

    let reader = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    #expect(reader.prices.isEmpty)
}

@Test("Flush после coalesced async save фиксирует самое новое состояние")
@MainActor
func flushWinsAsyncPersistenceRace() async throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let writer = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    writer.records = (0..<50_000).map { index in
        UsageRecord(
            timestamp: Date(timeIntervalSince1970: 1_785_052_800 - Double(index)),
            model: "older-\(index)",
            inputTokens: index,
            outputTokens: 1,
            source: "async-stress"
        )
    }
    try await Task.sleep(for: .milliseconds(260))

    writer.records = [qaPersistenceRecord(model: "latest")]
    writer.flushState()

    let reader = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    #expect(reader.records.count == 1)
    #expect(reader.records.first?.model == "latest")
}

@Test("UI addPrice использует общий persistence cap")
@MainActor
func addPriceHonorsPersistenceLimit() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    store.prices = (0..<UsageStateLimits.maximumPrices).map { index in
        ModelPrice(
            modelPattern: "model-\(index)",
            inputPerMillion: 1,
            cachedInputPerMillion: 1,
            outputPerMillion: 1
        )
    }

    store.addPrice()

    #expect(store.prices.count == UsageStateLimits.maximumPrices)
    #expect(store.alertMessage?.contains("максимум") == true)
}

@Test("Price fetch блокирует editor, reset очищает error, stale result игнорируется")
@MainActor
func priceFetchSerializesEditorMutations() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let fetcher = QAPricingFetcher()
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false,
        officialPricingFetcher: { completion in
            fetcher.completions.append(completion)
        }
    )
    let initialPrices = store.prices

    store.updateOfficialPrices()
    #expect(store.isUpdatingPrices)
    #expect(!store.canEditPrices)
    store.addPrice()
    store.prices = []
    #expect(store.prices == initialPrices)

    let firstCompletion = try #require(fetcher.completions.first)
    firstCompletion(.failure(NSError(domain: "qa", code: 1)))
    #expect(store.priceUpdateHasError)
    #expect(!store.isUpdatingPrices)

    store.resetPrices()
    #expect(!store.priceUpdateHasError)
    #expect(store.alertMessage == nil)

    store.updateOfficialPrices()
    let secondCompletion = try #require(fetcher.completions.last)
    let current = ModelPrice(
        modelPattern: "current-result",
        inputPerMillion: 2,
        cachedInputPerMillion: 0,
        outputPerMillion: 3
    )
    secondCompletion(.success([current]))
    #expect(store.prices.contains { $0.modelPattern == "current-result" })

    let stale = ModelPrice(
        modelPattern: "stale-result",
        inputPerMillion: 9,
        cachedInputPerMillion: 0,
        outputPerMillion: 9
    )
    firstCompletion(.success([stale]))
    #expect(!store.prices.contains { $0.modelPattern == "stale-result" })
    #expect(store.prices.contains { $0.modelPattern == "current-result" })
}

@Test("Live acceptance приходит только после durable state write")
@MainActor
func liveAcceptanceWaitsForDurableWrite() async throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    let probe = QAAcceptanceProbe()
    let live = UsageRecord(
        timestamp: Date(timeIntervalSince1970: 1_785_052_800),
        model: "durable-live",
        inputTokens: 10,
        outputTokens: 2,
        source: "otel-live"
    )

    store.mergeLiveRecords([live]) { result in
        Task {
            await probe.set(result)
        }
    }
    #expect(store.records.isEmpty)
    for _ in 0..<200 {
        if await probe.value != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }

    let acceptedResult = await probe.value
    #expect(acceptedResult == .accepted)
    #expect(store.records.count == 1)
    let stateURL = storage.appendingPathComponent("state.json")
    #expect(FileManager.default.fileExists(atPath: stateURL.path))
    let reader = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    #expect(reader.records.first?.model == "durable-live")
}

@Test("Oversized live batch не меняет память и сохранённый state")
@MainActor
func oversizedLiveBatchRollsBackMemoryAndDisk() async throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let fetcher = QAPricingFetcher()
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false,
        officialPricingFetcher: { completion in
            fetcher.completions.append(completion)
        }
    )
    let baseline = qaPersistenceRecord(model: "baseline")
    store.records = [baseline]
    store.flushState()
    let stateURL = storage.appendingPathComponent("state.json")
    let longModel = String(repeating: "m", count: 512)
    let baseTimestamp = Date(timeIntervalSince1970: 1_785_052_800)
    let liveRecords = (0..<UsageLimits.maximumRetainedRecords).map { index in
        UsageRecord(
            timestamp: baseTimestamp.addingTimeInterval(-Double(index)),
            model: longModel,
            inputTokens: index,
            outputTokens: 1,
            source: "otel-live"
        )
    }

    store.updateOfficialPrices()
    let priceCompletion = try #require(fetcher.completions.first)
    let acceptance = QAAcceptanceProbe()
    store.mergeLiveRecords(liveRecords) { result in
        Task {
            await acceptance.set(result)
        }
    }
    priceCompletion(.success([
        ModelPrice(
            modelPattern: "queued-official",
            inputPerMillion: 1,
            cachedInputPerMillion: 0,
            outputPerMillion: 1
        )
    ]))
    let queuedAccount = AccountUsageSnapshot(
        summary: AccountUsageSummary(
            lifetimeTokens: 123,
            peakDailyTokens: nil,
            longestRunningTurnSec: nil,
            currentStreakDays: nil,
            longestStreakDays: nil
        ),
        dailyUsageBuckets: [],
        fetchedAt: baseTimestamp,
        codexExecutable: nil
    )
    store.applyAccountSyncResult(
        .success(
            CodexAccountResult(usage: queuedAccount, models: [])
        )
    )
    let originalPriceID = try #require(store.prices.first?.id)
    store.resetPrices()
    store.addPrice()
    store.removePrice(id: originalPriceID)

    // Exact JSON validation/encoding runs off MainActor. Until it completes,
    // the last durable and in-memory value remains visible.
    #expect(store.records == [baseline])
    #expect(store.accountUsage == nil)
    #expect(store.isUpdatingPrices)
    for _ in 0..<600 {
        if
            store.alertMessage?.contains("слишком велик") == true,
            store.prices.contains(where: {
                $0.modelPattern == "new-model"
            }),
            !store.prices.contains(where: { $0.id == originalPriceID })
        {
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }

    #expect(store.alertMessage?.contains("слишком велик") == true)
    let rejection = await acceptance.value
    #expect(rejection == .insufficientStorage)
    #expect(store.records == [baseline])
    #expect(store.accountUsage == queuedAccount)
    #expect(!store.isUpdatingPrices)
    #expect(store.prices.contains { $0.modelPattern == "new-model" })
    #expect(!store.prices.contains { $0.id == originalPriceID })
    store.flushState()
    let reader = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    #expect(reader.records == store.records)
    #expect(reader.prices == store.prices)
    #expect(reader.accountUsage == queuedAccount)
    #expect(try Data(contentsOf: stateURL).count < 64 * 1024 * 1024)
}

@Test("Flush barriers candidate write и отменяет deferred termination mutations")
@MainActor
func flushDuringCandidateValidationIsDurableAndBounded() async throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    let timestamp = Date(timeIntervalSince1970: 1_785_052_800)
    let conservativelyExpensiveModel = String(repeating: "/", count: 100)
    store.records = (0..<UsageLimits.maximumRetainedRecords).map { index in
        UsageRecord(
            timestamp: timestamp.addingTimeInterval(-Double(index)),
            model: conservativelyExpensiveModel,
            inputTokens: index,
            outputTokens: 1,
            source: "termination"
        )
    }
    let originalPriceID = try #require(store.prices.first?.id)
    let originalPriceCount = store.prices.count

    store.addPrice()
    #expect(!store.canMutatePersistedState)
    store.removePrice(id: originalPriceID)
    store.flushState()

    // The durable candidate is complete, but its MainActor commit is queued
    // behind this test. The later removal was explicitly discarded by flush.
    #expect(store.prices.count == originalPriceCount)
    for _ in 0..<200 {
        if store.prices.count == originalPriceCount + 1 { break }
        await Task.yield()
    }
    #expect(store.prices.count == originalPriceCount + 1)
    #expect(store.prices.contains { $0.id == originalPriceID })
    let reader = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    #expect(reader.records.count == UsageLimits.maximumRetainedRecords)
    #expect(reader.prices == store.prices)
}

private func qaPersistenceRecord(model: String) -> UsageRecord {
    UsageRecord(
        timestamp: Date(timeIntervalSince1970: 1_785_052_800),
        model: model,
        inputTokens: 10,
        outputTokens: 2,
        source: "persistence-qa"
    )
}

@MainActor
private final class QAPricingFetcher {
    var completions: [
        @MainActor @Sendable (Result<[ModelPrice], Error>) -> Void
    ] = []
}

private actor QAAcceptanceProbe {
    private(set) var value: OTelRecordAcceptance?

    func set(_ value: OTelRecordAcceptance) {
        self.value = value
    }
}

private func qaRepeatedJSONArray(
    _ element: String,
    count: Int
) -> String {
    guard count > 0 else { return "[]" }
    return "[" + String(repeating: element + ",", count: count - 1)
        + element + "]"
}

private func qaStateDocument(
    records: String = "[]",
    prices: String = "[]",
    knownModels: String = "[]",
    accountUsage: String = "null",
    schemaVersion: String = "4",
    importedFileName: String = "null",
    lastLocalScanAt: String = "null"
) -> String {
    """
    {
      "schemaVersion": \(schemaVersion),
      "records": \(records),
      "prices": \(prices),
      "sourceKind": "empty",
      "importedFileName": \(importedFileName),
      "accountUsage": \(accountUsage),
      "knownModels": \(knownModels),
      "lastLocalScanAt": \(lastLocalScanAt)
    }
    """
}
