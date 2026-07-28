import Foundation

struct OpenAIServiceStatus: Equatable, Sendable {
    let description: String
    let indicator: String
    let updatedAt: Date
}

enum OpenAIStatusClient {
    static let statusURL = URL(
        string: "https://status.openai.com/api/v2/status.json"
    )!
    static let pageURL = URL(string: "https://status.openai.com/")!
    private static let maximumResponseBytes = 128 * 1024

    static func fetch(
        completion: @escaping @MainActor @Sendable (
            Result<OpenAIServiceStatus, Error>
        ) -> Void
    ) {
        var request = URLRequest(url: statusURL)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<OpenAIServiceStatus, Error>
            do {
                if let error {
                    throw error
                }
                guard
                    let http = response as? HTTPURLResponse,
                    (200...299).contains(http.statusCode),
                    let data,
                    data.count <= maximumResponseBytes
                else {
                    throw OpenAIStatusError.invalidResponse
                }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let wire = try decoder.decode(
                    WireStatusResponse.self,
                    from: data
                )
                guard
                    wire.status.description.utf8.count <= 512,
                    wire.status.indicator.utf8.count <= 64,
                    let updatedAt = ISO8601DateFormatter()
                        .date(from: wire.page.updatedAt),
                    UsageLimits.isPlausibleTimestamp(updatedAt)
                else {
                    throw OpenAIStatusError.invalidResponse
                }
                result = .success(
                    OpenAIServiceStatus(
                        description: wire.status.description,
                        indicator: wire.status.indicator,
                        updatedAt: updatedAt
                    )
                )
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in
                completion(result)
            }
        }
        .resume()
    }
}

private struct WireStatusResponse: Decodable {
    struct Page: Decodable {
        let updatedAt: String
    }

    struct Status: Decodable {
        let description: String
        let indicator: String
    }

    let page: Page
    let status: Status
}

enum OpenAIStatusError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "OpenAI Status вернул неожиданный ответ."
    }
}
