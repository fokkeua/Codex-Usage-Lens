import Foundation
import Testing
@testable import CodexUsageMenuBar

@Test("Цвет неизвестной модели стабилен между диапазонами")
func modelPaletteUsesStableIndex() {
    let first = ModelPalette.stableIndex(for: "future-codex-model", count: 6)
    let second = ModelPalette.stableIndex(for: "future-codex-model", count: 6)

    #expect(first == second)
    #expect((0..<6).contains(first))
}

@Test("Палитра безопасно обрабатывает пустой список цветов")
func modelPaletteHandlesEmptyFallback() {
    #expect(ModelPalette.stableIndex(for: "future-codex-model", count: 0) == 0)
}

@Test("Количество ответов использует русское склонение")
func responseCountUsesRussianPluralRules() {
    let cases = [
        (0, "ответов"),
        (1, "ответ"),
        (2, "ответа"),
        (4, "ответа"),
        (5, "ответов"),
        (11, "ответов"),
        (14, "ответов"),
        (21, "ответ"),
        (22, "ответа"),
        (25, "ответов"),
        (101, "ответ"),
        (111, "ответов"),
    ]

    for (count, expected) in cases {
        #expect(UsageFormatting.responseWord(for: count) == expected)
    }
    #expect(UsageFormatting.responses(21).hasSuffix("21 ответ Codex"))
}

@Test("Пользовательское форматирование всегда использует ru_RU")
func usageFormattingUsesRussianLocale() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let date = try #require(
        calendar.date(
            from: DateComponents(
                year: 2026,
                month: 1,
                day: 2,
                hour: 12
            )
        )
    )

    #expect(UsageFormatting.locale.identifier == "ru_RU")
    #expect(UsageFormatting.shortDate(date).lowercased().contains("янв"))
    #expect(UsageFormatting.dollars(1.5).contains("1,50"))
    #expect(
        UsageFormatting.percent(
            0.125,
            fractionLength: 1...1
        ).contains("12,5")
    )
}

@Test("Карточка официальных данных различает обновление и ошибку")
func dataRefreshDisplayStateDoesNotPresentStaleDataAsCurrent() {
    let current = DataRefreshDisplayState.resolve(
        isRefreshing: false,
        hasError: false
    )
    let refreshing = DataRefreshDisplayState.resolve(
        isRefreshing: true,
        hasError: false
    )
    let failed = DataRefreshDisplayState.resolve(
        isRefreshing: false,
        hasError: true
    )

    #expect(current == .current)
    #expect(!current.usesOperationStatus)
    #expect(current.accountIcon(hasValue: true) == "checkmark.seal.fill")
    #expect(refreshing == .refreshing)
    #expect(refreshing.usesOperationStatus)
    #expect(refreshing.accountIcon(hasValue: true) == "arrow.triangle.2.circlepath")
    #expect(failed == .failed)
    #expect(failed.usesOperationStatus)
    #expect(failed.accountIcon(hasValue: true) == "exclamationmark.triangle.fill")
}
