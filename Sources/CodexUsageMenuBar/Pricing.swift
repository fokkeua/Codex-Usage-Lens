import Foundation

enum Pricing {
    static let officialPricingURL = URL(string: "https://developers.openai.com/api/docs/models/compare")!

    static let defaultPrices: [ModelPrice] = [
        ModelPrice(
            modelPattern: "gpt-5.6-sol*",
            inputPerMillion: 5.00,
            cachedInputPerMillion: 0.50,
            cacheWritePerMillion: 6.25,
            outputPerMillion: 30.00,
            sourceURL: "https://developers.openai.com/api/docs/models/gpt-5.6-sol",
            lastUpdated: Date(timeIntervalSince1970: 1_774_483_200),
            priorityMultiplier: 2
        ),
        ModelPrice(
            modelPattern: "gpt-5.6",
            inputPerMillion: 5.00,
            cachedInputPerMillion: 0.50,
            cacheWritePerMillion: 6.25,
            outputPerMillion: 30.00,
            sourceURL: "https://developers.openai.com/api/docs/models/gpt-5.6-sol",
            lastUpdated: Date(timeIntervalSince1970: 1_774_483_200),
            priorityMultiplier: 2
        ),
        ModelPrice(
            modelPattern: "gpt-5.6-terra*",
            inputPerMillion: 2.50,
            cachedInputPerMillion: 0.25,
            cacheWritePerMillion: 3.125,
            outputPerMillion: 15.00,
            sourceURL: "https://developers.openai.com/api/docs/models/gpt-5.6-terra",
            lastUpdated: Date(timeIntervalSince1970: 1_774_483_200),
            priorityMultiplier: 2
        ),
        ModelPrice(
            modelPattern: "gpt-5.6-luna*",
            inputPerMillion: 1.00,
            cachedInputPerMillion: 0.10,
            cacheWritePerMillion: 1.25,
            outputPerMillion: 6.00,
            sourceURL: "https://developers.openai.com/api/docs/models/gpt-5.6-luna",
            lastUpdated: Date(timeIntervalSince1970: 1_774_483_200),
            priorityMultiplier: 2
        )
    ]

    static func price(for model: String, in prices: [ModelPrice]) -> ModelPrice? {
        CompiledPricingCatalog(prices: prices).price(for: model)
    }

    static func compiledCatalog(
        from prices: [ModelPrice]
    ) -> CompiledPricingCatalog {
        CompiledPricingCatalog(prices: prices)
    }

    static func cost(for record: UsageRecord, prices: [ModelPrice]) -> Double? {
        guard let price = price(for: record.model, in: prices) else {
            return nil
        }
        return cost(for: record, price: price)
    }

    static func cost(for record: UsageRecord, price: ModelPrice) -> Double {
        let million = 1_000_000.0
        // Published GPT-5.6 pricing applies higher rates to a whole request
        // when its input exceeds 272K tokens.
        let longContext = record.model.lowercased().hasPrefix("gpt-5.6")
            && record.inputTokens > 272_000
        let inputMultiplier = longContext ? 2.0 : 1.0
        let outputMultiplier = longContext ? 1.5 : 1.0
        let tier = record.serviceTier?.lowercased() ?? "default"
        let serviceMultiplier = ["fast", "priority"].contains(tier)
            ? max(1, price.priorityMultiplier ?? 2)
            : 1

        let uncached = Double(record.uncachedInputTokens) * price.inputPerMillion / million
        let cached = Double(record.cachedInputTokens) * price.cachedInputPerMillion / million
        let cacheWrite = Double(record.cacheWriteTokens) * price.cacheWritePerMillion / million
        // reasoningOutputTokens is a subset of outputTokens and is not added again.
        let output = Double(record.outputTokens) * price.outputPerMillion / million
        return serviceMultiplier * (inputMultiplier * (uncached + cached + cacheWrite)
            + outputMultiplier * output)
    }
}

/// An immutable resolver compiled once per catalog generation.
///
/// Exact rows use a dictionary and prefix rows use a UTF-8 trie. Insertion
/// deliberately keeps the first row at every terminal so duplicate ties retain
/// the same semantics as the table-order resolver.
struct CompiledPricingCatalog: Sendable {
    private struct PrefixNode: Sendable {
        var children: [UInt8: Int] = [:]
        var price: ModelPrice?
    }

    private var exact: [String: ModelPrice] = [:]
    private var prefixNodes: [PrefixNode] = [PrefixNode()]
    private var wildcard: ModelPrice?

    init(prices: [ModelPrice]) {
        exact.reserveCapacity(prices.count)
        prefixNodes.reserveCapacity(prices.count + 1)

        for price in prices {
            let pattern = price.modelPattern
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .precomposedStringWithCanonicalMapping
            guard !pattern.isEmpty else { continue }

            if pattern == "*" {
                if wildcard == nil {
                    wildcard = price
                }
                continue
            }

            guard pattern.hasSuffix("*") else {
                if exact[pattern] == nil {
                    exact[pattern] = price
                }
                continue
            }

            let prefix = String(pattern.dropLast())
            guard !prefix.isEmpty else {
                if wildcard == nil {
                    wildcard = price
                }
                continue
            }
            var nodeIndex = 0
            for byte in prefix.utf8 {
                if let existing = prefixNodes[nodeIndex].children[byte] {
                    nodeIndex = existing
                } else {
                    let newIndex = prefixNodes.count
                    prefixNodes.append(PrefixNode())
                    prefixNodes[nodeIndex].children[byte] = newIndex
                    nodeIndex = newIndex
                }
            }
            if prefixNodes[nodeIndex].price == nil {
                prefixNodes[nodeIndex].price = price
            }
        }
    }

    func price(for model: String) -> ModelPrice? {
        let candidate = model
            .lowercased()
            .precomposedStringWithCanonicalMapping
        if let exactPrice = exact[candidate] {
            return exactPrice
        }

        var nodeIndex = 0
        var longestPrefix: ModelPrice?
        for byte in candidate.utf8 {
            guard let next = prefixNodes[nodeIndex].children[byte] else {
                break
            }
            nodeIndex = next
            if let price = prefixNodes[nodeIndex].price {
                longestPrefix = price
            }
        }
        return longestPrefix ?? wildcard
    }
}

enum OfficialPricingCatalog {
    static let maximumResponseSize = 2 * 1024 * 1024
    static let maximumPricePerMillion = 10_000.0
    static let officialHost = "developers.openai.com"

    private static let pages: [(pattern: String, url: URL)] = [
        ("gpt-5.6-sol*", URL(string: "https://developers.openai.com/api/docs/models/gpt-5.6-sol")!),
        ("gpt-5.6", URL(string: "https://developers.openai.com/api/docs/models/gpt-5.6-sol")!),
        ("gpt-5.6-terra*", URL(string: "https://developers.openai.com/api/docs/models/gpt-5.6-terra")!),
        ("gpt-5.6-luna*", URL(string: "https://developers.openai.com/api/docs/models/gpt-5.6-luna")!),
    ]

    static func fetch(
        completion: @escaping @MainActor @Sendable (
            Result<[ModelPrice], Error>
        ) -> Void
    ) {
        let group = DispatchGroup()
        let accumulator = PricingFetchAccumulator()
        let pagesByURL = Dictionary(grouping: pages, by: \.url)

        for (url, matchingPages) in pagesByURL {
            group.enter()
            BoundedPricingPageLoader.load(
                url: url,
                maximumBytes: maximumResponseSize
            ) { result in
                defer { group.leave() }
                do {
                    let data = try result.get()
                    guard let html = String(data: data, encoding: .utf8) else {
                        throw PricingCatalogError.unreadable
                    }
                    let values = try parsePricing(html)
                    let cacheWrite = values.input * 1.25
                    guard isValidPrice(cacheWrite) else {
                        throw PricingCatalogError.invalidPrice
                    }
                    let fetchedAt = Date()
                    accumulator.append(
                        matchingPages.map { page in
                            ModelPrice(
                                modelPattern: page.pattern,
                                inputPerMillion: values.input,
                                cachedInputPerMillion: values.cached,
                                cacheWritePerMillion: cacheWrite,
                                outputPerMillion: values.output,
                                sourceURL: url.absoluteString,
                                lastUpdated: fetchedAt,
                                priorityMultiplier: 2
                            )
                        }
                    )
                } catch {
                    accumulator.record(error)
                }
            }
        }

        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let (fetched, firstError) = accumulator.snapshot()
                if fetched.count == pages.count {
                    let ordering = pages.map(\.pattern)
                    completion(.success(fetched.sorted {
                        (ordering.firstIndex(of: $0.modelPattern) ?? 99)
                            < (ordering.firstIndex(of: $1.modelPattern) ?? 99)
                    }))
                } else {
                    completion(.failure(firstError ?? PricingCatalogError.unreadable))
                }
            }
        }
    }

    static func parsePricing(_ html: String) throws -> (input: Double, cached: Double, output: Double) {
        func value(after label: String) -> Double? {
            let escaped = NSRegularExpression.escapedPattern(for: label)
            let pattern =
                #"<div>\#(escaped)</div><div[^>]*>\$([0-9]{1,6}(?:\.[0-9]{1,6})?)</div>"#
            guard
                let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                let match = regex.firstMatch(
                    in: html,
                    range: NSRange(html.startIndex..., in: html)
                ),
                let range = Range(match.range(at: 1), in: html)
            else {
                return nil
            }
            guard let value = Double(html[range]), isValidPrice(value) else {
                return nil
            }
            return value
        }

        guard
            let input = value(after: "Input"),
            let cached = value(after: "Cached input"),
            let output = value(after: "Output")
        else {
            throw PricingCatalogError.unexpectedPage
        }
        return (input, cached, output)
    }

    static func isValidPrice(_ value: Double) -> Bool {
        value.isFinite
            && value >= 0
            && value <= maximumPricePerMillion
    }

    static func isOfficialOrigin(_ url: URL?) -> Bool {
        guard
            let url,
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            components.scheme?.lowercased() == "https",
            components.host?.lowercased() == officialHost,
            components.port == nil || components.port == 443,
            components.user == nil,
            components.password == nil
        else {
            return false
        }
        return true
    }

    static func redirectRequestIfAllowed(
        _ request: URLRequest
    ) -> URLRequest? {
        isOfficialOrigin(request.url) ? request : nil
    }

    static func validate(
        response: HTTPURLResponse,
        expectedURL: URL
    ) throws {
        guard (200...299).contains(response.statusCode) else {
            throw PricingCatalogError.invalidStatus(response.statusCode)
        }
        guard
            isOfficialOrigin(expectedURL),
            isOfficialOrigin(response.url)
        else {
            throw PricingCatalogError.unexpectedOrigin
        }
        guard response.mimeType?.lowercased() == "text/html" else {
            throw PricingCatalogError.unexpectedContentType
        }
        let expectedLength = response.expectedContentLength
        guard
            expectedLength < 0
                || expectedLength <= Int64(maximumResponseSize)
        else {
            throw PricingCatalogError.responseTooLarge
        }
    }
}

struct BoundedPricingBuffer {
    let maximumBytes: Int
    private(set) var data = Data()

    mutating func append(_ chunk: Data) throws {
        guard
            maximumBytes >= 0,
            data.count <= maximumBytes,
            chunk.count <= maximumBytes - data.count
        else {
            throw PricingCatalogError.responseTooLarge
        }
        data.append(chunk)
    }
}

final class BoundedPricingPageLoader:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    private let url: URL
    private let completion: (Result<Data, Error>) -> Void
    private var buffer: BoundedPricingBuffer
    private var responseValidated = false
    private var didComplete = false
    private var session: URLSession?

    private init(
        url: URL,
        maximumBytes: Int,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        self.url = url
        self.completion = completion
        buffer = BoundedPricingBuffer(maximumBytes: maximumBytes)
    }

    static func load(
        url: URL,
        maximumBytes: Int,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let loader = BoundedPricingPageLoader(
            url: url,
            maximumBytes: maximumBytes,
            completion: completion
        )
        loader.start()
    }

    private func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
        self.session = session
        session.dataTask(with: url).resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard
            let allowedRequest =
                OfficialPricingCatalog.redirectRequestIfAllowed(request)
        else {
            completionHandler(nil)
            task.cancel()
            finish(.failure(PricingCatalogError.unexpectedOrigin))
            return
        }
        completionHandler(allowedRequest)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            guard let response = response as? HTTPURLResponse else {
                throw PricingCatalogError.unreadable
            }
            try OfficialPricingCatalog.validate(
                response: response,
                expectedURL: url
            )
            responseValidated = true
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard !didComplete else { return }
        do {
            try buffer.append(data)
        } catch {
            dataTask.cancel()
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !didComplete else { return }
        if let error {
            finish(.failure(error))
        } else if responseValidated {
            finish(.success(buffer.data))
        } else {
            finish(.failure(PricingCatalogError.unreadable))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !didComplete else { return }
        didComplete = true
        completion(result)
        session?.finishTasksAndInvalidate()
        session = nil
    }
}

private final class PricingFetchAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var prices: [ModelPrice] = []
    private var firstError: Error?

    func append(_ newPrices: [ModelPrice]) {
        lock.lock()
        prices.append(contentsOf: newPrices)
        lock.unlock()
    }

    func record(_ error: Error) {
        lock.lock()
        if firstError == nil {
            firstError = error
        }
        lock.unlock()
    }

    func snapshot() -> ([ModelPrice], Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (prices, firstError)
    }
}

enum PricingCatalogError: LocalizedError, Equatable {
    case unreadable
    case unexpectedPage
    case invalidStatus(Int)
    case unexpectedOrigin
    case unexpectedContentType
    case responseTooLarge
    case invalidPrice

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "Не удалось загрузить официальные страницы цен."
        case .unexpectedPage:
            "Формат официальной страницы цен изменился; сохранена предыдущая таблица."
        case .invalidStatus(let status):
            "Официальная страница цен вернула HTTP \(status); сохранена предыдущая таблица."
        case .unexpectedOrigin:
            "Страница цен перенаправлена за пределы официального HTTPS-хоста."
        case .unexpectedContentType:
            "Официальная страница цен вернула не HTML; сохранена предыдущая таблица."
        case .responseTooLarge:
            "Официальная страница цен превышает лимит 2 МБ."
        case .invalidPrice:
            "Официальная страница содержит недопустимое значение цены."
        }
    }
}
