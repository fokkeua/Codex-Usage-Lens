import AppKit
import Darwin
import Foundation

enum CodexResetCreditOutcome: String, Sendable {
    case reset
    case nothingToReset
    case noCredit
    case alreadyRedeemed
}

enum CodexResetCreditClient {
    static func consume(
        creditID: String? = nil,
        completion: @escaping @MainActor @Sendable (
            Result<CodexResetCreditOutcome, Error>
        ) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<CodexResetCreditOutcome, Error>
            do {
                result = .success(
                    try consumeSynchronously(creditID: creditID)
                )
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func consumeSynchronously(
        creditID: String?
    ) throws -> CodexResetCreditOutcome {
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

        let state = ResetCreditAppServerState(
            input: stdin.fileHandleForWriting,
            creditID: creditID
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
            throw CodexAppServerError.launchFailed(
                error.localizedDescription
            )
        }
        state.send(CodexAppServerClient.initializeRequest())
        let wait = state.finished.wait(
            timeout: .now() + CodexAppServerClient.responseTimeout
        )

        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        ProcessTerminator.stop(process)
        process.terminationHandler = nil

        guard wait == .success else {
            throw CodexAppServerError.timeout
        }
        if let error = state.error {
            throw error
        }
        guard let outcome = state.outcome else {
            throw CodexAppServerError.invalidResponse
        }
        return outcome
    }
}

private final class ResetCreditAppServerState: @unchecked Sendable {
    static let maximumOutputBytes = 512 * 1024

    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let input: FileHandle
    private let creditID: String?
    private var buffer = Data()
    private var outputBytes = 0
    private var initialized = false
    private var didFinish = false

    private(set) var outcome: CodexResetCreditOutcome?
    private(set) var error: Error?

    init(input: FileHandle, creditID: String?) {
        self.input = input
        self.creditID = creditID
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
        defer { lock.unlock() }
        guard !didFinish else { return }
        guard
            data.count <= Self.maximumOutputBytes - outputBytes
        else {
            finishLocked(error: CodexAppServerError.outputLimitExceeded)
            return
        }
        outputBytes += data.count
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            consumeLineLocked(Data(line))
            if didFinish {
                return
            }
        }
        guard buffer.count <= Self.maximumOutputBytes else {
            finishLocked(error: CodexAppServerError.outputLimitExceeded)
            return
        }
    }

    func processDidTerminate() {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return }
        finishLocked(error: CodexAppServerError.invalidResponse)
    }

    private func consumeLineLocked(_ data: Data) {
        guard
            let message = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let id = StrictIntegerDecoding.value(
                from: message["id"] as Any,
                in: Int.min...Int.max,
                allowNumericString: false
            )
        else {
            return
        }

        if id == 0, !initialized {
            guard message["result"] != nil else {
                finishLocked(error: protocolError(from: message))
                return
            }
            initialized = true
            send(["method": "initialized", "params": [:]])
            var params: [String: Any] = [
                "idempotencyKey": UUID().uuidString,
            ]
            if let creditID {
                params["creditId"] = creditID
            }
            send([
                "method": "account/rateLimitResetCredit/consume",
                "id": 1,
                "params": params,
            ])
            return
        }

        guard id == 1 else { return }
        guard
            let result = message["result"] as? [String: Any],
            let rawOutcome = result["outcome"] as? String,
            let outcome = CodexResetCreditOutcome(rawValue: rawOutcome)
        else {
            finishLocked(error: protocolError(from: message))
            return
        }
        self.outcome = outcome
        finishLocked(error: nil)
    }

    private func finishLocked(error: Error?) {
        guard !didFinish else { return }
        didFinish = true
        self.error = error
        finished.signal()
    }

    private func protocolError(
        from message: [String: Any]
    ) -> CodexAppServerError {
        if
            let payload = message["error"] as? [String: Any],
            let text = payload["message"] as? String
        {
            return .protocolError(text)
        }
        return .invalidResponse
    }
}

@MainActor
final class CodexLoginCoordinator: ObservableObject {
    static let shared = CodexLoginCoordinator()

    @Published private(set) var isRunning = false
    @Published private(set) var statusText: String?

    private var process: Process?
    private var stdin: Pipe?
    private var stdout: Pipe?
    private var state: LoginAppServerState?
    private var timeoutWorkItem: DispatchWorkItem?
    private var completion:
        (@MainActor @Sendable (Result<Void, Error>) -> Void)?

    func start(
        completion: @escaping @MainActor @Sendable (
            Result<Void, Error>
        ) -> Void
    ) {
        guard !isRunning else {
            completion(.failure(CodexAccountActionError.alreadyRunning))
            return
        }
        guard let executable = CodexCommandLocator.locate() else {
            completion(.failure(CodexAppServerError.codexNotFound))
            return
        }

        isRunning = true
        statusText = "Открывается безопасный вход Codex…"
        self.completion = completion

        let process = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice

        let state = LoginAppServerState(
            input: stdin.fileHandleForWriting,
            authURLHandler: { [weak self] url in
                Task { @MainActor in
                    guard let self else { return }
                    self.statusText = "Завершите вход в браузере…"
                    guard NSWorkspace.shared.open(url) else {
                        self.finish(
                            .failure(
                                CodexAccountActionError.couldNotOpenBrowser
                            )
                        )
                        return
                    }
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    self?.finish(result)
                }
            }
        )
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            state.consume(data)
        }
        process.terminationHandler = { _ in
            state.processDidTerminate()
        }

        self.process = process
        self.stdin = stdin
        self.stdout = stdout
        self.state = state

        do {
            try process.run()
        } catch {
            finish(
                .failure(
                    CodexAppServerError.launchFailed(
                        error.localizedDescription
                    )
                )
            )
            return
        }
        state.send(CodexAppServerClient.initializeRequest())

        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.finish(.failure(CodexAccountActionError.loginTimedOut))
            }
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 5 * 60,
            execute: timeout
        )
    }

    private func finish(_ result: Result<Void, Error>) {
        guard isRunning else { return }
        isRunning = false
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        stdout?.fileHandleForReading.readabilityHandler = nil
        try? stdin?.fileHandleForWriting.close()
        if let process {
            ProcessTerminator.stop(process)
            process.terminationHandler = nil
        }
        process = nil
        stdin = nil
        stdout = nil
        state = nil

        statusText = switch result {
        case .success:
            "Аккаунт Codex подключён"
        case .failure(let error):
            error.localizedDescription
        }
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
}

private final class LoginAppServerState: @unchecked Sendable {
    static let maximumOutputBytes = 512 * 1024

    private let lock = NSLock()
    private let input: FileHandle
    private let authURLHandler: @Sendable (URL) -> Void
    private let completion:
        @Sendable (Result<Void, Error>) -> Void
    private var buffer = Data()
    private var outputBytes = 0
    private var initialized = false
    private var loginID: String?
    private var didFinish = false

    init(
        input: FileHandle,
        authURLHandler: @escaping @Sendable (URL) -> Void,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.input = input
        self.authURLHandler = authURLHandler
        self.completion = completion
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
        defer { lock.unlock() }
        guard !didFinish else { return }
        guard
            data.count <= Self.maximumOutputBytes - outputBytes
        else {
            finishLocked(.failure(CodexAppServerError.outputLimitExceeded))
            return
        }
        outputBytes += data.count
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            consumeLineLocked(Data(line))
            if didFinish {
                return
            }
        }
        guard buffer.count <= Self.maximumOutputBytes else {
            finishLocked(.failure(CodexAppServerError.outputLimitExceeded))
            return
        }
    }

    func processDidTerminate() {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return }
        finishLocked(.failure(CodexAppServerError.invalidResponse))
    }

    private func consumeLineLocked(_ data: Data) {
        guard
            let message = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return
        }

        if
            let idValue = message["id"],
            let id = StrictIntegerDecoding.value(
                from: idValue,
                in: Int.min...Int.max,
                allowNumericString: false
            )
        {
            consumeResponseLocked(message, id: id)
            return
        }

        guard
            message["method"] as? String == "account/login/completed",
            let params = message["params"] as? [String: Any],
            let success = params["success"] as? Bool,
            (params["loginId"] is NSNull
                || params["loginId"] as? String == loginID)
        else {
            return
        }
        if success {
            finishLocked(.success(()))
        } else {
            let message = params["error"] as? String
                ?? "Вход Codex не завершён."
            finishLocked(
                .failure(CodexAppServerError.protocolError(message))
            )
        }
    }

    private func consumeResponseLocked(
        _ message: [String: Any],
        id: Int
    ) {
        if id == 0, !initialized {
            guard message["result"] != nil else {
                finishLocked(.failure(protocolError(from: message)))
                return
            }
            initialized = true
            send(["method": "initialized", "params": [:]])
            send([
                "method": "account/login/start",
                "id": 1,
                "params": [
                    "type": "chatgpt",
                    "appBrand": "codex",
                    "codexStreamlinedLogin": true,
                    "useHostedLoginSuccessPage": true,
                ],
            ])
            return
        }

        guard id == 1 else { return }
        guard
            let result = message["result"] as? [String: Any],
            result["type"] as? String == "chatgpt",
            let loginID = result["loginId"] as? String,
            loginID.utf8.count <= 4 * 1024,
            let rawURL = result["authUrl"] as? String,
            rawURL.utf8.count <= 16 * 1024,
            let url = URL(string: rawURL),
            url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased(),
            isAllowedAuthenticationHost(host)
        else {
            finishLocked(.failure(protocolError(from: message)))
            return
        }
        self.loginID = loginID
        authURLHandler(url)
    }

    private func isAllowedAuthenticationHost(_ host: String) -> Bool {
        host == "openai.com"
            || host.hasSuffix(".openai.com")
            || host == "chatgpt.com"
            || host.hasSuffix(".chatgpt.com")
    }

    private func finishLocked(_ result: Result<Void, Error>) {
        guard !didFinish else { return }
        didFinish = true
        completion(result)
    }

    private func protocolError(
        from message: [String: Any]
    ) -> CodexAppServerError {
        if
            let payload = message["error"] as? [String: Any],
            let text = payload["message"] as? String
        {
            return .protocolError(text)
        }
        return .invalidResponse
    }
}

enum CodexAccountActionError: LocalizedError {
    case alreadyRunning
    case couldNotOpenBrowser
    case loginTimedOut

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Вход Codex уже выполняется."
        case .couldNotOpenBrowser:
            "Не удалось открыть страницу входа в браузере."
        case .loginTimedOut:
            "Время ожидания входа Codex истекло."
        }
    }
}
