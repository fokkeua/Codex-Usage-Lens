import Foundation

protocol UsageDataSource {
    var displayName: String { get }
    func load() throws -> [UsageRecord]
}

struct DemoUsageSource: UsageDataSource {
    let displayName = "Встроенный демо-набор"
    var calendar = Calendar.current
    var now = Date()

    func load() throws -> [UsageRecord] {
        let models = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
        var result: [UsageRecord] = []

        for dayOffset in 0..<21 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else {
                continue
            }
            let weekdayFactor = calendar.isDateInWeekend(day) ? 0.38 : 1.0

            for modelIndex in models.indices {
                if (dayOffset + modelIndex * 2).isMultiple(of: 5) {
                    continue
                }

                let base = Double(58_000 + (dayOffset * 13_771 + modelIndex * 27_409) % 155_000)
                let input = Int(base * weekdayFactor)
                let cached = Int(Double(input) * (0.23 + Double((dayOffset + modelIndex) % 4) * 0.11))
                let cacheWrite = models[modelIndex].hasPrefix("gpt-5.6")
                    ? Int(Double(input) * 0.04)
                    : 0
                let output = Int(Double(input) * (0.09 + Double(modelIndex) * 0.025))
                let hour = 10 + (dayOffset * 3 + modelIndex * 2) % 9
                let timestamp = calendar.date(bySettingHour: hour, minute: 15, second: 0, of: day) ?? day

                result.append(
                    UsageRecord(
                        timestamp: timestamp,
                        model: models[modelIndex],
                        inputTokens: input,
                        cachedInputTokens: cached,
                        cacheWriteTokens: cacheWrite,
                        outputTokens: output,
                        source: "demo"
                    )
                )
            }
        }

        return result.sorted { $0.timestamp > $1.timestamp }
    }
}

struct FileUsageSource: UsageDataSource {
    let url: URL
    var displayName: String { url.lastPathComponent }

    func load() throws -> [UsageRecord] {
        try UsageImporter.importFile(url).records
    }
}
