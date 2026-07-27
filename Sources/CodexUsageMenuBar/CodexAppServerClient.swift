import Darwin
import Foundation

enum CodexCommandLocator {
    static let candidates = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
    ]

    static func locate() -> URL? {
        if let override = ProcessInfo.processInfo.environment["CODEX_USAGE_CODEX_PATH"],
           FileManager.default.isExecutableFile(atPath: override)
        {
            return URL(fileURLWithPath: override)
        }
        return candidates
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }
}

enum CodexAppServerClient {
    static let responseTimeout: TimeInterval = 20
    static let optionalModelsGracePeriod: TimeInterval = 0.5
    static let maximumDailyUsageBuckets = 10_000
    static let maximumModelCount = 100
    static let maximumModelStringBytes = UsageLimits.maximumModelBytes
    static let maximumAccountCounter = UsageLimits.maximumTokenCount
    static let maximumDateStringBytes = 64

    static func initializeRequest() -> [String: Any] {
        [
            "method": "initialize",
            "id": 0,
            "params": [
                "clientInfo": [
                    "name": "codex_usage_lens",
                    "title": "Codex Usage Lens",
                    "version": "1.2.0",
                ],
            ],
        ]
    }

    static func fetch(
        completion: @escaping @MainActor @Sendable (
            Result<CodexAccountResult, Error>
        ) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try fetchSynchronously()
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    static func decodeAccountUsage(
        from object: Any,
        executablePath: String? = nil,
        fetchedAt: Date = Date()
    ) throws -> AccountUsageSnapshot {
        do {
            guard JSONSerialization.isValidJSONObject(object) else {
                throw CodexAppServerError.invalidResponse
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            let wire = try JSONDecoder().decode(
                WireAccountUsage.self,
                from: data
            )
            try validate(summary: wire.summary)
            try validate(dailyUsageBuckets: wire.dailyUsageBuckets)
            return AccountUsageSnapshot(
                summary: wire.summary,
                dailyUsageBuckets: wire.dailyUsageBuckets,
                fetchedAt: fetchedAt,
                codexExecutable: executablePath
            )
        } catch let error as CodexAppServerError {
            throw error
        } catch {
            throw CodexAppServerError.invalidResponse
        }
    }

    static func decodeModels(from object: Any) throws -> [CodexModelInfo] {
        do {
            guard
                let result = object as? [String: Any],
                let rawModels = result["data"] as? [Any],
                rawModels.count <= maximumModelCount,
                rawModels.allSatisfy({ $0 is [String: Any] }),
                JSONSerialization.isValidJSONObject(rawModels)
            else {
                throw CodexAppServerError.invalidResponse
            }
            let data = try JSONSerialization.data(withJSONObject: rawModels)
            let models = try JSONDecoder().decode(
                [CodexModelInfo].self,
                from: data
            )
            guard
                models.count <= maximumModelCount,
                models.allSatisfy({ model in
                    [model.id, model.model, model.displayName]
                        .compactMap { $0 }
                        .allSatisfy {
                            $0.utf8.count <= maximumModelStringBytes
                        }
                })
            else {
                throw CodexAppServerError.invalidResponse
            }
            return models
        } catch let error as CodexAppServerError {
            throw error
        } catch {
            throw CodexAppServerError.invalidResponse
        }
    }

    private static func validate(summary: AccountUsageSummary) throws {
        let counters = [
            summary.lifetimeTokens,
            summary.peakDailyTokens,
            summary.longestRunningTurnSec,
            summary.currentStreakDays,
            summary.longestStreakDays,
        ]
        guard counters.compactMap({ $0 }).allSatisfy(isValidCounter) else {
            throw CodexAppServerError.invalidResponse
        }
    }

    private static func validate(
        dailyUsageBuckets: [AccountUsageDailyBucket]?
    ) throws {
        guard let dailyUsageBuckets else { return }
        guard dailyUsageBuckets.count <= maximumDailyUsageBuckets else {
            throw CodexAppServerError.invalidResponse
        }
        var seenDates = Set<String>()
        for bucket in dailyUsageBuckets {
            guard
                bucket.startDate.utf8.count <= maximumDateStringBytes,
                isValidBucketDate(bucket.startDate),
                isValidCounter(bucket.tokens),
                seenDates.insert(bucket.startDate).inserted
            else {
                throw CodexAppServerError.invalidResponse
            }
        }
    }

    private static func isValidCounter(_ value: Int) -> Bool {
        (0...maximumAccountCounter).contains(value)
    }

    private static func isValidBucketDate(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard
            bytes.count == 10,
            bytes[4] == 0x2D,
            bytes[7] == 0x2D,
            bytes.enumerated().allSatisfy({ index, byte in
                index == 4 || index == 7
                    ? byte == 0x2D
                    : (0x30...0x39).contains(byte)
            }),
            let year = Int(String(decoding: bytes[0..<4], as: UTF8.self)),
            let month = Int(String(decoding: bytes[5..<7], as: UTF8.self)),
            let day = Int(String(decoding: bytes[8..<10], as: UTF8.self))
        else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return roundTrip.year == year
            && roundTrip.month == month
            && roundTrip.day == day
            && UsageLimits.isPlausibleTimestamp(date)
    }

    private static func fetchSynchronously() throws -> CodexAccountResult {
        guard let executable = CodexCommandLocator.locate() else {
            throw CodexAppServerError.codexNotFound
        }

        let process = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice

        let state = AppServerState(
            input: stdin.fileHandleForWriting,
            executablePath: executable.path
        )
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            state.consume(data)
        }
        process.terminationHandler = { _ in
            state.processDidTerminate()
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        // account/usage/read and model/list are on the documented stable
        // surface. Omitting capabilities keeps experimental methods disabled.
        state.send(initializeRequest())

        let usageWait = state.usageFinished.wait(
            timeout: .now() + responseTimeout
        )
        if usageWait == .success {
            _ = state.modelsFinished.wait(
                timeout: .now() + optionalModelsGracePeriod
            )
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        ProcessTerminator.stop(process)
        process.terminationHandler = nil

        guard usageWait == .success else {
            throw CodexAppServerError.timeout
        }
        let snapshot = state.snapshot()
        if let error = snapshot.error {
            throw error
        }
        guard let usage = snapshot.usage else {
            throw CodexAppServerError.invalidResponse
        }
        return CodexAccountResult(usage: usage, models: snapshot.models)
    }
}

final class AppServerState: @unchecked Sendable {
    static let maximumLineSize = 512 * 1024
    static let maximumBufferedSize = 512 * 1024
    static let maximumTotalOutputSize = 4 * 1024 * 1024

    let usageFinished = DispatchSemaphore(value: 0)
    let modelsFinished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let input: FileHandle
    private let executablePath: String
    private var buffer = Data()
    private var totalOutputBytes = 0
    private var initialized = false
    private var usageDidFinish = false
    private var modelsDidFinish = false

    private(set) var usage: AccountUsageSnapshot?
    private(set) var models: [CodexModelInfo] = []
    private(set) var error: Error?

    init(input: FileHandle, executablePath: String) {
        self.input = input
        self.executablePath = executablePath
    }

    func send(_ object: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object),
            var line = String(data: data, encoding: .utf8)?.data(using: .utf8)
        else {
            return
        }
        line.append(0x0A)
        try? input.write(contentsOf: line)
    }

    func consume(_ data: Data) {
        lock.lock()
        guard error == nil else {
            lock.unlock()
            return
        }
        guard
            data.count <= Self.maximumTotalOutputSize - totalOutputBytes
        else {
            failLocked(.outputLimitExceeded)
            lock.unlock()
            return
        }
        totalOutputBytes += data.count

        var segmentStart = data.startIndex
        while segmentStart < data.endIndex,
              let newline = data[segmentStart...].firstIndex(of: 0x0A)
        {
            let segment = data[segmentStart..<newline]
            guard
                segment.count <= Self.maximumLineSize - buffer.count
            else {
                failLocked(.outputLimitExceeded)
                lock.unlock()
                return
            }
            buffer.append(segment)
            consumeLineLocked(buffer)
            buffer.removeAll(keepingCapacity: true)
            segmentStart = data.index(after: newline)
        }

        if segmentStart < data.endIndex {
            let remainder = data[segmentStart...]
            guard
                remainder.count <= Self.maximumBufferedSize - buffer.count,
                remainder.count <= Self.maximumLineSize - buffer.count
            else {
                failLocked(.outputLimitExceeded)
                lock.unlock()
                return
            }
            buffer.append(remainder)
        }
        lock.unlock()
    }

    func processDidTerminate() {
        lock.lock()
        if !usageDidFinish {
            if usage == nil, error == nil {
                error = CodexAppServerError.invalidResponse
            }
            usageDidFinish = true
            usageFinished.signal()
        }
        if !modelsDidFinish {
            modelsDidFinish = true
            modelsFinished.signal()
        }
        lock.unlock()
    }

    func snapshot() -> (
        usage: AccountUsageSnapshot?,
        models: [CodexModelInfo],
        error: Error?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (usage, models, error)
    }

    private func consumeLineLocked(_ data: Data) {
        guard
            let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawID = message["id"],
            let id = StrictIntegerDecoding.value(
                from: rawID,
                in: Int.min...Int.max,
                allowNumericString: false
            )
        else {
            return
        }

        if id == 0, !initialized {
            guard message["result"] != nil else {
                failLocked(protocolError(from: message))
                return
            }
            initialized = true
            send(["method": "initialized", "params": [:]])
            send(["method": "account/usage/read", "id": 1])
            send([
                "method": "model/list",
                "id": 2,
                "params": ["includeHidden": false, "limit": 100],
            ])
            return
        }

        if id == 1 {
            guard !usageDidFinish else { return }
            if let result = message["result"] {
                do {
                    usage = try CodexAppServerClient.decodeAccountUsage(
                        from: result,
                        executablePath: executablePath
                    )
                } catch {
                    self.error = error
                }
            } else {
                error = protocolError(from: message)
            }
            usageDidFinish = true
            usageFinished.signal()
        } else if id == 2 {
            guard !modelsDidFinish else { return }
            if let result = message["result"] {
                models = (
                    try? CodexAppServerClient.decodeModels(from: result)
                ) ?? []
            }
            modelsDidFinish = true
            modelsFinished.signal()
        }
    }

    private func failLocked(_ failure: CodexAppServerError) {
        if error == nil {
            error = failure
        }
        if !usageDidFinish {
            usageDidFinish = true
            usageFinished.signal()
        }
        if !modelsDidFinish {
            modelsDidFinish = true
            modelsFinished.signal()
        }
    }

    private func failLocked(_ failure: Error) {
        if let failure = failure as? CodexAppServerError {
            failLocked(failure)
        } else {
            failLocked(.invalidResponse)
        }
    }

    private func protocolError(from message: [String: Any]) -> CodexAppServerError {
        guard let payload = message["error"] as? [String: Any] else {
            return CodexAppServerError.invalidResponse
        }
        return CodexAppServerError.protocolError(
            payload["message"] as? String ?? "неизвестная ошибка app-server"
        )
    }
}

enum ProcessTerminator {
    static let defaultGracePeriod: TimeInterval = 0.5

    static func stop(
        _ process: Process,
        gracePeriod: TimeInterval = defaultGracePeriod
    ) {
        guard process.isRunning else { return }
        process.terminate()

        let deadline = Date().addingTimeInterval(max(0, gracePeriod))
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private struct WireAccountUsage: Decodable {
    let summary: AccountUsageSummary
    let dailyUsageBuckets: [AccountUsageDailyBucket]?
}

enum CodexAppServerError: LocalizedError, Equatable {
    case codexNotFound
    case launchFailed(String)
    case protocolError(String)
    case invalidResponse
    case outputLimitExceeded
    case timeout

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            "Не найден исполняемый файл Codex."
        case .launchFailed(let message):
            "Не удалось запустить Codex app-server: \(message)"
        case .protocolError(let message):
            "Codex app-server: \(message)"
        case .invalidResponse:
            "Codex app-server вернул неожиданный формат."
        case .outputLimitExceeded:
            "Codex app-server превысил допустимый размер ответа."
        case .timeout:
            "Codex app-server не ответил за 20 секунд."
        }
    }
}
