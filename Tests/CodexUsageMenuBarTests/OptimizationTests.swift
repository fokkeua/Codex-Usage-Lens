import Foundation
import Testing
@testable import CodexUsageMenuBar

@Test("Dashboard snapshot агрегирует период один раз и инвалидируется ценами")
@MainActor
func dashboardSnapshotAggregatesAndInvalidates() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(DateParsing.parse("2026-07-26T12:00:00Z"))
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }

    let store = UsageStore(
        storageDirectory: storage,
        calendar: calendar,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    store.prices = [
        ModelPrice(
            modelPattern: "model-*",
            inputPerMillion: 1,
            cachedInputPerMillion: 0.1,
            outputPerMillion: 2
        )
    ]
    store.records = [
        UsageRecord(
            timestamp: try #require(DateParsing.parse("2026-07-26T10:00:00Z")),
            model: "model-a",
            inputTokens: 1_000,
            cachedInputTokens: 200,
            outputTokens: 100,
            source: "test"
        ),
        UsageRecord(
            timestamp: try #require(DateParsing.parse("2026-07-25T10:00:00Z")),
            model: "model-a",
            inputTokens: 2_000,
            outputTokens: 200,
            source: "test"
        ),
        UsageRecord(
            timestamp: try #require(DateParsing.parse("2026-07-25T11:00:00Z")),
            model: "model-b",
            inputTokens: 3_000,
            outputTokens: 300,
            source: "test"
        ),
        UsageRecord(
            timestamp: try #require(DateParsing.parse("2026-07-20T10:00:00Z")),
            model: "model-a",
            inputTokens: 99_000,
            outputTokens: 99_000,
            source: "outside"
        ),
    ]

    let snapshot = store.dashboardSnapshot(days: 2, now: now)
    #expect(snapshot.summary.recordCount == 3)
    #expect(snapshot.summary.totalTokens == 6_600)
    #expect(snapshot.dailyRows.count == 3)
    #expect(Set(snapshot.modelRows.map(\.model)) == Set(["model-a", "model-b"]))
    #expect(snapshot.chartSegments.count == 3)
    #expect(snapshot.dailyTotals.count == 2)
    #expect(snapshot.dailyTotals.first?.summary.totalTokens == 1_100)
    #expect(snapshot.dailyTotals.last?.summary.totalTokens == 5_500)

    let oldCost = snapshot.summary.apiEquivalentCost
    store.prices[0].inputPerMillion = 4
    let repriced = store.dashboardSnapshot(days: 2, now: now)
    #expect(repriced.summary.apiEquivalentCost > oldCost)
}

@Test("State сохраняется компактно и синхронно flush-ится перед завершением")
@MainActor
func persistenceIsCompactAndFlushable() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let timestamp = try #require(DateParsing.parse("2026-07-26T08:00:00.123456Z"))
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    store.records = [
        UsageRecord(
            timestamp: timestamp,
            model: "model-a",
            inputTokens: 100,
            outputTokens: 20,
            source: "test",
            threadId: "legacy-thread-secret",
            sourceEventId: "legacy-event-secret"
        )
    ]
    store.flushState()

    let stateURL = storage.appendingPathComponent("state.json")
    let data = try Data(contentsOf: stateURL)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("\n"))
    #expect(!text.contains("legacy-thread-secret"))
    #expect(!text.contains("legacy-event-secret"))
    #expect(!text.contains("threadId"))
    #expect(!text.contains("sourceEventId"))

    let restored = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    let record = try #require(restored.records.first)
    #expect(abs(record.timestamp.timeIntervalSince(timestamp)) < 0.000_001)
    #expect(record.totalTokens == 120)
}

@Test("UsageRecord Codable нормализует hostile legacy state")
func usageRecordCodableNormalizesAndDropsRawIdentifiers() throws {
    let oversizedModel = String(
        repeating: "m",
        count: UsageLimits.maximumModelBytes + 100
    )
    let legacyObject: [String: Any] = [
        "id": UUID().uuidString,
        "timestamp": 0,
        "model": oversizedModel,
        "inputTokens": "1e300",
        "cachedInputTokens": Int.max,
        "cacheWriteTokens": Int.max,
        "outputTokens": Int.max,
        "source": String(
            repeating: "s",
            count: UsageLimits.maximumSourceBytes + 100
        ),
        "reasoningOutputTokens": Int.max,
        "serviceTier": String(
            repeating: "p",
            count: UsageLimits.maximumServiceTierBytes + 100
        ),
        "threadId": "legacy-thread-secret",
        "sourceEventId": "legacy-event-secret",
    ]
    let data = try JSONSerialization.data(withJSONObject: legacyObject)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let record = try decoder.decode(UsageRecord.self, from: data)

    #expect(record.inputTokens == UsageLimits.maximumTokenCount)
    #expect(record.outputTokens == UsageLimits.maximumTokenCount)
    #expect(record.cachedInputTokens == UsageLimits.maximumTokenCount)
    #expect(record.cacheWriteTokens == 0)
    #expect(record.reasoningOutputTokens == UsageLimits.maximumTokenCount)
    #expect(record.model.utf8.count <= UsageLimits.maximumModelBytes)
    #expect(record.source.utf8.count <= UsageLimits.maximumSourceBytes)
    #expect(
        (record.serviceTier?.utf8.count ?? 0)
            <= UsageLimits.maximumServiceTierBytes
    )
    #expect(record.timestamp.timeIntervalSince1970 == 946_684_800)
    #expect(record.threadId == nil)
    #expect(record.sourceEventId == nil)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let encoded = try encoder.encode(record)
    let encodedObject = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(encodedObject["threadId"] == nil)
    #expect(encodedObject["sourceEventId"] == nil)
}

@Test("ModelPrice Codable и setters держат finite bounded prices")
func modelPriceCodableNormalizesHostileValues() throws {
    let hostileObject: [String: Any] = [
        "id": UUID().uuidString,
        "modelPattern": String(
            repeating: "m",
            count: UsageLimits.maximumModelBytes + 100
        ),
        "inputPerMillion": "nan",
        "cachedInputPerMillion": -10,
        "cacheWritePerMillion": 1e300,
        "outputPerMillion": "1e300",
        "sourceURL": String(
            repeating: "u",
            count: UsageLimits.maximumPriceSourceURLBytes + 100
        ),
        "priorityMultiplier": "inf",
    ]
    let data = try JSONSerialization.data(withJSONObject: hostileObject)
    var price = try JSONDecoder().decode(ModelPrice.self, from: data)

    #expect(price.inputPerMillion == 0)
    #expect(price.cachedInputPerMillion == 0)
    #expect(
        price.cacheWritePerMillion == UsageLimits.maximumPricePerMillion
    )
    #expect(price.outputPerMillion == UsageLimits.maximumPricePerMillion)
    #expect(price.priorityMultiplier == nil)
    #expect(
        price.modelPattern.utf8.count <= UsageLimits.maximumModelBytes
    )
    #expect(
        (price.sourceURL?.utf8.count ?? 0)
            <= UsageLimits.maximumPriceSourceURLBytes
    )

    price.inputPerMillion = .infinity
    price.outputPerMillion = -1
    price.priorityMultiplier = 1_000
    #expect(price.inputPerMillion == 0)
    #expect(price.outputPerMillion == 0)
    #expect(
        price.priorityMultiplier == UsageLimits.maximumPriorityMultiplier
    )

    let roundTrip = try JSONDecoder().decode(
        ModelPrice.self,
        from: JSONEncoder().encode(price)
    )
    #expect(roundTrip.inputPerMillion.isFinite)
    #expect(roundTrip.outputPerMillion.isFinite)
    #expect(
        roundTrip.priorityMultiplier == UsageLimits.maximumPriorityMultiplier
    )
}

@Test("Checked/saturating arithmetic не допускает Swift overflow traps")
func usageArithmeticSaturatesAtIntegerBoundaries() {
    let boundedAggregate = UsageLimits.maximumTokenCount
        .multipliedReportingOverflow(
            by: UsageLimits.maximumRetainedRecords
        )
    #expect(!boundedAggregate.overflow)
    #expect(boundedAggregate.partialValue <= Int.max / 2)

    #expect(UsageLimits.saturatingAdd(Int.max, 1) == Int.max)
    #expect(UsageLimits.saturatingAdd(Int.min, -1) == Int.min)
    #expect(UsageLimits.saturatingSubtract(Int.min, 1) == Int.min)
    #expect(UsageLimits.saturatingSubtract(Int.max, -1) == Int.max)

    var summary = UsageSummary()
    summary.inputTokens = Int.max
    summary.outputTokens = 1
    #expect(summary.totalTokens == Int.max)

    let record = UsageRecord(
        timestamp: Date(),
        model: "model-a",
        inputTokens: UsageLimits.maximumTokenCount,
        outputTokens: UsageLimits.maximumTokenCount,
        source: "test"
    )
    summary.add(record, cost: .infinity)
    #expect(summary.inputTokens == Int.max)
    #expect(summary.outputTokens == 1 + UsageLimits.maximumTokenCount)
    #expect(summary.apiEquivalentCost == 0)
    #expect(summary.unpricedRecords == 1)
}

@Test("HTTP parser отклоняет опасный Content-Length без crash")
func httpParserValidatesContentLength() throws {
    let valid = Data(
        "POST /v1/logs HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8
    )
    switch HTTPRequest.parse(valid) {
    case .complete(let request):
        #expect(request.body == Data("{}".utf8))
    default:
        Issue.record("valid HTTP request was not parsed")
    }

    for (malformed, expectedError) in [
        (
            "POST /v1/logs HTTP/1.1\r\nContent-Length:\r\n\r\n",
            HTTPRequestParseError.invalidContentLength
        ),
        (
            "POST /v1/logs HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
            HTTPRequestParseError.invalidContentLength
        ),
        (
            "POST /v1/logs HTTP/1.1\r\nContent-Length: 999999999999999999999\r\n\r\n",
            HTTPRequestParseError.invalidContentLength
        ),
        (
            "POST /v1/logs HTTP/1.1\r\nContent-Length: \(OTelLiveReceiver.maximumBodySize + 1)\r\n\r\n",
            HTTPRequestParseError.bodyTooLarge
        ),
    ] {
        switch HTTPRequest.parse(Data(malformed.utf8)) {
        case .malformed(let error):
            #expect(error == expectedError)
        default:
            Issue.record("malformed HTTP request was not rejected")
        }
    }
}

@Test("JSONL importer безопасно пропускает non-finite token values")
func importerRejectsNonFiniteTokenValues() throws {
    let jsonl = """
    {"timestamp":"2026-07-26T08:00:00Z","model":"model-a","input_tokens":"nan","output_tokens":10}
    """
    let result = try UsageImporter.parseJSONLines(Data(jsonl.utf8))
    #expect(result.records.isEmpty)
    #expect(result.skippedRows == 1)
}

@Test("Importer отклоняет огромные отрицательные token values")
func importerRejectsHugeNegativeTokenValues() throws {
    let jsonl = """
    {"timestamp":"2026-07-26T08:00:00Z","model":"model-a","input_tokens":"-1e300","output_tokens":10}
    """
    let result = try UsageImporter.parseJSONLines(Data(jsonl.utf8))
    #expect(result.records.isEmpty)
    #expect(result.skippedRows == 1)
}

@Test("Importer отклоняет non-finite timestamps")
func importerRejectsNonFiniteTimestamps() {
    let base: [String: Any] = [
        "model": "model-a",
        "input_tokens": 100,
        "output_tokens": 10,
    ]
    #expect(
        UsageImporter.record(
            from: base.merging(["timestamp": Double.infinity]) { _, new in new }
        ) == nil
    )
    #expect(
        UsageImporter.record(
            from: base.merging(["timeUnixNano": "inf"]) { _, new in new }
        ) == nil
    )
}

@Test("Файловый JSONL importer потоково читает строки больше chunk")
func jsonLinesFileImportStreamsLargeLines() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("usage.jsonl")
    let padding = String(repeating: "x", count: 160 * 1024)
    let first = """
    {"timestamp":"2026-07-26T08:00:00Z","model":"model-a","input_tokens":100,"output_tokens":10,"padding":"\(padding)"}
    """
    let finalWithoutNewline = """
    {"timestamp":"2026-07-26T09:00:00Z","model":"model-b","input_tokens":200,"output_tokens":20}
    """
    try Data("\(first)\n\(finalWithoutNewline)".utf8).write(to: file)

    let result = try UsageImporter.importFile(file)
    #expect(result.records.count == 2)
    #expect(result.skippedRows == 0)
    #expect(result.records.map(\.model) == ["model-b", "model-a"])
    #expect(result.records.map(\.totalTokens) == [220, 110])
}

@Test("Dashboard cache включает запись, когда наступает её timestamp")
@MainActor
func dashboardCacheAdvancesPastFutureRecord() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let before = try #require(DateParsing.parse("2026-07-26T08:00:00Z"))
    let boundary = try #require(DateParsing.parse("2026-07-26T08:59:59Z"))
    let after = try #require(DateParsing.parse("2026-07-26T10:00:00Z"))
    let future = try #require(DateParsing.parse("2026-07-26T09:00:00Z"))
    let store = UsageStore(
        storageDirectory: storage,
        calendar: calendar,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    store.records = [
        UsageRecord(
            timestamp: future,
            model: "model-a",
            inputTokens: 100,
            outputTokens: 10,
            source: "test"
        )
    ]

    #expect(store.dashboardSnapshot(days: 1, now: before).summary.recordCount == 0)
    #expect(
        store.dashboardSnapshot(days: 1, now: boundary).summary.recordCount == 1
    )
    let advanced = store.dashboardSnapshot(days: 1, now: after)
    #expect(advanced.summary.recordCount == 1)
    #expect(advanced.interval.end == store.recentInterval(days: 1, now: after).end)
}

@Test("Dashboard benchmark использует реальный state только по opt-in")
@MainActor
func dashboardSnapshotBenchmark() {
    guard
        let storagePath = ProcessInfo.processInfo.environment[
            "CODEX_USAGE_BENCHMARK_STORAGE"
        ]
    else {
        return
    }

    let loadStart = DispatchTime.now().uptimeNanoseconds
    let store = UsageStore(
        storageDirectory: URL(fileURLWithPath: storagePath, isDirectory: true),
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    let loadNanoseconds = DispatchTime.now().uptimeNanoseconds - loadStart
    let firstStart = DispatchTime.now().uptimeNanoseconds
    let first = store.dashboardSnapshot(days: 90)
    let firstNanoseconds = DispatchTime.now().uptimeNanoseconds - firstStart

    var checksum = 0
    let cachedStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<1_000 {
        checksum += store.dashboardSnapshot(days: 90).summary.recordCount
    }
    let cachedNanoseconds = DispatchTime.now().uptimeNanoseconds - cachedStart

    print(
        "dashboard-benchmark records=\(first.summary.recordCount) "
            + "load_ms=\(Double(loadNanoseconds) / 1_000_000) "
            + "first_ms=\(Double(firstNanoseconds) / 1_000_000) "
            + "cached_1000_ms=\(Double(cachedNanoseconds) / 1_000_000)"
    )
    #expect(checksum == first.summary.recordCount * 1_000)
}

@Test("Cross-source dedupe остаётся bounded на 100k local records")
@MainActor
func crossSourceDedupeMaximumCardinalityPerformance() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let base = try #require(DateParsing.parse("2026-07-26T08:00:00Z"))
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )

    var localRecords: [UsageRecord] = []
    localRecords.reserveCapacity(UsageLimits.maximumRetainedRecords)
    for index in 0..<UsageLimits.maximumRetainedRecords {
        localRecords.append(
            UsageRecord(
                timestamp: base.addingTimeInterval(
                    Double(index) / 20_000
                ),
                model: "gpt-performance",
                inputTokens: 1_000,
                outputTokens: 100,
                source: "codex-local-rollout"
            )
        )
    }
    store.records = localRecords

    let liveRecords = (0..<2_048).map { index in
        UsageRecord(
            timestamp: base.addingTimeInterval(
                6 + Double(index) / 10_000
            ),
            model: "gpt-performance",
            inputTokens: 1_000,
            outputTokens: 100,
            source: "otel-live"
        )
    }
    let startedAt = DispatchTime.now().uptimeNanoseconds
    store.mergeLiveRecords(liveRecords)
    let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt

    print(
        "cross-source-dedupe-100k ms="
            + "\(Double(elapsed) / 1_000_000)"
    )
    #expect(elapsed < 5_000_000_000)
    #expect(store.records.count == UsageLimits.maximumRetainedRecords)
    #expect(store.records.allSatisfy {
        $0.source == "codex-local-rollout"
    })
}

@Test("Compiled pricing разрешает 100k моделей по каталогу из 4096 строк")
func compiledPricingCatalogPerformance() {
    let prices = (0..<UsageStateLimits.maximumPrices).map { index in
        ModelPrice(
            modelPattern: "model-\(index)-*",
            inputPerMillion: Double(index + 1),
            cachedInputPerMillion: 0,
            outputPerMillion: 1
        )
    }
    let catalog = Pricing.compiledCatalog(from: prices)
    let startedAt = DispatchTime.now().uptimeNanoseconds
    var checksum = 0
    for index in 0..<UsageLimits.maximumRetainedRecords {
        let price = catalog.price(
            for: "model-\(index % prices.count)-variant-\(index)"
        )
        checksum += Int(price?.inputPerMillion ?? 0)
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt

    print(
        "compiled-pricing-4096x100k ms="
            + "\(Double(elapsed) / 1_000_000)"
    )
    #expect(checksum > 0)
    #expect(elapsed < 5_000_000_000)
}

@Test("Price editor не сканирует 100k records на каждое нажатие")
@MainActor
func priceEditorMutationPerformanceWithMaximumRecords() throws {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    let timestamp = Date(timeIntervalSince1970: 1_785_052_800)
    store.records = (0..<UsageLimits.maximumRetainedRecords).map { index in
        UsageRecord(
            timestamp: timestamp.addingTimeInterval(-Double(index)),
            model: "compact",
            inputTokens: index,
            outputTokens: 1,
            source: "benchmark"
        )
    }
    let id = try #require(store.prices.first?.id)

    let startedAt = DispatchTime.now().uptimeNanoseconds
    for index in 0..<1_000 {
        store.updatePricePattern(id: id, value: "gpt-\(index)")
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt

    print(
        "price-editor-1000-with-100k-records ms="
            + "\(Double(elapsed) / 1_000_000)"
    )
    #expect(store.prices.first?.modelPattern == "gpt-999")
    #expect(elapsed < 2_000_000_000)
}

@Test("Many one-record live callbacks остаются практичными")
@MainActor
func manySingleRecordLiveCallbacksPerformance() {
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let store = UsageStore(
        storageDirectory: storage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    let timestamp = Date(timeIntervalSince1970: 1_785_052_800)
    let startedAt = DispatchTime.now().uptimeNanoseconds
    for index in 0..<500 {
        store.mergeLiveRecords([
            UsageRecord(
                timestamp: timestamp.addingTimeInterval(Double(index)),
                model: "callback-\(index)",
                inputTokens: index,
                outputTokens: 1,
                source: "otel-live"
            )
        ])
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt

    print(
        "single-live-callbacks-500 ms="
            + "\(Double(elapsed) / 1_000_000)"
    )
    #expect(store.records.count == 500)
    #expect(elapsed < 5_000_000_000)
}
