import Darwin
import Foundation
import Testing
@testable import CodexUsageMenuBar

@Test("Сверка пропускает незавершённый сегодняшний bucket")
@MainActor
func reconciliationUsesLatestCompletedDay() throws {
    let calendar = Calendar(identifier: .gregorian)
    let today = calendar.startOfDay(for: Date())
    let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let store = UsageStore(
        storageDirectory: storage,
        calendar: calendar,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    store.accountUsage = AccountUsageSnapshot(
        summary: AccountUsageSummary(
            lifetimeTokens: 300,
            peakDailyTokens: nil,
            longestRunningTurnSec: nil,
            currentStreakDays: nil,
            longestStreakDays: nil
        ),
        dailyUsageBuckets: [
            AccountUsageDailyBucket(startDate: DateParsing.format(yesterday), tokens: 100),
            AccountUsageDailyBucket(startDate: DateParsing.format(today), tokens: 1),
        ],
        fetchedAt: Date(),
        codexExecutable: nil
    )
    store.records = [
        UsageRecord(
            timestamp: yesterday.addingTimeInterval(3_600),
            model: "gpt-5.6-sol",
            inputTokens: 80,
            outputTokens: 20,
            source: "test"
        ),
        UsageRecord(
            timestamp: today.addingTimeInterval(3_600),
            model: "gpt-5.6-sol",
            inputTokens: 240,
            outputTokens: 60,
            source: "test"
        ),
    ]

    let latest = try #require(store.latestReconciliation)
    #expect(calendar.isDate(latest.date, inSameDayAs: yesterday))
    #expect(latest.value.officialTokens == 100)
    #expect(latest.value.detailedTokens == 100)
}

@Test("Кэш сверки обновляется после смены календарного дня")
@MainActor
func reconciliationCacheAdvancesAtMidnight() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let firstDay = try #require(DateParsing.parse("2026-07-25T12:00:00Z"))
    let secondDay = try #require(DateParsing.parse("2026-07-26T12:00:00Z"))
    let firstStart = calendar.startOfDay(for: firstDay)
    let previousStart = try #require(
        calendar.date(byAdding: .day, value: -1, to: firstStart)
    )
    let secondStart = calendar.startOfDay(for: secondDay)
    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let store = UsageStore(
        storageDirectory: storage,
        calendar: calendar,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    store.accountUsage = AccountUsageSnapshot(
        summary: AccountUsageSummary(
            lifetimeTokens: 300,
            peakDailyTokens: nil,
            longestRunningTurnSec: nil,
            currentStreakDays: nil,
            longestStreakDays: nil
        ),
        dailyUsageBuckets: [
            AccountUsageDailyBucket(
                startDate: DateParsing.format(previousStart),
                tokens: 100
            ),
            AccountUsageDailyBucket(
                startDate: DateParsing.format(firstStart),
                tokens: 200
            ),
        ],
        fetchedAt: secondDay,
        codexExecutable: nil
    )
    store.records = [
        UsageRecord(
            timestamp: previousStart.addingTimeInterval(3_600),
            model: "model-a",
            inputTokens: 100,
            outputTokens: 0,
            source: "test"
        ),
        UsageRecord(
            timestamp: firstStart.addingTimeInterval(3_600),
            model: "model-a",
            inputTokens: 200,
            outputTokens: 0,
            source: "test"
        ),
    ]

    let beforeMidnight = try #require(
        store.latestReconciliation(asOf: firstDay)
    )
    #expect(calendar.isDate(beforeMidnight.date, inSameDayAs: previousStart))
    let afterMidnight = try #require(
        store.latestReconciliation(asOf: secondDay)
    )
    #expect(calendar.isDate(afterMidnight.date, inSameDayAs: firstStart))
    #expect(afterMidnight.value.officialTokens == 200)
    #expect(afterMidnight.value.detailedTokens == 200)
    #expect(secondStart > firstStart)
}

@Test("Декодируется официальный account/usage/read")
func decodesAccountUsage() throws {
    let object: [String: Any] = [
        "summary": [
            "lifetimeTokens": 3_422_334_126,
            "peakDailyTokens": 413_565_729,
            "currentStreakDays": 18,
        ],
        "dailyUsageBuckets": [
            ["startDate": "2026-07-26", "tokens": 91_739_553],
        ],
    ]

    let value = try CodexAppServerClient.decodeAccountUsage(from: object)
    #expect(value.summary.lifetimeTokens == 3_422_334_126)
    #expect(value.dailyUsageBuckets?.first?.tokens == 91_739_553)
}

@Test("App-server запускается без opt-in в experimental API")
func initializesAppServerWithStableSurfaceOnly() throws {
    let request = CodexAppServerClient.initializeRequest()
    let params = try #require(request["params"] as? [String: Any])
    let clientInfo = try #require(params["clientInfo"] as? [String: Any])

    #expect(request["method"] as? String == "initialize")
    #expect(clientInfo["name"] as? String == "codex_usage_lens")
    #expect(params["capabilities"] == nil)
}

@Test("Локальный backfill читает только token_count и удаляет точный дубль")
func scansLocalTokenEvents() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("rollout.jsonl")
    let tokenLine = """
    {"timestamp":"2026-07-26T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":400,"cache_write_input_tokens":100,"output_tokens":300,"reasoning_output_tokens":40}}}}
    """
    let jsonl = """
    {"timestamp":"2026-07-26T07:59:00Z","type":"session_meta","payload":{"id":"thread-1"}}
    {"timestamp":"2026-07-26T07:59:30Z","type":"turn_context","payload":{"model":"gpt-5.6-terra","service_tier":"default"}}
    \(tokenLine)
    \(tokenLine)
    {"timestamp":"2026-07-26T08:01:00Z","type":"event_msg","payload":{"type":"user_message","message":"must not be parsed"}}
    """
    try Data(jsonl.utf8).write(to: file)

    let result = try CodexLocalSessionSource.scan(files: [file])
    let record = try #require(result.records.first)
    #expect(result.tokenEvents == 2)
    #expect(result.duplicatesRemoved == 1)
    #expect(record.model == "gpt-5.6-terra")
    #expect(record.cachedInputTokens == 400)
    #expect(record.reasoningOutputTokens == 40)
    #expect(record.threadId == nil)
}

@Test("Turn context сбрасывает отсутствующие model и service tier")
func localScanResetsIncompleteTurnContext() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("contexts.jsonl")
    let jsonl = """
    {"timestamp":"2026-07-26T08:00:00Z","type":"turn_context","payload":{"model":"model-a","service_tier":"priority"}}
    {"timestamp":"2026-07-26T08:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":1}}}}
    {"timestamp":"2026-07-26T08:01:00Z","type":"turn_context","payload":{"model":"model-b"}}
    {"timestamp":"2026-07-26T08:01:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":2,"output_tokens":1}}}}
    {"timestamp":"2026-07-26T08:02:00Z","type":"turn_context","payload":{}}
    {"timestamp":"2026-07-26T08:02:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":3,"output_tokens":1}}}}
    """
    try Data(jsonl.utf8).write(to: file)

    let records = try CodexLocalSessionSource.scan(files: [file]).records
        .sorted { $0.timestamp < $1.timestamp }
    #expect(records.count == 3)
    #expect(records[0].model == "model-a")
    #expect(records[0].serviceTier == "priority")
    #expect(records[1].model == "model-b")
    #expect(records[1].serviceTier == "default")
    #expect(records[2].model == "unknown")
    #expect(records[2].serviceTier == "default")
}

@Test("Incremental session scan использует bounded mtime overlap")
func localScanUsesModificationDateOverlap() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let checkpoint = Date()

    for (index, age) in [0.0, 1.0].enumerated() {
        let file = directory.appendingPathComponent("overlap-\(index).jsonl")
        let jsonl = """
        {"timestamp":"2026-07-26T08:0\(index):00Z","type":"turn_context","payload":{"model":"model-\(index)"}}
        {"timestamp":"2026-07-26T08:0\(index):01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(index + 1),"output_tokens":1}}}}
        """
        try Data(jsonl.utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: checkpoint.addingTimeInterval(-age)],
            ofItemAtPath: file.path
        )
    }

    let result = try CodexLocalSessionSource.scan(
        root: directory,
        modifiedAfter: checkpoint
    )
    #expect(result.records.count == 2)
    #expect(Set(result.records.map(\.model)) == ["model-0", "model-1"])
}

@Test("Session prefilter распознаёт whitespace вокруг type members")
func localSessionPrefilterAcceptsWhitespace() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("whitespace-rollout.jsonl")

    let context: [String: Any] = [
        "timestamp": "2026-07-26T07:59:00Z",
        "type": "turn_context",
        "payload": [
            "model": "model-before-settings",
            "service_tier": "default",
        ],
    ]
    let settings: [String: Any] = [
        "timestamp": "2026-07-26T07:59:30Z",
        "type": "event_msg",
        "payload": [
            "type": "thread_settings_applied",
            "thread_settings": [
                "model": "model-after-settings",
                "service_tier": "priority",
            ],
        ],
    ]
    let tokenCount: [String: Any] = [
        "timestamp": "2026-07-26T08:00:00Z",
        "type": "event_msg",
        "payload": [
            "type": "token_count",
            "info": [
                "last_token_usage": [
                    "input_tokens": 10,
                    "output_tokens": 2,
                ],
            ],
        ],
    ]
    let jsonl = try [context, settings, tokenCount]
        .map(singleLinePrettyPrintedJSON)
        .joined(separator: "\n")
    #expect(jsonl.contains(#""type" : "turn_context""#))
    #expect(jsonl.contains(#""type" : "thread_settings_applied""#))
    #expect(jsonl.contains(#""type" : "token_count""#))
    try Data(jsonl.utf8).write(to: file)

    let result = try CodexLocalSessionSource.scan(files: [file])
    let record = try #require(result.records.first)
    #expect(result.tokenEvents == 1)
    #expect(result.malformedLines == 0)
    #expect(record.model == "model-after-settings")
    #expect(record.serviceTier == "priority")
    #expect(record.totalTokens == 12)
}

@Test("Session prefilter игнорирует type-like текст внутри payload string")
func localSessionPrefilterSkipsQuotedLookalike() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("quoted-lookalike.jsonl")

    let object: [String: Any] = [
        "type": "metadata",
        "payload": #"quoted "type" : "token_count" text"#,
    ]
    let encoded = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    )
    var malformedLine = try #require(
        String(data: encoded, encoding: .utf8)
    )
    malformedLine.removeLast()
    #expect(malformedLine.contains(#"\"type\" : \"token_count\""#))
    try Data(malformedLine.utf8).write(to: file)

    let result = try CodexLocalSessionSource.scan(files: [file])
    #expect(result.records.isEmpty)
    #expect(result.malformedLines == 0)
}

@Test("Локальный backfill отклоняет огромные отрицательные tokens")
func localScanRejectsHugeNegativeTokens() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("rollout.jsonl")
    let jsonl = """
    {"timestamp":"2026-07-26T07:59:30Z","type":"turn_context","payload":{"model":"model-a"}}
    {"timestamp":"2026-07-26T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":"-1e300","output_tokens":10}}}}
    """
    try Data(jsonl.utf8).write(to: file)

    let result = try CodexLocalSessionSource.scan(files: [file])
    #expect(result.records.isEmpty)
    #expect(result.tokenEvents == 1)
    #expect(result.malformedLines == 1)
}

@Test("Локальный backfill читает строку длиннее chunk и финальную строку без newline")
func scansAcrossChunkBoundaryAndUnterminatedFinalLine() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("rollout.jsonl")
    let padding = String(repeating: "x", count: 128 * 1024)
    let sessionLine = """
    {"timestamp":"2026-07-26T07:59:00Z","payload":{"id":"thread-across-chunks","padding":"\(padding)"},"type":"session_meta"}
    """
    let contextLine = """
    {"timestamp":"2026-07-26T07:59:30Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","service_tier":"priority"}}
    """
    let tokenLine = """
    {"timestamp":"2026-07-26T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":800,"cached_input_tokens":200,"output_tokens":100}}}}
    """
    let jsonl = sessionLine + "\n" + contextLine + "\n" + tokenLine
    #expect(Data(sessionLine.utf8).count > 128 * 1024)
    #expect(!jsonl.hasSuffix("\n"))
    try Data(jsonl.utf8).write(to: file)

    let result = try CodexLocalSessionSource.scan(files: [file])
    let record = try #require(result.records.first)
    #expect(result.tokenEvents == 1)
    #expect(result.malformedLines == 0)
    #expect(record.model == "gpt-5.6-sol")
    #expect(record.serviceTier == "priority")
    #expect(record.threadId == nil)
    #expect(record.totalTokens == 900)
}

@Test("Session scan игнорирует symlink и FIFO без блокировки")
func localScanRejectsSymlinkAndSpecialFiles() throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = parent.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: parent) }

    let outside = parent.appendingPathComponent("outside.jsonl")
    let tokenLine = """
    {"timestamp":"2026-07-26T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":1}}}}
    """
    try Data(tokenLine.utf8).write(to: outside)

    let link = root.appendingPathComponent("linked.jsonl")
    try FileManager.default.createSymbolicLink(
        at: link,
        withDestinationURL: outside
    )
    let rootResult = try CodexLocalSessionSource.scan(root: root)
    #expect(rootResult.filesScanned == 0)
    #expect(rootResult.records.isEmpty)

    let linkedRoot = parent.appendingPathComponent("linked-root")
    try FileManager.default.createSymbolicLink(
        at: linkedRoot,
        withDestinationURL: root
    )
    for unsafeRoot in [linkedRoot, outside] {
        do {
            _ = try CodexLocalSessionSource.scan(root: unsafeRoot)
            Issue.record("unsafe session root unexpectedly succeeded")
        } catch let error as LocalSessionError {
            guard case .unsafeRoot = error else {
                Issue.record("unexpected unsafe-root error: \(error)")
                return
            }
        }
    }

    let fifo = root.appendingPathComponent("pipe.jsonl")
    let status = fifo.path.withCString {
        Darwin.mkfifo($0, mode_t(0o600))
    }
    #expect(status == 0)
    let directResult = try CodexLocalSessionSource.scan(files: [link, fifo])
    #expect(directResult.filesScanned == 0)
    #expect(directResult.records.isEmpty)
}

@Test("Session scan сообщает file и aggregate limits")
func localScanEnforcesResourceLimits() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let regular = directory.appendingPathComponent("regular.jsonl")
    try Data("{}".utf8).write(to: regular)
    do {
        _ = try CodexLocalSessionSource.scan(
            files: Array(
                repeating: regular,
                count: UsageLimits.maximumSessionFiles + 1
            )
        )
        Issue.record("session file-count limit unexpectedly succeeded")
    } catch let error as LocalSessionError {
        guard case .tooManyFiles(let maximum) = error else {
            Issue.record("unexpected file-count error: \(error)")
            return
        }
        #expect(maximum == UsageLimits.maximumSessionFiles)
    }

    let sparse = directory.appendingPathComponent("sparse.jsonl")
    #expect(FileManager.default.createFile(atPath: sparse.path, contents: nil))
    let sparseHandle = try FileHandle(forWritingTo: sparse)
    try sparseHandle.truncate(
        atOffset: UInt64(UsageLimits.maximumSessionAggregateBytes + 1)
    )
    try sparseHandle.close()
    do {
        _ = try CodexLocalSessionSource.scan(files: [sparse])
        Issue.record("session aggregate-byte limit unexpectedly succeeded")
    } catch let error as LocalSessionError {
        guard case .aggregateTooLarge(let maximumBytes) = error else {
            Issue.record("unexpected aggregate-byte error: \(error)")
            return
        }
        #expect(maximumBytes == UsageLimits.maximumSessionAggregateBytes)
    }

}

@Test("Session scan пропускает огромную строку и продолжает читать статистику")
func localScanSkipsOversizedLine() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("oversized-line.jsonl")
    let oversizedLine = String(
        repeating: "x",
        count: UsageLimits.maximumLogicalLineBytes + 2 * 128 * 1024
    )
    let contextLine = """
    {"timestamp":"2026-07-26T07:59:30Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
    """
    let tokenLine = """
    {"timestamp":"2026-07-26T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":800,"cached_input_tokens":200,"output_tokens":100}}}}
    """
    try Data(
        (oversizedLine + "\n" + contextLine + "\n" + tokenLine).utf8
    ).write(to: file)

    let result = try CodexLocalSessionSource.scan(files: [file])
    let record = try #require(result.records.first)
    #expect(result.records.count == 1)
    #expect(result.tokenEvents == 1)
    #expect(result.malformedLines == 1)
    #expect(record.model == "gpt-5.6-sol")
    #expect(record.totalTokens == 900)
}

@Test("Session counters принимают только конечные целые значения")
func localScanStrictlyDecodesTokenCounters() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("rollout.jsonl")
    let jsonl = """
    {"timestamp":"2026-07-26T07:59:30Z","type":"turn_context","payload":{"model":"model-a"}}
    {"timestamp":"2026-07-26T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":true,"output_tokens":1}}}}
    {"timestamp":"2026-07-26T08:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":false}}}}
    {"timestamp":"2026-07-26T08:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1.5,"output_tokens":1}}}}
    {"timestamp":"2026-07-26T08:03:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":"2.5","output_tokens":1}}}}
    {"timestamp":"2026-07-26T08:04:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":"1e300","output_tokens":1}}}}
    {"timestamp":"2026-07-26T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":"42","output_tokens":7}}}}
    """
    try Data(jsonl.utf8).write(to: file)

    let result = try CodexLocalSessionSource.scan(files: [file])
    let record = try #require(result.records.first)
    #expect(result.records.count == 1)
    #expect(result.tokenEvents == 6)
    #expect(result.malformedLines == 5)
    #expect(record.inputTokens == 42)
    #expect(record.outputTokens == 7)
}

@Test("OTLP JSON envelope преобразуется в live usage")
func parsesOTLPEnvelope() throws {
    let json = """
    {
      "resourceLogs": [{
        "resource": {"attributes": [
          {"key":"gen_ai.response.model","value":{"stringValue":"gpt-5.6-luna"}}
        ]},
        "scopeLogs": [{"logRecords": [{
          "timeUnixNano":"1785060000000000000",
          "attributes":[
            {"key":"event.name","value":{"stringValue":"codex.sse_event"}},
            {"key":"event.kind","value":{"stringValue":"response.completed"}},
            {"key":"input_token_count","value":{"intValue":"900"}},
            {"key":"output_token_count","value":{"intValue":"120"}},
            {"key":"cached_token_count","value":{"intValue":"300"}}
          ]
        }]}]
      }]
    }
    """

    let record = try #require(OTelJSONParser.records(from: Data(json.utf8)).first)
    #expect(record.model == "gpt-5.6-luna")
    #expect(record.inputTokens == 900)
    #expect(record.cachedInputTokens == 300)
    #expect(record.outputTokens == 120)
    #expect(record.source == "otel-live")
}

@Test("Официальная HTML-карточка цены разбирается best effort")
func parsesOfficialPriceCard() throws {
    let html = """
    <div>Input</div><div class="text-2xl font-semibold">$5.00</div>
    <div>Cached input</div><div class="text-2xl font-semibold">$0.50</div>
    <div>Output</div><div class="text-2xl font-semibold">$30.00</div>
    """
    let value = try OfficialPricingCatalog.parsePricing(html)
    #expect(value.input == 5)
    #expect(value.cached == 0.5)
    #expect(value.output == 30)
}

@Test("Long context и priority применяются ко всему запросу")
func appliesLongContextAndPriorityRates() throws {
    let price = ModelPrice(
        modelPattern: "gpt-5.6-test",
        inputPerMillion: 2,
        cachedInputPerMillion: 0.2,
        cacheWritePerMillion: 2.5,
        outputPerMillion: 10,
        priorityMultiplier: 2
    )
    let record = UsageRecord(
        timestamp: Date(),
        model: "gpt-5.6-test",
        inputTokens: 300_000,
        outputTokens: 100_000,
        source: "test",
        reasoningOutputTokens: 50_000,
        serviceTier: "priority"
    )

    let cost = try #require(Pricing.cost(for: record, prices: [price]))
    #expect(abs(cost - 5.4) < 0.000_001)
}

@Test("Fractional timestamp сохраняется для точной дедупликации")
func preservesFractionalTimestamp() throws {
    let original = try #require(DateParsing.parse("2026-07-26T08:00:00.123456Z"))
    let encoded = DateParsing.format(original)
    let decoded = try #require(DateParsing.parse(encoded))
    #expect(abs(decoded.timeIntervalSince(original)) < 0.000_001)
    #expect(encoded.contains(".123456"))
}

private func singleLinePrettyPrintedJSON(
    _ object: [String: Any]
) throws -> String {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    )
    return try #require(String(data: data, encoding: .utf8))
        .replacingOccurrences(of: "\n", with: " ")
}
