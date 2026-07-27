import Foundation
import SwiftUI

enum UsageFormatting {
    static var locale: Locale {
        AppLanguageController.shared.locale
    }

    static func tokens(_ value: Int) -> String {
        value.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
                .locale(locale)
        )
    }

    static func fullTokens(_ value: Int) -> String {
        fullTokens(value, locale: locale)
    }

    static func fullTokens(
        _ value: Int,
        language: AppLanguage
    ) -> String {
        fullTokens(value, locale: language.locale)
    }

    private static func fullTokens(
        _ value: Int,
        locale: Locale
    ) -> String {
        value.formatted(
            .number
                .grouping(.automatic)
                .locale(locale)
        )
    }

    static func dollars(_ value: Double) -> String {
        if value < 0.01, value > 0 {
            return value.formatted(
                .currency(code: "USD")
                    .precision(.fractionLength(4))
                    .locale(locale)
            )
        }
        return value.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(2))
                .locale(locale)
        )
    }

    static func shortDate(_ value: Date) -> String {
        value.formatted(
            .dateTime
                .day()
                .month(.abbreviated)
                .locale(locale)
        )
    }

    static func date(_ value: Date) -> String {
        value.formatted(
            .dateTime
                .day()
                .month(.abbreviated)
                .year()
                .locale(locale)
        )
    }

    static func dateTime(_ value: Date) -> String {
        value.formatted(
            .dateTime
                .day()
                .month(.abbreviated)
                .year()
                .hour()
                .minute()
                .locale(locale)
        )
    }

    static func percent(
        _ value: Double,
        fractionLength: ClosedRange<Int> = 0...1
    ) -> String {
        value.formatted(
            .percent
                .precision(.fractionLength(fractionLength))
                .locale(locale)
        )
    }

    static func responseWord(
        for count: Int,
        language: AppLanguage? = nil
    ) -> String {
        let effectiveLanguage =
            language ?? AppLanguageController.shared.resolvedLanguage
        let category = pluralCategory(
            for: count,
            language: effectiveLanguage
        )
        return L10n.string(
            "responses.word.\(category)",
            language: effectiveLanguage
        )
    }

    static func responses(
        _ count: Int,
        language: AppLanguage? = nil
    ) -> String {
        let effectiveLanguage =
            language ?? AppLanguageController.shared.resolvedLanguage
        return L10n.format(
            "responses.count",
            language: effectiveLanguage,
            fullTokens(count, language: effectiveLanguage),
            responseWord(for: count, language: effectiveLanguage)
        )
    }

    static func responseUnit(for count: Int) -> String {
        L10n.format(
            "responses.unit",
            responseWord(for: count)
        )
    }

    static func modelDisplayName(_ model: String) -> String {
        let normalized = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty || normalized == "unknown"
            ? L10n.string("model.unknown")
            : model
    }

    static func pluralCategory(
        for count: Int,
        language: AppLanguage
    ) -> String {
        let magnitude = count.magnitude

        switch language {
        case .russian, .ukrainian:
            let lastTwoDigits = magnitude % 100
            if (11...14).contains(lastTwoDigits) {
                return "many"
            }
            switch magnitude % 10 {
            case 1:
                return "one"
            case 2...4:
                return "few"
            default:
                return "many"
            }
        case .french:
            return magnitude == 0 || magnitude == 1 ? "one" : "many"
        case .english, .spanish, .german, .system:
            return magnitude == 1 ? "one" : "many"
        }
    }
}

extension Color {
    static let usageBlue = Color(red: 0.08, green: 0.45, blue: 0.96)
    static let usageTeal = Color(red: 0.10, green: 0.64, blue: 0.55)
    static let usageOrange = Color(red: 0.95, green: 0.48, blue: 0.15)
    static let usagePurple = Color(red: 0.59, green: 0.31, blue: 0.90)
    static let usageRed = Color(red: 0.92, green: 0.25, blue: 0.30)
}

enum ModelPalette {
    private static let fallback: [Color] = [
        Color(red: 0.18, green: 0.57, blue: 0.72),
        Color(red: 0.37, green: 0.42, blue: 0.86),
        Color(red: 0.82, green: 0.30, blue: 0.55),
        Color(red: 0.68, green: 0.49, blue: 0.12),
        Color(red: 0.23, green: 0.57, blue: 0.43),
        Color(red: 0.38, green: 0.45, blue: 0.54),
    ]

    static func color(for model: String) -> Color {
        let normalized = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.contains("gpt-5.6-sol") {
            return .usageBlue
        }
        if normalized.contains("gpt-5.6-luna") {
            return .usageTeal
        }
        if normalized.contains("gpt-5.6-terra") {
            return .usageRed
        }
        if normalized.contains("auto-review") {
            return .usageOrange
        }
        if normalized.isEmpty || normalized == "unknown" {
            return .usagePurple
        }

        return fallback[stableIndex(for: normalized, count: fallback.count)]
    }

    static func stableIndex(for model: String, count: Int) -> Int {
        guard count > 0 else { return 0 }

        // Swift's Hasher is intentionally randomized between launches. FNV-1a
        // keeps an unfamiliar model on the same fallback color every time.
        let hash = model.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}
