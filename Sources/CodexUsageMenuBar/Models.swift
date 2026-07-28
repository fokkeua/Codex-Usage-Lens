import Foundation

enum UsageLimits {
    static let maximumTokenCount = 1_000_000_000_000
    static let maximumRetainedRecords = 100_000
    static let maximumImportFileBytes = 64 * 1024 * 1024
    static let maximumLogicalLineBytes = 1024 * 1024
    static let maximumSessionFiles = 20_000
    static let maximumSessionEntries = 100_000
    static let maximumSessionAggregateBytes = 512 * 1024 * 1024
    static let maximumFlattenedFields = 256
    static let maximumNestingDepth = 32
    // Allows 100k normalized rows with up to 18 members plus their row/root
    // containers, while bounding aggregate JSON tree amplification.
    static let maximumJSONStructuralEntries =
        maximumRetainedRecords * 20 + 1
    static let maximumModelBytes = 512
    static let maximumSourceBytes = 256
    static let maximumServiceTierBytes = 128
    static let maximumGenericStringBytes = 4 * 1024
    static let maximumPriceSourceURLBytes = 4 * 1024
    static let maximumPricePerMillion = 1_000_000.0
    static let maximumPriorityMultiplier = 100.0
    static let maximumCostEstimate = 1_000_000_000_000_000_000.0

    private static let earliestPlausibleTimestamp = 946_684_800.0
    private static let futureTimestampAllowance = 366.0 * 24 * 60 * 60

    static func normalizedTokenCount(_ value: Int) -> Int {
        min(max(0, value), maximumTokenCount)
    }

    static func normalizedTokenCount(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        guard value > 0 else { return 0 }
        guard value < Double(maximumTokenCount) else {
            return maximumTokenCount
        }
        return min(Int(value.rounded(.towardZero)), maximumTokenCount)
    }

    static func normalizedPrice(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return min(value, maximumPricePerMillion)
    }

    static func normalizedPriorityMultiplier(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(0, value), maximumPriorityMultiplier)
    }

    static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard result.overflow else { return result.partialValue }
        return rhs >= 0 ? Int.max : Int.min
    }

    static func saturatingSubtract(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard result.overflow else { return result.partialValue }
        return rhs >= 0 ? Int.min : Int.max
    }

    static func saturatingCostAdd(_ lhs: Double, _ rhs: Double) -> Double {
        guard lhs.isFinite, rhs.isFinite else {
            return maximumCostEstimate
        }
        let sum = lhs + rhs
        guard sum.isFinite else { return maximumCostEstimate }
        return min(max(0, sum), maximumCostEstimate)
    }

    static func isPlausibleTimestamp(
        _ date: Date,
        now: Date = Date()
    ) -> Bool {
        let value = date.timeIntervalSince1970
        let latest = now.timeIntervalSince1970 + futureTimestampAllowance
        return value.isFinite
            && value >= earliestPlausibleTimestamp
            && value <= latest
    }

    static func normalizedTimestamp(
        _ date: Date,
        now: Date = Date()
    ) -> Date {
        let latest = now.timeIntervalSince1970 + futureTimestampAllowance
        let value = date.timeIntervalSince1970
        guard value.isFinite else {
            return Date(timeIntervalSince1970: earliestPlausibleTimestamp)
        }
        return Date(
            timeIntervalSince1970: min(
                max(value, earliestPlausibleTimestamp),
                latest
            )
        )
    }

    static func dateFromAutoDetectedEpoch(
        _ value: Double,
        now: Date = Date()
    ) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        for divisor in [1.0, 1_000.0, 1_000_000.0, 1_000_000_000.0] {
            let date = Date(timeIntervalSince1970: value / divisor)
            if isPlausibleTimestamp(date, now: now) {
                return date
            }
        }
        return nil
    }

    static func boundedString(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> String? {
        guard value.utf8.count <= maximumUTF8Bytes else { return nil }
        return value
    }

    static func normalizedString(
        _ value: String,
        fallback: String,
        maximumUTF8Bytes: Int
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? fallback : trimmed
        guard candidate.utf8.count > maximumUTF8Bytes else {
            return candidate
        }

        var byteCount = 0
        var end = candidate.startIndex
        while end < candidate.endIndex {
            let next = candidate.index(after: end)
            let characterBytes = candidate[end..<next].utf8.count
            guard byteCount + characterBytes <= maximumUTF8Bytes else {
                break
            }
            byteCount += characterBytes
            end = next
        }
        let truncated = String(candidate[..<end])
        return truncated.isEmpty ? fallback : truncated
    }
}

struct UsageRecord: Identifiable, Hashable, Sendable {
    var id: UUID
    var timestamp: Date
    var model: String
    var inputTokens: Int
    var cachedInputTokens: Int
    var cacheWriteTokens: Int
    var outputTokens: Int
    var source: String
    var reasoningOutputTokens: Int?
    var serviceTier: String?
    var threadId: String? {
        get { nil }
        set {}
    }
    var sourceEventId: String? {
        get { nil }
        set {}
    }

    init(
        id: UUID = UUID(),
        timestamp: Date,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        outputTokens: Int,
        source: String,
        reasoningOutputTokens: Int? = nil,
        serviceTier: String? = nil,
        threadId: String? = nil,
        sourceEventId: String? = nil
    ) {
        self.id = id
        self.timestamp = UsageLimits.normalizedTimestamp(timestamp)
        self.model = UsageLimits.normalizedString(
            model,
            fallback: "unknown",
            maximumUTF8Bytes: UsageLimits.maximumModelBytes
        )
        self.inputTokens = UsageLimits.normalizedTokenCount(inputTokens)
        self.outputTokens = UsageLimits.normalizedTokenCount(outputTokens)
        self.cachedInputTokens = min(
            UsageLimits.normalizedTokenCount(cachedInputTokens),
            self.inputTokens
        )
        let remainingInput = self.inputTokens - self.cachedInputTokens
        self.cacheWriteTokens = min(
            UsageLimits.normalizedTokenCount(cacheWriteTokens),
            remainingInput
        )
        self.source = UsageLimits.normalizedString(
            source,
            fallback: "unknown",
            maximumUTF8Bytes: UsageLimits.maximumSourceBytes
        )
        self.reasoningOutputTokens = reasoningOutputTokens.map {
            min(UsageLimits.normalizedTokenCount($0), self.outputTokens)
        }
        self.serviceTier = serviceTier.map {
            UsageLimits.normalizedString(
                $0,
                fallback: "default",
                maximumUTF8Bytes: UsageLimits.maximumServiceTierBytes
            )
        }
        _ = threadId
        _ = sourceEventId
    }

    var totalTokens: Int {
        UsageLimits.saturatingAdd(inputTokens, outputTokens)
    }

    var uncachedInputTokens: Int {
        let afterCache = max(
            0,
            UsageLimits.saturatingSubtract(inputTokens, cachedInputTokens)
        )
        return max(
            0,
            UsageLimits.saturatingSubtract(afterCache, cacheWriteTokens)
        )
    }

    var exactUsageSignature: UsageRecordSignature {
        UsageRecordSignature(
            timestamp: timestamp,
            model: model,
            serviceTier: serviceTier ?? "default",
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteTokens: cacheWriteTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens ?? 0
        )
    }

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
        case threadId
        case sourceEventId
    }
}

extension UsageRecord: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedTimestamp =
            (try? container.decode(Date.self, forKey: .timestamp))
            ?? Date(timeIntervalSince1970: 946_684_800)

        self.init(
            id: (try? container.decode(UUID.self, forKey: .id)) ?? UUID(),
            timestamp: decodedTimestamp,
            model: (try? container.decode(String.self, forKey: .model))
                ?? "unknown",
            inputTokens: container.decodeLossyInt(forKey: .inputTokens) ?? 0,
            cachedInputTokens: container.decodeLossyInt(
                forKey: .cachedInputTokens
            ) ?? 0,
            cacheWriteTokens: container.decodeLossyInt(
                forKey: .cacheWriteTokens
            ) ?? 0,
            outputTokens: container.decodeLossyInt(forKey: .outputTokens) ?? 0,
            source: (try? container.decode(String.self, forKey: .source))
                ?? "unknown",
            reasoningOutputTokens: container.decodeLossyInt(
                forKey: .reasoningOutputTokens
            ),
            serviceTier: try? container.decode(
                String.self,
                forKey: .serviceTier
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(
            UsageLimits.normalizedTimestamp(timestamp),
            forKey: .timestamp
        )
        try container.encode(
            UsageLimits.normalizedString(
                model,
                fallback: "unknown",
                maximumUTF8Bytes: UsageLimits.maximumModelBytes
            ),
            forKey: .model
        )
        let safeInput = UsageLimits.normalizedTokenCount(inputTokens)
        let safeOutput = UsageLimits.normalizedTokenCount(outputTokens)
        let safeCached = min(
            UsageLimits.normalizedTokenCount(cachedInputTokens),
            safeInput
        )
        let safeCacheWrite = min(
            UsageLimits.normalizedTokenCount(cacheWriteTokens),
            safeInput - safeCached
        )
        try container.encode(safeInput, forKey: .inputTokens)
        try container.encode(safeCached, forKey: .cachedInputTokens)
        try container.encode(safeCacheWrite, forKey: .cacheWriteTokens)
        try container.encode(safeOutput, forKey: .outputTokens)
        try container.encode(
            UsageLimits.normalizedString(
                source,
                fallback: "unknown",
                maximumUTF8Bytes: UsageLimits.maximumSourceBytes
            ),
            forKey: .source
        )
        try container.encodeIfPresent(
            reasoningOutputTokens.map {
                min(UsageLimits.normalizedTokenCount($0), safeOutput)
            },
            forKey: .reasoningOutputTokens
        )
        try container.encodeIfPresent(
            serviceTier.map {
                UsageLimits.normalizedString(
                    $0,
                    fallback: "default",
                    maximumUTF8Bytes: UsageLimits.maximumServiceTierBytes
                )
            },
            forKey: .serviceTier
        )
    }
}

struct UsageRecordSignature: Hashable, Sendable {
    let timestamp: Date
    let model: String
    let serviceTier: String
    let inputTokens: Int
    let cachedInputTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
}

struct ModelPrice: Identifiable, Hashable, Sendable {
    var id: UUID
    private var storedModelPattern: String
    var modelPattern: String {
        get { storedModelPattern }
        set {
            storedModelPattern = UsageLimits.normalizedString(
                newValue,
                fallback: "",
                maximumUTF8Bytes: UsageLimits.maximumModelBytes
            )
        }
    }
    private var storedInputPerMillion: Double
    private var storedCachedInputPerMillion: Double
    private var storedCacheWritePerMillion: Double
    private var storedOutputPerMillion: Double
    private var storedPriorityMultiplier: Double?
    var sourceURL: String?
    var lastUpdated: Date?

    var inputPerMillion: Double {
        get { storedInputPerMillion }
        set { storedInputPerMillion = UsageLimits.normalizedPrice(newValue) }
    }

    var cachedInputPerMillion: Double {
        get { storedCachedInputPerMillion }
        set {
            storedCachedInputPerMillion = UsageLimits.normalizedPrice(newValue)
        }
    }

    var cacheWritePerMillion: Double {
        get { storedCacheWritePerMillion }
        set {
            storedCacheWritePerMillion = UsageLimits.normalizedPrice(newValue)
        }
    }

    var outputPerMillion: Double {
        get { storedOutputPerMillion }
        set { storedOutputPerMillion = UsageLimits.normalizedPrice(newValue) }
    }

    var priorityMultiplier: Double? {
        get { storedPriorityMultiplier }
        set {
            storedPriorityMultiplier =
                UsageLimits.normalizedPriorityMultiplier(newValue)
        }
    }

    init(
        id: UUID = UUID(),
        modelPattern: String,
        inputPerMillion: Double,
        cachedInputPerMillion: Double,
        cacheWritePerMillion: Double? = nil,
        outputPerMillion: Double,
        sourceURL: String? = nil,
        lastUpdated: Date? = nil,
        priorityMultiplier: Double? = nil
    ) {
        self.id = id
        storedModelPattern = UsageLimits.normalizedString(
            modelPattern,
            fallback: "",
            maximumUTF8Bytes: UsageLimits.maximumModelBytes
        )
        storedInputPerMillion = UsageLimits.normalizedPrice(inputPerMillion)
        storedCachedInputPerMillion =
            UsageLimits.normalizedPrice(cachedInputPerMillion)
        storedCacheWritePerMillion = UsageLimits.normalizedPrice(
            cacheWritePerMillion ?? inputPerMillion
        )
        storedOutputPerMillion = UsageLimits.normalizedPrice(outputPerMillion)
        self.sourceURL = sourceURL.map {
            UsageLimits.normalizedString(
                $0,
                fallback: "",
                maximumUTF8Bytes: UsageLimits.maximumPriceSourceURLBytes
            )
        }
        self.lastUpdated = lastUpdated.flatMap {
            UsageLimits.isPlausibleTimestamp($0) ? $0 : nil
        }
        storedPriorityMultiplier =
            UsageLimits.normalizedPriorityMultiplier(priorityMultiplier)
    }

    func matches(model: String) -> Bool {
        let pattern = modelPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .precomposedStringWithCanonicalMapping
        let candidate = model
            .lowercased()
            .precomposedStringWithCanonicalMapping

        guard !pattern.isEmpty else { return false }
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") {
            return candidate.hasPrefix(String(pattern.dropLast()))
        }
        return candidate == pattern
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case modelPattern
        case inputPerMillion
        case cachedInputPerMillion
        case cacheWritePerMillion
        case outputPerMillion
        case sourceURL
        case lastUpdated
        case priorityMultiplier
    }
}

extension ModelPrice: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let input = container.decodeLossyDouble(forKey: .inputPerMillion) ?? 0

        self.init(
            id: (try? container.decode(UUID.self, forKey: .id)) ?? UUID(),
            modelPattern:
                (try? container.decode(String.self, forKey: .modelPattern))
                ?? "",
            inputPerMillion: input,
            cachedInputPerMillion: container.decodeLossyDouble(
                forKey: .cachedInputPerMillion
            ) ?? 0,
            cacheWritePerMillion: container.decodeLossyDouble(
                forKey: .cacheWritePerMillion
            ) ?? input,
            outputPerMillion: container.decodeLossyDouble(
                forKey: .outputPerMillion
            ) ?? 0,
            sourceURL: try? container.decode(String.self, forKey: .sourceURL),
            lastUpdated: try? container.decode(Date.self, forKey: .lastUpdated),
            priorityMultiplier: container.decodeLossyDouble(
                forKey: .priorityMultiplier
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(
            UsageLimits.normalizedString(
                modelPattern,
                fallback: "",
                maximumUTF8Bytes: UsageLimits.maximumModelBytes
            ),
            forKey: .modelPattern
        )
        try container.encode(inputPerMillion, forKey: .inputPerMillion)
        try container.encode(
            cachedInputPerMillion,
            forKey: .cachedInputPerMillion
        )
        try container.encode(
            cacheWritePerMillion,
            forKey: .cacheWritePerMillion
        )
        try container.encode(outputPerMillion, forKey: .outputPerMillion)
        try container.encodeIfPresent(
            sourceURL.map {
                UsageLimits.normalizedString(
                    $0,
                    fallback: "",
                    maximumUTF8Bytes:
                        UsageLimits.maximumPriceSourceURLBytes
                )
            },
            forKey: .sourceURL
        )
        try container.encodeIfPresent(
            lastUpdated.flatMap {
                UsageLimits.isPlausibleTimestamp($0) ? $0 : nil
            },
            forKey: .lastUpdated
        )
        try container.encodeIfPresent(
            priorityMultiplier,
            forKey: .priorityMultiplier
        )
    }
}

enum UsageSourceKind: String, Codable, CaseIterable, Sendable {
    case empty
    case demo
    case importedFile
    case codexLocal
    case otelLive

    var title: String {
        switch self {
        case .empty: L10n.string("source.empty")
        case .demo: L10n.string("source.demo")
        case .importedFile: L10n.string("source.imported")
        case .codexLocal: L10n.string("source.codexLocal")
        case .otelLive: L10n.string("source.otelLive")
        }
    }
}

struct UsageSummary: Sendable {
    var inputTokens = 0
    var cachedInputTokens = 0
    var cacheWriteTokens = 0
    var outputTokens = 0
    var apiEquivalentCost = 0.0
    var unpricedRecords = 0
    var recordCount = 0

    var totalTokens: Int {
        UsageLimits.saturatingAdd(inputTokens, outputTokens)
    }

    var uncachedInputTokens: Int {
        let afterCache = max(
            0,
            UsageLimits.saturatingSubtract(inputTokens, cachedInputTokens)
        )
        return max(
            0,
            UsageLimits.saturatingSubtract(afterCache, cacheWriteTokens)
        )
    }

    mutating func add(_ record: UsageRecord, cost: Double?) {
        inputTokens = UsageLimits.saturatingAdd(
            inputTokens,
            record.inputTokens
        )
        cachedInputTokens = UsageLimits.saturatingAdd(
            cachedInputTokens,
            record.cachedInputTokens
        )
        cacheWriteTokens = UsageLimits.saturatingAdd(
            cacheWriteTokens,
            record.cacheWriteTokens
        )
        outputTokens = UsageLimits.saturatingAdd(
            outputTokens,
            record.outputTokens
        )
        recordCount = UsageLimits.saturatingAdd(recordCount, 1)
        if let cost, cost.isFinite, cost >= 0 {
            apiEquivalentCost = UsageLimits.saturatingCostAdd(
                apiEquivalentCost,
                cost
            )
        } else {
            unpricedRecords = UsageLimits.saturatingAdd(unpricedRecords, 1)
        }
    }

    mutating func add(_ other: UsageSummary) {
        inputTokens = UsageLimits.saturatingAdd(inputTokens, other.inputTokens)
        cachedInputTokens = UsageLimits.saturatingAdd(
            cachedInputTokens,
            other.cachedInputTokens
        )
        cacheWriteTokens = UsageLimits.saturatingAdd(
            cacheWriteTokens,
            other.cacheWriteTokens
        )
        outputTokens = UsageLimits.saturatingAdd(
            outputTokens,
            other.outputTokens
        )
        apiEquivalentCost = UsageLimits.saturatingCostAdd(
            apiEquivalentCost,
            other.apiEquivalentCost
        )
        unpricedRecords = UsageLimits.saturatingAdd(
            unpricedRecords,
            other.unpricedRecords
        )
        recordCount = UsageLimits.saturatingAdd(
            recordCount,
            other.recordCount
        )
    }
}

struct DailyUsage: Identifiable, Sendable {
    let date: Date
    let model: String
    let summary: UsageSummary

    var id: String {
        "\(date.timeIntervalSince1970)-\(model)"
    }
}

struct ModelUsage: Identifiable, Sendable {
    let model: String
    let summary: UsageSummary

    var id: String { model }
}

struct ImportResult: Sendable {
    let records: [UsageRecord]
    let format: String
    let skippedRows: Int
}

struct AccountUsageDailyBucket: Identifiable, Codable, Hashable, Sendable {
    let startDate: String
    let tokens: Int

    var id: String { startDate }

    var date: Date? {
        DateParsing.parse(startDate)
    }
}

struct AccountUsageSummary: Codable, Hashable, Sendable {
    let lifetimeTokens: Int?
    let peakDailyTokens: Int?
    let longestRunningTurnSec: Int?
    let currentStreakDays: Int?
    let longestStreakDays: Int?
}

struct AccountUsageSnapshot: Codable, Hashable, Sendable {
    let summary: AccountUsageSummary
    let dailyUsageBuckets: [AccountUsageDailyBucket]?
    var fetchedAt: Date
    var codexExecutable: String?

    func tokens(on date: Date, calendar: Calendar = .current) -> Int? {
        dailyUsageBuckets?.first {
            guard let bucketDate = $0.date else { return false }
            return calendar.isDate(bucketDate, inSameDayAs: date)
        }?.tokens
    }
}

struct CodexAccountProfile: Codable, Hashable, Sendable {
    let kind: String
    let email: String?
    let planType: String?
}

struct CodexRateLimitWindow: Codable, Hashable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int?

    var resetDate: Date? {
        resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

struct CodexCreditsSnapshot: Codable, Hashable, Sendable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct CodexSpendControlSnapshot: Codable, Hashable, Sendable {
    let limit: String
    let remainingPercent: Int
    let resetsAt: Int
    let used: String
}

struct CodexRateLimitBucket: Codable, Hashable, Sendable {
    let credits: CodexCreditsSnapshot?
    let individualLimit: CodexSpendControlSnapshot?
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: CodexRateLimitWindow?
    let rateLimitReachedType: String?
    let secondary: CodexRateLimitWindow?
    let spendControlReached: Bool?
}

struct CodexRateLimitResetCredit: Codable, Hashable, Sendable {
    let description: String?
    let expiresAt: Int?
    let grantedAt: Int
    let id: String
    let resetType: String
    let status: String
    let title: String?

    var expirationDate: Date? {
        expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

struct CodexRateLimitResetCreditsSummary: Codable, Hashable, Sendable {
    let availableCount: Int
    let credits: [CodexRateLimitResetCredit]?
}

struct CodexRateLimitsSnapshot: Decodable, Hashable, Sendable {
    let rateLimits: CodexRateLimitBucket
    let rateLimitsByLimitId: [String: CodexRateLimitBucket]?
    let rateLimitResetCredits: CodexRateLimitResetCreditsSummary?
    var fetchedAt: Date

    private enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitId
        case rateLimitResetCredits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimits = try container.decode(
            CodexRateLimitBucket.self,
            forKey: .rateLimits
        )
        rateLimitsByLimitId = try container.decodeIfPresent(
            [String: CodexRateLimitBucket].self,
            forKey: .rateLimitsByLimitId
        )
        rateLimitResetCredits = try container.decodeIfPresent(
            CodexRateLimitResetCreditsSummary.self,
            forKey: .rateLimitResetCredits
        )
        fetchedAt = Date()
    }

    var preferredBucket: CodexRateLimitBucket {
        if
            let codex = rateLimitsByLimitId?["codex"]
                ?? rateLimitsByLimitId?.first(where: {
                    $0.key.localizedCaseInsensitiveContains("codex")
                })?.value
        {
            return codex
        }
        return rateLimits
    }
}

struct CodexModelInfo: Codable, Hashable, Sendable {
    let id: String?
    let model: String?
    let displayName: String?
    let hidden: Bool?
    let isDefault: Bool?
}

struct CodexAccountResult: Sendable {
    let usage: AccountUsageSnapshot
    let models: [CodexModelInfo]
    let profile: CodexAccountProfile?
    let rateLimits: CodexRateLimitsSnapshot?

    init(
        usage: AccountUsageSnapshot,
        models: [CodexModelInfo],
        profile: CodexAccountProfile? = nil,
        rateLimits: CodexRateLimitsSnapshot? = nil
    ) {
        self.usage = usage
        self.models = models
        self.profile = profile
        self.rateLimits = rateLimits
    }
}

struct LocalScanResult: Sendable {
    let records: [UsageRecord]
    let filesScanned: Int
    let tokenEvents: Int
    let duplicatesRemoved: Int
    let missingModel: Int
    let malformedLines: Int
}

struct UsageReconciliation: Sendable {
    let officialTokens: Int
    let detailedTokens: Int

    var delta: Int {
        UsageLimits.saturatingSubtract(detailedTokens, officialTokens)
    }

    var coverage: Double {
        guard officialTokens > 0 else { return 0 }
        return Double(detailedTokens) / Double(officialTokens)
    }
}

enum UsageImportError: LocalizedError {
    case unreadable
    case unsafeFile
    case unsupportedFormat(String)
    case noRecords
    case malformed(String)
    case fileTooLarge(maximumBytes: Int)
    case lineTooLong(maximumBytes: Int)
    case tooManyRecords(maximum: Int)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "Не удалось прочитать выбранный файл."
        case .unsafeFile:
            "Можно импортировать только обычный файл, не symbolic link или special file."
        case .unsupportedFormat(let extensionName):
            "Формат .\(extensionName) не поддерживается. Используйте JSON, JSONL или CSV."
        case .noRecords:
            "В файле не найдено корректных записей usage."
        case .malformed(let message):
            "Некорректные данные: \(message)"
        case .fileTooLarge(let maximumBytes):
            "Файл превышает безопасный предел \(maximumBytes) байт."
        case .lineTooLong(let maximumBytes):
            "Строка превышает безопасный предел \(maximumBytes) байт."
        case .tooManyRecords(let maximum):
            "Файл содержит больше \(maximum) записей."
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyInt(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) {
            return UsageLimits.normalizedTokenCount(value)
        }
        if let value = try? decode(Double.self, forKey: key) {
            return UsageLimits.normalizedTokenCount(value)
        }
        if
            let value = try? decode(String.self, forKey: key),
            let number = Double(value)
        {
            return UsageLimits.normalizedTokenCount(number)
        }
        return nil
    }

    func decodeLossyDouble(forKey key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if
            let value = try? decode(String.self, forKey: key),
            let number = Double(value)
        {
            return number
        }
        return nil
    }
}
