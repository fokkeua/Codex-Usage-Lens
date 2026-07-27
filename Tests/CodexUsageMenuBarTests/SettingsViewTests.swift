import Foundation
import Testing
@testable import CodexUsageMenuBar

@Test(
    "UI цен принимает только неотрицательные конечные числа",
    arguments: [
        0.0,
        0.125,
        30.0,
        UsageLimits.maximumPricePerMillion,
    ]
)
func priceInputPolicyAcceptsValidValues(value: Double) {
    #expect(PriceInputPolicy.isAccepted(value))
    #expect(PriceInputPolicy.sanitized(value) == value)
}

@Test(
    "UI цен отклоняет отрицательные и нечисловые значения",
    arguments: [
        -0.001,
        -Double.greatestFiniteMagnitude,
        Double.nan,
        Double.infinity,
        -Double.infinity,
        UsageLimits.maximumPricePerMillion.nextUp,
        Double.greatestFiniteMagnitude,
    ]
)
func priceInputPolicyRejectsInvalidValues(value: Double) {
    #expect(!PriceInputPolicy.isAccepted(value))
    #expect(
        PriceInputPolicy.sanitized(value)
            == (value.isFinite && value > 0
                ? UsageLimits.maximumPricePerMillion
                : 0)
    )
}

@Test("Невалидное редактирование сохраняет последнее валидное значение")
func invalidPriceUpdatePreservesLastValidValue() {
    #expect(
        PriceInputPolicy.resolvedUpdate(-1, current: 2.5) == 2.5
    )
    #expect(
        PriceInputPolicy.resolvedUpdate(.nan, current: .infinity) == 0
    )
    #expect(
        PriceInputPolicy.resolvedUpdate(3.75, current: 2.5) == 3.75
    )
}

@Test("Accessibility-имя удаления цены не бывает пустым")
func priceAccessibilityModelNameHasFallback() {
    #expect(
        PriceInputPolicy.accessibilityModelName("  ") == "модели без названия"
    )
    #expect(
        PriceInputPolicy.accessibilityModelName("  gpt-test*  ") == "gpt-test*"
    )
}

@Test("OTel UI разрешает новую установку и блокирует legacy-конфиг")
func otelSettingsStateUsesConfigurationStatus() {
    let install = OTelSettingsState.resolve(
        status: .absent,
        canInstall: true
    )
    let legacy = OTelSettingsState.resolve(
        status: .managedLegacy,
        canInstall: true
    )
    let existing = OTelSettingsState.resolve(
        status: .existing,
        canInstall: false
    )

    #expect(install.action == .install)
    #expect(install.buttonTitle.contains("Добавить"))
    #expect(legacy.action == nil)
    #expect(legacy.buttonTitle.contains("удалите"))
    #expect(legacy.note.contains("вручную"))
    #expect(existing.action == nil)
    #expect(existing.note.contains("не изменяет существующую секцию"))
}

@Test("OTel UI блокирует действие, если безопасная проверка не разрешает запись")
func otelSettingsStateRequiresCanInstall() {
    let unavailable = OTelSettingsState.resolve(
        status: .absent,
        canInstall: false
    )

    #expect(unavailable.action == nil)
    #expect(unavailable.buttonTitle == "OTel-настройка недоступна")
}

@Test("Подтверждение OTel явно описывает изменение config.toml")
func otelConfirmationDescribesConfigurationMutation() {
    let install = SettingsConfirmation.otel(.install)

    #expect(!install.isDestructive)
    #expect(install.message.contains("~/.codex/config.toml"))
    #expect(install.message.contains("log_user_prompt=false"))
}

@Test("Удаление строки и сброс цен требуют destructive-подтверждения")
func priceConfirmationsAreDestructive() {
    let id = UUID()
    let removal = SettingsConfirmation.removePrice(
        id: id,
        modelName: "gpt-test*"
    )
    let reset = SettingsConfirmation.resetPrices(count: 7)

    #expect(removal.isDestructive)
    #expect(removal.message.contains("gpt-test*"))
    #expect(reset.isDestructive)
    #expect(reset.message.contains("7 строк"))
}

@Test("Price pattern предупреждает о trim+lowercase дубликатах")
func pricePatternWarningsNormalizeDuplicates() {
    let firstID = UUID()
    let duplicateID = UUID()
    let uniqueID = UUID()
    let prices = [
        testPrice(id: firstID, pattern: "  GPT-Test* "),
        testPrice(id: duplicateID, pattern: "gpt-test*"),
        testPrice(id: uniqueID, pattern: "*"),
    ]

    #expect(
        PricePatternWarningPolicy.normalized("  GPT-Test* \n")
            == "gpt-test*"
    )
    #expect(
        PricePatternWarningPolicy.warning(for: firstID, in: prices)
            == .duplicate(isFirst: true, count: 2)
    )
    #expect(
        PricePatternWarningPolicy.warning(for: duplicateID, in: prices)
            == .duplicate(isFirst: false, count: 2)
    )
    #expect(
        PricePatternWarningPolicy.warning(for: uniqueID, in: prices) == nil
    )
}

@Test("Пустой price pattern получает доступное предупреждение")
func emptyPricePatternHasAccessibleWarning() throws {
    let emptyID = UUID()
    let prices = [testPrice(id: emptyID, pattern: " \n\t ")]
    let warning = try #require(
        PricePatternWarningPolicy.warning(for: emptyID, in: prices)
    )

    #expect(warning == .empty)
    #expect(warning.accessibilityLabel == "Предупреждение шаблона цены")
    #expect(warning.accessibilityValue.contains("Шаблон пуст"))
}

private func testPrice(id: UUID, pattern: String) -> ModelPrice {
    ModelPrice(
        id: id,
        modelPattern: pattern,
        inputPerMillion: 1,
        cachedInputPerMillion: 0.1,
        outputPerMillion: 2
    )
}
