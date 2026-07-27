import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case french = "fr"
    case spanish = "es"
    case german = "de"
    case russian = "ru"
    case ukrainian = "uk"

    static let supportedLanguageCodes = Set(
        allCases.compactMap(\.languageCode)
    )

    var id: String { rawValue }

    var languageCode: String? {
        self == .system ? nil : rawValue
    }

    var nativeName: String {
        switch self {
        case .system:
            L10n.string("language.system")
        case .english:
            "English"
        case .french:
            "Français"
        case .spanish:
            "Español"
        case .german:
            "Deutsch"
        case .russian:
            "Русский"
        case .ukrainian:
            "Українська"
        }
    }

    static func resolved(
        selection: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        guard selection == .system else { return selection }

        for identifier in preferredLanguages {
            let normalized = identifier
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            let code = normalized.split(separator: "-").first.map(String.init)
            if let code,
               let language = allCases.first(where: {
                   $0.languageCode == code
               })
            {
                return language
            }
        }
        return .english
    }

    var locale: Locale {
        switch self {
        case .system:
            Locale.autoupdatingCurrent
        case .english:
            Locale(identifier: "en_US")
        case .french:
            Locale(identifier: "fr_FR")
        case .spanish:
            Locale(identifier: "es_ES")
        case .german:
            Locale(identifier: "de_DE")
        case .russian:
            Locale(identifier: "ru_RU")
        case .ukrainian:
            Locale(identifier: "uk_UA")
        }
    }
}

final class AppLanguageController: ObservableObject {
    static let storageKey = "appLanguage"
    static let shared = AppLanguageController(
        selectionOverride: (
            ProcessInfo.processInfo.processName.contains("xctest")
                || CommandLine.arguments.contains(where: {
                    $0.contains(".xctest")
                })
                || NSClassFromString("XCTestCase") != nil
                || NSClassFromString("XCTest.XCTestCase") != nil
        ) ? .russian : nil
    )

    @Published var selection: AppLanguage {
        didSet {
            defaults.set(selection.rawValue, forKey: Self.storageKey)
        }
    }

    private let defaults: UserDefaults
    private let preferredLanguages: () -> [String]
    private var localeObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        preferredLanguages: @escaping () -> [String] = {
            Locale.preferredLanguages
        },
        selectionOverride: AppLanguage? = nil
    ) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        selection = selectionOverride
            ?? defaults
                .string(forKey: Self.storageKey)
                .flatMap(AppLanguage.init(rawValue:))
            ?? .system
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.selection == .system else { return }
            self?.objectWillChange.send()
        }
    }

    deinit {
        if let localeObserver {
            NotificationCenter.default.removeObserver(localeObserver)
        }
    }

    var resolvedLanguage: AppLanguage {
        AppLanguage.resolved(
            selection: selection,
            preferredLanguages: preferredLanguages()
        )
    }

    var locale: Locale {
        resolvedLanguage.locale
    }
}

enum L10n {
    static var language: AppLanguage {
        AppLanguageController.shared.resolvedLanguage
    }

    static func string(_ key: String) -> String {
        string(key, language: language)
    }

    static func string(
        _ key: String,
        language: AppLanguage
    ) -> String {
        let resolved = AppLanguage.resolved(selection: language)
        let code = resolved.languageCode ?? "en"
        let bundle = localizedBundle(languageCode: code)
        return bundle.localizedString(
            forKey: key,
            value: fallbackValue(for: key),
            table: nil
        )
    }

    static func format(
        _ key: String,
        _ arguments: CVarArg...
    ) -> String {
        format(
            key,
            language: language,
            arguments: arguments
        )
    }

    static func format(
        _ key: String,
        language: AppLanguage,
        _ arguments: CVarArg...
    ) -> String {
        format(
            key,
            language: language,
            arguments: arguments
        )
    }

    static func translations(
        language: AppLanguage
    ) -> [String: String] {
        let resolved = AppLanguage.resolved(selection: language)
        let code = resolved.languageCode ?? "en"
        guard
            let path = Bundle.module.path(
                forResource: "Localizable",
                ofType: "strings",
                inDirectory: nil,
                forLocalization: code
            ),
            let dictionary = NSDictionary(contentsOfFile: path)
                as? [String: String]
        else {
            return [:]
        }
        return dictionary
    }

    static func presentation(_ source: String) -> String {
        presentation(source, language: language)
    }

    static func presentation(
        _ source: String,
        language: AppLanguage
    ) -> String {
        let direct = string(source, language: language)
        if direct != source || language == .russian {
            return direct
        }

        if let values = captures(
            #"^([0-9]+) реальных ответов • ([0-9]+) файлов$"#,
            in: source
        ) {
            return format(
                "status.scan.records",
                language: language,
                values[0],
                pluralWord(
                    "count.realResponse",
                    count: values[0],
                    language: language
                ),
                values[1],
                pluralWord(
                    "count.file",
                    count: values[1],
                    language: language
                )
            )
        }
        if let values = captures(
            #"^Получено официально • lifetime (.+)$"#,
            in: source
        ) {
            return format(
                "status.account.success",
                language: language,
                values[0]
            )
        }
        if let values = captures(
            #"^(Полный scan|Incremental) • ([0-9]+) событий • дублей ([0-9]+)(?: • без модели ([0-9]+))?$"#,
            in: source
        ) {
            let key = values[0] == "Полный scan"
                ? "status.scan.full"
                : "status.scan.incremental"
            var result = format(
                key,
                language: language,
                values[1],
                pluralWord(
                    "count.event",
                    count: values[1],
                    language: language
                ),
                values[2],
                pluralWord(
                    "count.duplicate",
                    count: values[2],
                    language: language
                )
            )
            if values.count > 3, !values[3].isEmpty {
                result += format(
                    "status.scan.missingModel",
                    language: language,
                    values[3]
                )
            }
            return result
        }
        if let values = captures(
            #"^Слушает (.+)$"#,
            in: source
        ) {
            return format(
                "status.otel.listening",
                language: language,
                values[0]
            )
        }
        if let values = captures(
            #"^([0-9]+) записей • (.+?)(?: • пропущено: ([0-9]+))?$"#,
            in: source
        ) {
            var result = format(
                "status.import.success",
                language: language,
                values[0],
                pluralWord(
                    "count.record",
                    count: values[0],
                    language: language
                ),
                values[1]
            )
            if values.count > 2, !values[2].isEmpty {
                result += format(
                    "status.import.skipped",
                    language: language,
                    values[2]
                )
            }
            return result
        }
        if let values = captures(
            #"^Получено live OTel: ([0-9]+)$"#,
            in: source
        ) {
            return format(
                "status.otel.received",
                language: language,
                values[0]
            )
        }
        if let values = captures(
            #"^Официальные цены актуальны • (.+)$"#,
            in: source
        ) {
            return format(
                "status.prices.current",
                language: language,
                values[0]
            )
        }
        if let values = captures(
            #"^Обновлено с developers\.openai\.com • (.+)$"#,
            in: source
        ) {
            return format(
                "status.prices.updated",
                language: language,
                values[0]
            )
        }
        if let values = captures(
            #"^Последняя синхронизация (.+)$"#,
            in: source
        ) {
            return format(
                "status.lastSync",
                language: language,
                values[0]
            )
        }
        if let values = captures(
            #"^Импортируется (.+)…$"#,
            in: source
        ) {
            return format(
                "status.import.loading",
                language: language,
                values[0]
            )
        }
        if let values = captures(
            #"^Ошибка: (.+)$"#,
            in: source
        ) {
            return format(
                "status.error",
                language: language,
                values[0]
            )
        }
        return source
    }

    private static func format(
        _ key: String,
        language: AppLanguage,
        arguments: [CVarArg]
    ) -> String {
        let resolved = AppLanguage.resolved(selection: language)
        return String(
            format: string(key, language: resolved),
            locale: resolved.locale,
            arguments: arguments
        )
    }

    private static func localizedBundle(languageCode: String) -> Bundle {
        guard
            let path = Bundle.module.path(
                forResource: languageCode,
                ofType: "lproj"
            ),
            let bundle = Bundle(path: path)
        else {
            return Bundle.module
        }
        return bundle
    }

    private static func captures(
        _ pattern: String,
        in value: String
    ) -> [String]? {
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
            ),
            match.range.location != NSNotFound
        else {
            return nil
        }

        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard
                range.location != NSNotFound,
                let swiftRange = Range(range, in: value)
            else {
                return ""
            }
            return String(value[swiftRange])
        }
    }

    private static func pluralWord(
        _ key: String,
        count: String,
        language: AppLanguage
    ) -> String {
        let value = Int(count) ?? 0
        let category = UsageFormatting.pluralCategory(
            for: value,
            language: language
        )
        return string(
            "\(key).\(category)",
            language: language
        )
    }

    private static func fallbackValue(for key: String) -> String {
        guard
            let path = Bundle.module.path(
                forResource: "en",
                ofType: "lproj"
            ),
            let bundle = Bundle(path: path)
        else {
            return key
        }
        return bundle.localizedString(
            forKey: key,
            value: key,
            table: nil
        )
    }
}

struct LocalizedAppRoot<Content: View>: View {
    @ObservedObject var languageController: AppLanguageController
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environmentObject(languageController)
            .environment(\.locale, languageController.locale)
            .id(languageController.resolvedLanguage.rawValue)
    }
}
