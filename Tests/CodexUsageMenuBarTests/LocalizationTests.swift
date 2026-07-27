import Foundation
import Testing
@testable import CodexUsageMenuBar

@Test(
    "Системный язык разрешается в поддерживаемую локаль",
    arguments: [
        ("uk-UA", AppLanguage.ukrainian),
        ("de-DE", AppLanguage.german),
        ("fr-CA", AppLanguage.french),
        ("es_ES", AppLanguage.spanish),
        ("ru_UA", AppLanguage.russian),
        ("en-GB", AppLanguage.english),
        ("pl-PL", AppLanguage.english),
    ]
)
func systemLanguageResolution(
    identifier: String,
    expected: AppLanguage
) {
    #expect(
        AppLanguage.resolved(
            selection: .system,
            preferredLanguages: [identifier]
        ) == expected
    )
}

@Test("Явно выбранный язык не зависит от системного")
func explicitLanguageResolution() {
    #expect(
        AppLanguage.resolved(
            selection: .ukrainian,
            preferredLanguages: ["de-DE"]
        ) == .ukrainian
    )
}

@Test("Выбор языка сохраняется отдельно от usage-состояния")
func languageSelectionPersists() throws {
    let suiteName = "CodexUsageMenuBarTests.Language.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let first = AppLanguageController(
        defaults: defaults,
        preferredLanguages: { ["en-US"] }
    )
    #expect(first.selection == .system)
    first.selection = .german

    let second = AppLanguageController(
        defaults: defaults,
        preferredLanguages: { ["en-US"] }
    )
    #expect(second.selection == .german)
    #expect(second.locale.identifier == "de_DE")
}

@Test("Все локали содержат одинаковый набор переводов и placeholders")
func localizationCatalogsAreComplete() throws {
    let languages: [AppLanguage] = [
        .english,
        .french,
        .spanish,
        .german,
        .russian,
        .ukrainian,
    ]
    let english = L10n.translations(language: .english)
    #expect(english.count >= 180)

    for language in languages {
        let translations = L10n.translations(language: language)
        #expect(Set(translations.keys) == Set(english.keys))
        #expect(translations.values.allSatisfy { !$0.isEmpty })

        for key in english.keys {
            let base = try #require(english[key])
            let localized = try #require(translations[key])
            #expect(placeholders(in: localized) == placeholders(in: base))
            if key.first?.isASCII == true, key.contains(".") {
                #expect(localized != key)
            }
        }
    }
}

@Test("Основные строки доступны на всех шести языках")
func coreStringsAreLocalized() {
    let expectations: [(AppLanguage, String)] = [
        (.english, "Settings…"),
        (.french, "Réglages…"),
        (.spanish, "Ajustes…"),
        (.german, "Einstellungen…"),
        (.russian, "Настройки…"),
        (.ukrainian, "Налаштування…"),
    ]

    for (language, expected) in expectations {
        #expect(
            L10n.string(
                "settings.command",
                language: language
            ) == expected
        )
    }
}

@Test("Формы количества ответов корректны для поддерживаемых языков")
func responsePluralRulesCoverAllLanguages() {
    let slavicCounts = [0, 1, 2, 5, 11, 21, 22, 25]
    let expectedRussian = [
        "ответов", "ответ", "ответа", "ответов",
        "ответов", "ответ", "ответа", "ответов",
    ]
    let expectedUkrainian = [
        "відповідей", "відповідь", "відповіді", "відповідей",
        "відповідей", "відповідь", "відповіді", "відповідей",
    ]

    for (index, count) in slavicCounts.enumerated() {
        #expect(
            UsageFormatting.responseWord(
                for: count,
                language: .russian
            ) == expectedRussian[index]
        )
        #expect(
            UsageFormatting.responseWord(
                for: count,
                language: .ukrainian
            ) == expectedUkrainian[index]
        )
    }

    for language in [
        AppLanguage.english,
        .spanish,
        .german,
    ] {
        #expect(
            UsageFormatting.responseWord(
                for: 1,
                language: language
            ) != UsageFormatting.responseWord(
                for: 2,
                language: language
            )
        )
    }
    #expect(
        UsageFormatting.responseWord(
            for: 0,
            language: .french
        ) == "réponse"
    )
    #expect(
        UsageFormatting.responseWord(
            for: 2,
            language: .french
        ) == "réponses"
    )
}

@Test("Сохранённые русские статусы локализуются вместе с числами")
func persistedStatusMessagesAreLocalized() {
    #expect(
        L10n.presentation(
            "103 реальных ответов • 1 файлов",
            language: .ukrainian
        ) == "103 реальні відповіді • 1 файл"
    )
    #expect(
        L10n.presentation(
            "Incremental • 108 событий • дублей 0",
            language: .german
        ) == "Inkrementell • 108 Ereignisse • 0 Duplikate"
    )
    #expect(
        L10n.presentation(
            "Слушает 127.0.0.1:4319",
            language: .french
        ) == "Écoute sur 127.0.0.1:4319"
    )
}

private func placeholders(in value: String) -> [String] {
    let expression = try! NSRegularExpression(
        pattern: "%(?:[0-9]+\\$)?[@df]"
    )
    let range = NSRange(value.startIndex..., in: value)
    return expression.matches(in: value, range: range).compactMap {
        Range($0.range, in: value).map { String(value[$0]) }
    }
}
