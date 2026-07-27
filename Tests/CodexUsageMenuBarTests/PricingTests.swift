import Foundation
import Testing
@testable import CodexUsageMenuBar

@Test("Стоимость учитывает uncached, cache read, cache write и output отдельно")
func calculatesAPEquivalentCost() throws {
    let price = ModelPrice(
        modelPattern: "test-model",
        inputPerMillion: 2,
        cachedInputPerMillion: 0.2,
        cacheWritePerMillion: 2.5,
        outputPerMillion: 10
    )
    let record = UsageRecord(
        timestamp: Date(),
        model: "test-model",
        inputTokens: 1_000_000,
        cachedInputTokens: 200_000,
        cacheWriteTokens: 100_000,
        outputTokens: 100_000,
        source: "test"
    )

    let cost = try #require(Pricing.cost(for: record, prices: [price]))
    #expect(abs(cost - 2.69) < 0.000_001)
}

@Test("Шаблон со звездочкой сопоставляет префикс модели")
func matchesPricePrefix() {
    let price = ModelPrice(
        modelPattern: "gpt-5.6-*",
        inputPerMillion: 1,
        cachedInputPerMillion: 0.1,
        outputPerMillion: 6
    )

    #expect(price.matches(model: "gpt-5.6-terra"))
    #expect(!price.matches(model: "gpt-5.5"))
}

@Test("Точная цена приоритетнее wildcard независимо от порядка строк")
func exactPriceWinsOverWildcard() throws {
    let fallback = ModelPrice(
        modelPattern: "*",
        inputPerMillion: 1,
        cachedInputPerMillion: 0,
        outputPerMillion: 1
    )
    let prefix = ModelPrice(
        modelPattern: "gpt-5.6-*",
        inputPerMillion: 2,
        cachedInputPerMillion: 0,
        outputPerMillion: 2
    )
    let exact = ModelPrice(
        modelPattern: "GPT-5.6-TERRA",
        inputPerMillion: 3,
        cachedInputPerMillion: 0,
        outputPerMillion: 3
    )

    let resolved = try #require(
        Pricing.price(
            for: "gpt-5.6-terra",
            in: [fallback, prefix, exact]
        )
    )
    #expect(resolved.id == exact.id)
}

@Test("Самый длинный prefix wildcard приоритетнее короткого")
func longestPricePrefixWins() throws {
    let short = ModelPrice(
        modelPattern: "gpt-*",
        inputPerMillion: 1,
        cachedInputPerMillion: 0,
        outputPerMillion: 1
    )
    let long = ModelPrice(
        modelPattern: "gpt-5.6-*",
        inputPerMillion: 2,
        cachedInputPerMillion: 0,
        outputPerMillion: 2
    )

    let resolved = try #require(
        Pricing.price(for: "gpt-5.6-terra", in: [short, long])
    )
    #expect(resolved.id == long.id)
}

@Test("Дубликаты одинаковой специфичности разрешаются первой строкой")
func firstDuplicatePriceWins() throws {
    let first = ModelPrice(
        modelPattern: " gpt-5.6-terra ",
        inputPerMillion: 1,
        cachedInputPerMillion: 0,
        outputPerMillion: 1
    )
    let duplicate = ModelPrice(
        modelPattern: "GPT-5.6-TERRA",
        inputPerMillion: 99,
        cachedInputPerMillion: 0,
        outputPerMillion: 99
    )

    let resolved = try #require(
        Pricing.price(for: "gpt-5.6-terra", in: [first, duplicate])
    )
    #expect(resolved.id == first.id)
}

@Test("Exact pricing сохраняет Unicode canonical equivalence")
func exactPriceUsesCanonicalUnicodeEquivalence() throws {
    let composed = ModelPrice(
        modelPattern: "modèle-café",
        inputPerMillion: 7,
        cachedInputPerMillion: 0,
        outputPerMillion: 7
    )
    let decomposedCandidate = "mode\u{300}le-cafe\u{301}"

    let resolved = try #require(
        Pricing.price(for: decomposedCandidate, in: [composed])
    )
    #expect(resolved.id == composed.id)
}

@Test("Prefix pricing сохраняет Unicode canonical equivalence")
func prefixPriceUsesCanonicalUnicodeEquivalence() throws {
    let decomposedPattern = ModelPrice(
        modelPattern: "cafe\u{301}-*",
        inputPerMillion: 8,
        cachedInputPerMillion: 0,
        outputPerMillion: 8
    )

    let resolved = try #require(
        Pricing.price(for: "CAFÉ-TERRA", in: [decomposedPattern])
    )
    #expect(resolved.id == decomposedPattern.id)
}

@Test("Pricing не обрезает пробелы в имени модели")
func priceCandidateWhitespaceRemainsSignificant() {
    let exact = ModelPrice(
        modelPattern: "gpt-test",
        inputPerMillion: 1,
        cachedInputPerMillion: 0,
        outputPerMillion: 1
    )

    #expect(Pricing.price(for: " gpt-test ", in: [exact]) == nil)
}

@Test("ModelPrice ограничивает pattern сразу при присваивании")
func modelPricePatternIsBoundedOnMutation() {
    var price = ModelPrice(
        modelPattern: "initial",
        inputPerMillion: 1,
        cachedInputPerMillion: 0,
        outputPerMillion: 1
    )

    price.modelPattern = String(repeating: "é", count: 1_000)

    #expect(price.modelPattern.utf8.count <= UsageLimits.maximumModelBytes)
    #expect(!price.modelPattern.isEmpty)
}
