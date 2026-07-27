import Darwin
import Foundation
import Testing
@testable import CodexUsageMenuBar

private let testOTelCapabilityToken = String(repeating: "A", count: 43)

@Test("Storage bootstrap не следует промежуточному symbolic link")
@MainActor
func storageBootstrapRejectsIntermediateSymbolicLink() throws {
    let root = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(
        at: outside,
        withIntermediateDirectories: false
    )
    let linkedParent = root.appendingPathComponent("linked-parent")
    try FileManager.default.createSymbolicLink(
        at: linkedParent,
        withDestinationURL: outside
    )
    let escapedStorage = linkedParent.appendingPathComponent(
        "storage",
        isDirectory: true
    )
    let outsideStorage = outside.appendingPathComponent(
        "storage",
        isDirectory: true
    )

    #expect(throws: OTelCapabilityError.self) {
        try OTelCapabilityStore.loadOrCreate(in: escapedStorage)
    }
    #expect(!FileManager.default.fileExists(atPath: outsideStorage.path))

    let store = UsageStore(
        storageDirectory: escapedStorage,
        seedDemoIfNeeded: false,
        autoRefreshRealData: false
    )
    #expect(!store.canPersist)
    #expect(!FileManager.default.fileExists(atPath: outsideStorage.path))
}

@Test("OTel config не следует промежуточному symbolic link")
func otelConfigRejectsIntermediateSymbolicLink() throws {
    let root = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(
        at: outside,
        withIntermediateDirectories: false
    )
    let linkedParent = root.appendingPathComponent("linked-parent")
    try FileManager.default.createSymbolicLink(
        at: linkedParent,
        withDestinationURL: outside
    )
    let config = linkedParent
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("config.toml")
    let escapedDirectory = outside.appendingPathComponent(
        ".codex",
        isDirectory: true
    )

    #expect(throws: OTelConfigError.self) {
        try OTelConfigManager.configurationStatus(at: config)
    }
    #expect(throws: OTelConfigError.self) {
        try OTelConfigManager.install(
            capabilityToken: testOTelCapabilityToken,
            configURL: config
        )
    }
    #expect(!FileManager.default.fileExists(atPath: escapedDirectory.path))
}

@Test("OTel capability отклоняет hard link без изменения внешнего файла")
func otelCapabilityRejectsHardLinkWithoutMutatingTarget() throws {
    let root = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("storage", isDirectory: true)
    try FileManager.default.createDirectory(
        at: storage,
        withIntermediateDirectories: true
    )
    let outside = root.appendingPathComponent("outside-token")
    let outsideData = Data(String(repeating: "a", count: 64).utf8)
    try outsideData.write(to: outside)
    #expect(Darwin.chmod(outside.path, 0o644) == 0)

    let capability = storage.appendingPathComponent("otel-capability")
    #expect(Darwin.link(outside.path, capability.path) == 0)
    var before = stat()
    #expect(outside.path.withCString { lstat($0, &before) } == 0)

    #expect(throws: OTelCapabilityError.self) {
        try OTelCapabilityStore.loadOrCreate(in: storage)
    }

    var after = stat()
    #expect(outside.path.withCString { lstat($0, &after) } == 0)
    #expect(try Data(contentsOf: outside) == outsideData)
    #expect((after.st_mode & mode_t(0o777)) == mode_t(0o644))
    #expect(after.st_dev == before.st_dev)
    #expect(after.st_ino == before.st_ino)
    #expect(after.st_nlink == before.st_nlink)
}

@Test("OTel capability восстанавливает прерванную legacy publication")
func otelCapabilityRecoversInterruptedLegacyPublication() throws {
    let root = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent(
        "storage",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: storage,
        withIntermediateDirectories: true
    )

    let token = String(repeating: "a", count: 64)
    let temporary = storage.appendingPathComponent(
        ".otel-capability.\(UUID().uuidString).temporary"
    )
    let published = storage.appendingPathComponent("otel-capability")
    try Data(token.utf8).write(to: temporary)
    #expect(Darwin.chmod(temporary.path, 0o600) == 0)
    #expect(Darwin.link(temporary.path, published.path) == 0)

    let recovered = try OTelCapabilityStore.loadOrCreate(in: storage)
    #expect(recovered == token)
    #expect(!FileManager.default.fileExists(atPath: temporary.path))

    var metadata = stat()
    #expect(published.path.withCString { lstat($0, &metadata) } == 0)
    #expect(metadata.st_nlink == 1)
    #expect((metadata.st_mode & mode_t(0o777)) == mode_t(0o600))
}

private func otelAttribute(
    _ key: String,
    _ valueKey: String,
    _ value: Any
) -> [String: Any] {
    [
        "key": key,
        "value": [valueKey: value],
    ]
}

private func otlpData(
    logRecords: [[String: Any]],
    resourceAttributes: [[String: Any]] = []
) throws -> Data {
    let envelope: [String: Any] = [
        "resourceLogs": [[
            "resource": ["attributes": resourceAttributes],
            "scopeLogs": [[
                "logRecords": logRecords,
            ]],
        ]],
    ]
    return try JSONSerialization.data(withJSONObject: envelope)
}

private func completedOTelLogRecord(
    eventName: String = "codex.sse_event",
    eventKind: String = "response.completed"
) -> [String: Any] {
    [
        "timeUnixNano": "1785060000000000000",
        "attributes": [
            otelAttribute("event.name", "stringValue", eventName),
            otelAttribute("event.kind", "stringValue", eventKind),
            otelAttribute("slug", "stringValue", "gpt-5.6-sol"),
            otelAttribute("input_token_count", "intValue", "1000"),
            otelAttribute("output_token_count", "intValue", "100"),
            otelAttribute(
                "cached_input_token_count",
                "intValue",
                "200"
            ),
            otelAttribute(
                "cache_write_input_token_count",
                "intValue",
                "50"
            ),
            otelAttribute(
                "reasoning_output_token_count",
                "intValue",
                "20"
            ),
        ],
    ]
}

private func otelRequest(
    body: Data,
    method: String = "POST",
    path: String = "/v1/logs",
    host: String = "127.0.0.1:4319",
    contentType: String = "application/json; charset=utf-8",
    token: String? = testOTelCapabilityToken
) -> HTTPRequest {
    var headers = [
        "host": host,
        "content-type": contentType,
        "content-length": String(body.count),
    ]
    if let token {
        headers[OTelCapabilityToken.headerName] = token
    }
    return HTTPRequest(
        method: method,
        path: path,
        version: "HTTP/1.1",
        headers: headers,
        body: body
    )
}

private func temporaryTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private final class LoopbackHTTPTestServer: @unchecked Sendable {
    private let listenerDescriptor: Int32
    private let response: @Sendable () -> Data
    private let queue = DispatchQueue(
        label: "CodexUsageMenuBarTests.LoopbackHTTPTestServer"
    )
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var isStopped = false
    private var observedRequestCount = 0

    let port: UInt16

    init(response: @escaping @Sendable () -> Data) throws {
        self.response = response

        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw Self.posixError("socket")
        }
        var shouldCloseDescriptor = true
        defer {
            if shouldCloseDescriptor {
                Darwin.close(descriptor)
            }
        }

        var reuseAddress: Int32 = 1
        guard
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuseAddress,
                socklen_t(MemoryLayout.size(ofValue: reuseAddress))
            ) == 0
        else {
            throw Self.posixError("setsockopt")
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindStatus == 0 else {
            throw Self.posixError("bind")
        }
        guard Darwin.listen(descriptor, 4) == 0 else {
            throw Self.posixError("listen")
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(
            MemoryLayout<sockaddr_in>.size
        )
        let nameStatus = withUnsafeMutablePointer(
            to: &boundAddress
        ) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.getsockname(
                    descriptor,
                    $0,
                    &boundAddressLength
                )
            }
        }
        guard nameStatus == 0 else {
            throw Self.posixError("getsockname")
        }

        listenerDescriptor = descriptor
        port = UInt16(bigEndian: boundAddress.sin_port)
        shouldCloseDescriptor = false

        group.enter()
        queue.async { [self] in
            defer {
                Darwin.close(listenerDescriptor)
                group.leave()
            }
            serve()
        }
    }

    deinit {
        stop()
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observedRequestCount
    }

    func stop() {
        lock.lock()
        let shouldStop = !isStopped
        isStopped = true
        lock.unlock()
        guard shouldStop else { return }

        _ = Darwin.shutdown(listenerDescriptor, SHUT_RDWR)
        _ = group.wait(timeout: .now() + 2)
    }

    private func serve() {
        while !stoppedSnapshot() {
            var pollDescriptor = pollfd(
                fd: listenerDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let pollStatus = Darwin.poll(&pollDescriptor, 1, 100)
            if pollStatus < 0, errno == EINTR {
                continue
            }
            guard pollStatus > 0, !stoppedSnapshot() else {
                continue
            }

            let clientDescriptor = Darwin.accept(
                listenerDescriptor,
                nil,
                nil
            )
            if clientDescriptor < 0 {
                if errno == EINTR {
                    continue
                }
                if stoppedSnapshot() {
                    return
                }
                continue
            }
            handle(clientDescriptor)
            Darwin.close(clientDescriptor)
        }
    }

    private func handle(_ clientDescriptor: Int32) {
        var noPipe: Int32 = 1
        _ = setsockopt(
            clientDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noPipe,
            socklen_t(MemoryLayout.size(ofValue: noPipe))
        )

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 2_048)
        while
            received.count < 16_384,
            received.range(of: Data("\r\n\r\n".utf8)) == nil
        {
            var pollDescriptor = pollfd(
                fd: clientDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            guard Darwin.poll(&pollDescriptor, 1, 1_000) > 0 else {
                return
            }
            let byteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    clientDescriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            guard byteCount > 0 else { return }
            received.append(buffer, count: byteCount)
        }

        lock.lock()
        observedRequestCount += 1
        lock.unlock()

        let response = response()
        var sent = 0
        while sent < response.count {
            let byteCount = response.withUnsafeBytes { bytes in
                Darwin.write(
                    clientDescriptor,
                    bytes.baseAddress!.advanced(by: sent),
                    response.count - sent
                )
            }
            if byteCount < 0, errno == EINTR {
                continue
            }
            guard byteCount > 0 else { return }
            sent += byteCount
        }
    }

    private func stoppedSnapshot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    private static func posixError(_ operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(operation) failed: \(String(validatingCString: strerror(code)) ?? "unknown")"
            ]
        )
    }
}

@Test("OTel processor принимает только аутентифицированный response.completed")
func otelProcessorAuthenticatesCompletedUsage() throws {
    let body = try otlpData(logRecords: [completedOTelLogRecord()])
    let outcome = OTelHTTPRequestProcessor.process(
        otelRequest(body: body),
        capabilityToken: testOTelCapabilityToken
    )

    #expect(outcome.status == .ok)
    let record = try #require(outcome.records.first)
    #expect(outcome.records.count == 1)
    #expect(record.model == "gpt-5.6-sol")
    #expect(record.inputTokens == 1_000)
    #expect(record.cachedInputTokens == 200)
    #expect(record.cacheWriteTokens == 50)
    #expect(record.outputTokens == 100)
    #expect(record.reasoningOutputTokens == 20)
}

@Test("OTel HTTP подтверждает batch только после durable acceptance")
func otelProcessorMapsDurableAcceptanceToHTTP() throws {
    let request = otelRequest(
        body: try otlpData(logRecords: [completedOTelLogRecord()])
    )
    let outcome = OTelHTTPRequestProcessor.process(
        request,
        capabilityToken: testOTelCapabilityToken
    )
    #expect(outcome.status == .ok)
    #expect(outcome.records.count == 1)
    #expect(
        OTelLiveReceiver.responseStatus(for: .accepted) == .ok
    )
    #expect(
        OTelLiveReceiver.responseStatus(for: .temporarilyUnavailable)
            == .serviceUnavailable
    )
    #expect(
        OTelLiveReceiver.responseStatus(for: .insufficientStorage)
            == .insufficientStorage
    )
}

@Test("OTel processor маскирует неверный capability и проверяет HTTP metadata")
func otelProcessorRejectsUntrustedHTTPMetadata() throws {
    let body = try otlpData(logRecords: [completedOTelLogRecord()])
    let cases: [(HTTPRequest, HTTPResponseStatus)] = [
        (otelRequest(body: body, token: nil), .notFound),
        (otelRequest(body: body, token: String(repeating: "B", count: 43)), .notFound),
        (otelRequest(body: body, method: "GET"), .methodNotAllowed),
        (otelRequest(body: body, path: "/"), .notFound),
        (otelRequest(body: body, host: "localhost:4319"), .badRequest),
        (otelRequest(body: body, contentType: "text/plain"), .unsupportedMediaType),
    ]

    for (request, expectedStatus) in cases {
        let outcome = OTelHTTPRequestProcessor.process(
            request,
            capabilityToken: testOTelCapabilityToken
        )
        #expect(outcome.status == expectedStatus)
        #expect(outcome.records.isEmpty)
    }
}

@Test("OTel processor различает malformed JSON и oversized parser input")
func otelProcessorMapsParserFailures() throws {
    let malformed = OTelHTTPRequestProcessor.process(
        otelRequest(body: Data("{".utf8)),
        capabilityToken: testOTelCapabilityToken
    )
    #expect(malformed.status == .badRequest)

    let excessiveRecords = Array(
        repeating: [String: Any](),
        count: OTelJSONParser.maximumLogRecords + 1
    )
    let oversized = OTelHTTPRequestProcessor.process(
        otelRequest(body: try otlpData(logRecords: excessiveRecords)),
        capabilityToken: testOTelCapabilityToken
    )
    #expect(oversized.status == .payloadTooLarge)
}

@Test("OTel parser фильтрует другие события и поддерживает websocket layout")
func otelParserFiltersEventsAndSupportsLayouts() throws {
    let ignoredData = try otlpData(logRecords: [
        completedOTelLogRecord(eventKind: "response.in_progress"),
        [
            "timeUnixNano": "1785060000000000000",
            "attributes": [
                otelAttribute("slug", "stringValue", "gpt-5.6-sol"),
                otelAttribute("input_token_count", "intValue", "10"),
                otelAttribute("output_token_count", "intValue", "2"),
            ],
        ],
    ])
    #expect(try OTelJSONParser.records(from: ignoredData).isEmpty)

    let websocket: [String: Any] = [
        "eventName": "codex.websocket_event",
        "eventType": "response.completed",
        "timeUnixNano": "1785060000000000000",
        "attributes": [
            otelAttribute("model", "stringValue", "gpt-5.6-terra"),
            otelAttribute("input_token_count", "intValue", "11"),
            otelAttribute("output_token_count", "intValue", "3"),
        ],
    ]
    let websocketRecords = try OTelJSONParser.records(
        from: otlpData(logRecords: [websocket])
    )
    #expect(websocketRecords.count == 1)
    #expect(websocketRecords.first?.model == "gpt-5.6-terra")
}

@Test("OTel body-only JSON допускает leading JSON whitespace")
func otelParserAcceptsWhitespaceBeforeBodyJSON() throws {
    let bodyObject: [String: Any] = [
        "event.name": "codex.sse_event",
        "event.kind": "response.completed",
        "model": "gpt-5.6-terra",
        "input_tokens": 14,
        "output_tokens": 3,
    ]
    let encodedBody = try JSONSerialization.data(
        withJSONObject: bodyObject,
        options: [.sortedKeys]
    )
    let bodyText = " \t\r\n" + (try #require(
        String(data: encodedBody, encoding: .utf8)
    ))
    let logRecord: [String: Any] = [
        "timeUnixNano": "1785060000000000000",
        "body": ["stringValue": bodyText],
    ]

    let records = try OTelJSONParser.records(
        from: otlpData(logRecords: [logRecord])
    )
    let record = try #require(records.first)
    #expect(records.count == 1)
    #expect(record.model == "gpt-5.6-terra")
    #expect(record.inputTokens == 14)
    #expect(record.outputTokens == 3)
}

@Test("Completed OTel event с неполной usage schema отклоняется")
func otelParserRejectsMalformedCompletedEvent() throws {
    var malformed = completedOTelLogRecord()
    malformed["attributes"] = [
        otelAttribute("event.name", "stringValue", "codex.sse_event"),
        otelAttribute("event.kind", "stringValue", "response.completed"),
        otelAttribute("slug", "stringValue", "gpt-5.6-sol"),
        otelAttribute("input_token_count", "intValue", "10"),
    ]

    do {
        _ = try OTelJSONParser.records(
            from: otlpData(logRecords: [malformed])
        )
        Issue.record("malformed completed event unexpectedly succeeded")
    } catch let error as OTelJSONParserError {
        #expect(error == .invalidCompletedEvent)
    }
}

@Test("OTel token attributes принимают только конечные целые counters")
func otelParserStrictlyDecodesTokenCounters() throws {
    let invalidAttributes: [[String: Any]] = [
        otelAttribute("input_token_count", "boolValue", true),
        otelAttribute("input_token_count", "boolValue", false),
        otelAttribute("input_token_count", "doubleValue", 1.5),
        otelAttribute("input_token_count", "intValue", "2.5"),
        otelAttribute("input_token_count", "intValue", "1e300"),
    ]

    for invalidAttribute in invalidAttributes {
        var logRecord = completedOTelLogRecord()
        var attributes = try #require(
            logRecord["attributes"] as? [[String: Any]]
        )
        attributes.removeAll {
            ($0["key"] as? String) == "input_token_count"
        }
        attributes.append(invalidAttribute)
        logRecord["attributes"] = attributes

        do {
            _ = try OTelJSONParser.records(
                from: otlpData(logRecords: [logRecord])
            )
            Issue.record("invalid OTel token counter unexpectedly succeeded")
        } catch let error as OTelJSONParserError {
            #expect(error == .invalidCompletedEvent)
        }
    }
}

@Test("OTel отклоняет противоречивую identity и фиксирует provenance")
func otelParserRejectsConflictingIdentityAndForcesSource() throws {
    for (field, value, expectedField) in [
        ("eventName", "codex.websocket_event", "event.name"),
        ("eventType", "response.in_progress", "event.kind"),
    ] {
        var conflicting = completedOTelLogRecord()
        conflicting[field] = value
        do {
            _ = try OTelJSONParser.records(
                from: otlpData(logRecords: [conflicting])
            )
            Issue.record("conflicting OTel identity unexpectedly succeeded")
        } catch let error as OTelJSONParserError {
            #expect(error == .invalidField(expectedField))
        }
    }

    var spoofed = completedOTelLogRecord()
    var attributes = try #require(
        spoofed["attributes"] as? [[String: Any]]
    )
    attributes.append(
        otelAttribute("source", "stringValue", "spoofed-source")
    )
    spoofed["attributes"] = attributes
    let record = try #require(
        OTelJSONParser.records(
            from: otlpData(logRecords: [spoofed])
        ).first
    )
    #expect(record.source == "otel-live")
}

@Test("OTel preflight ограничивает nested body до materialization")
func otelParserPreflightsNestedBodyJSON() throws {
    var junk = "0"
    for _ in 0...OTelJSONParser.maximumJSONDepth {
        junk = #"{"nested":\#(junk)}"#
    }
    let body = """
    {"event.name":"codex.sse_event","event.kind":"response.completed","model":"gpt-5.6-sol","input_tokens":1,"output_tokens":1,"junk":\(junk)}
    """
    let logRecord: [String: Any] = [
        "timeUnixNano": "1785060000000000000",
        "body": ["stringValue": body],
    ]

    do {
        _ = try OTelJSONParser.records(
            from: otlpData(logRecords: [logRecord])
        )
        Issue.record("deep nested OTel body unexpectedly succeeded")
    } catch let error as OTelJSONParserError {
        guard case .limitExceeded = error else {
            Issue.record("unexpected nested body error: \(error)")
            return
        }
    }
}

@Test("OTel parser ограничивает records, attributes и строки")
func otelParserEnforcesStructuralLimits() throws {
    do {
        _ = try OTelJSONParser.records(
            from: otlpData(
                logRecords: Array(
                    repeating: [String: Any](),
                    count: OTelJSONParser.maximumLogRecords + 1
                )
            )
        )
        Issue.record("excessive log record count unexpectedly succeeded")
    } catch let error as OTelJSONParserError {
        #expect(error == .limitExceeded(.logRecords))
    }

    let tooManyAttributes = (0...OTelJSONParser.maximumAttributesPerEntity)
        .map { index in
            otelAttribute("field-\(index)", "stringValue", "value")
        }
    do {
        _ = try OTelJSONParser.records(
            from: otlpData(logRecords: [[
                "attributes": tooManyAttributes,
            ]])
        )
        Issue.record("excessive attribute count unexpectedly succeeded")
    } catch let error as OTelJSONParserError {
        #expect(error == .limitExceeded(.attributesPerEntity))
    }

    let oversizedString = String(
        repeating: "x",
        count: OTelJSONParser.maximumStringLength + 1
    )
    do {
        _ = try OTelJSONParser.records(
            from: otlpData(logRecords: [[
                "body": ["stringValue": oversizedString],
            ]])
        )
        Issue.record("oversized OTel string unexpectedly succeeded")
    } catch let error as OTelJSONParserError {
        #expect(error == .limitExceeded(.stringLength))
    }
}

@Test("HTTP parser сохраняет incomplete/malformed distinction и limits")
func hardenedHTTPParserDistinguishesStructuralState() {
    switch HTTPRequest.parse(Data("POST /v1/logs HTTP/1.1\r\nHost: 127".utf8)) {
    case .incomplete:
        break
    default:
        Issue.record("partial header was not classified as incomplete")
    }

    let partialBody = Data(
        "POST /v1/logs HTTP/1.1\r\nContent-Length: 2\r\n\r\n{".utf8
    )
    switch HTTPRequest.parse(partialBody) {
    case .incomplete:
        break
    default:
        Issue.record("partial body was not classified as incomplete")
    }

    let duplicate = Data(
        "POST /v1/logs HTTP/1.1\r\nContent-Length: 0\r\ncontent-length: 0\r\n\r\n".utf8
    )
    switch HTTPRequest.parse(duplicate) {
    case .malformed(let error):
        #expect(error == .duplicateHeader)
    default:
        Issue.record("duplicate Content-Length was not rejected")
    }

    let oversizedHeader = Data(
        repeating: 0x41,
        count: OTelLiveReceiver.maximumHeaderSize + 1
    )
    switch HTTPRequest.parse(oversizedHeader) {
    case .malformed(let error):
        #expect(error == .headerTooLarge)
    default:
        Issue.record("oversized header was not rejected")
    }

    #expect(OTelLiveReceiver.admitsConnection(activeCount: 15))
    #expect(!OTelLiveReceiver.admitsConnection(activeCount: 16))
    #expect(!OTelLiveReceiver.admitsConnection(activeCount: -1))
    #expect(
        !OTelLiveReceiver.shouldExpireIncompleteRequest(
            hasCompletedRequest: false,
            elapsed: OTelLiveReceiver.incompleteRequestTimeout - 0.01
        )
    )
    #expect(
        OTelLiveReceiver.shouldExpireIncompleteRequest(
            hasCompletedRequest: false,
            elapsed: OTelLiveReceiver.incompleteRequestTimeout
        )
    )
    #expect(
        !OTelLiveReceiver.shouldExpireIncompleteRequest(
            hasCompletedRequest: true,
            elapsed: OTelLiveReceiver.incompleteRequestTimeout
        )
    )
}

@Test("OTel config detector распознаёт TOML table variants и inline table")
func otelConfigRecognizesAllSupportedForms() {
    for text in [
        "[ otel ]\nenvironment = \"custom\"",
        "[\"otel\"]\nenvironment = \"custom\"",
        "[otel.exporter]\nkind = \"custom\"",
        "[\"otel\" . 'exporter.kind']\nkind = \"custom\"",
        "[[otel.exporters]]\nkind = \"custom\"",
        "[[ \"otel\" . \"exporter#kind\" ]] # existing\nkind = \"custom\"",
        "otel = { environment = \"custom\" }",
        "otel = false",
        "\"otel\" = []",
        "'otel' = \"custom\"",
        "otel.exporter = { none = true }",
        "otel . exporter = { none = true }",
        "\"otel\" . \"exporter.kind\" = \"none\"",
        "otel.\"exporter#kind\" = \"none\"",
        "'otel'.'environment' = 'existing'",
        #"["o\u0074el"]"#,
        #"[["o\U00000074el".exporters]]"#,
        #""o\u0074el" = false"#,
        #""o\u0074el".exporter = { none = true }"#,
    ] {
        #expect(
            OTelConfigManager.configurationStatus(in: text) == .existing
        )
    }
    #expect(
        OTelConfigManager.configurationStatus(in: "# [otel]\n[x]\na = 1")
            == .absent
    )
    for text in [
        "[telemetry.otel]\nenabled = true",
        "[otelish.exporter]\nenabled = true",
        "# [[otel.exporter]]",
        ##"""
        value = """
        ["o\u0074el"]
        otel.exporter = false
        """
        """##,
        """
        value = '''
        [otel]
        otel = false
        '''
        """,
        #"value = "[otel]""#,
    ] {
        #expect(
            OTelConfigManager.configurationStatus(in: text) == .absent
        )
    }
}

@Test("OTel config требует ручного удаления legacy block")
func otelConfigRefusesLegacyRewrite() throws {
    let directory = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let codexDirectory = directory.appendingPathComponent(
        ".codex",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: codexDirectory,
        withIntermediateDirectories: true
    )
    let config = codexDirectory.appendingPathComponent("config.toml")
    let legacy = """
    title = "preserve"

    # Codex Usage Lens: local token telemetry only.
    [otel]
    environment = "codex-usage-lens"
    log_user_prompt = false
    exporter = { otlp-http = { endpoint = "http://127.0.0.1:4319/v1/logs", protocol = "json" } }

    [features]
    enabled = true
    """
    try Data(legacy.utf8).write(to: config)

    #expect(
        try OTelConfigManager.configurationStatus(at: config)
            == .managedLegacy
    )
    #expect(!OTelConfigManager.canInstall(at: config))
    do {
        try OTelConfigManager.install(
            capabilityToken: testOTelCapabilityToken,
            configURL: config
        )
        Issue.record("legacy OTel configuration unexpectedly rewritten")
    } catch let error as OTelConfigError {
        #expect(error == .managedLegacyRequiresManualRemoval)
        #expect(error.localizedDescription.contains("Удалите его вручную"))
    }
    #expect(try String(contentsOf: config, encoding: .utf8) == legacy)
}

@Test("OTel config не перезаписывает произвольный existing section")
func otelConfigPreservesArbitraryExistingSection() throws {
    let directory = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("config.toml")
    let original = "[ otel ]\nexporter = \"custom\"\n"
    try Data(original.utf8).write(to: config)

    do {
        try OTelConfigManager.install(
            capabilityToken: testOTelCapabilityToken,
            configURL: config
        )
        Issue.record("arbitrary [otel] section unexpectedly overwritten")
    } catch let error as OTelConfigError {
        #expect(error == .existingSection)
    }
    #expect(try String(contentsOf: config, encoding: .utf8) == original)
}

@Test("OTel config не дублирует top-level dotted keys")
func otelConfigPreservesDottedKeys() throws {
    let directory = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("config.toml")
    let original = """
    "otel" . exporter = { custom = true }
    'otel'.'environment' = 'existing'
    """
    try Data(original.utf8).write(to: config)

    #expect(!OTelConfigManager.canInstall(at: config))
    do {
        try OTelConfigManager.install(
            capabilityToken: testOTelCapabilityToken,
            configURL: config
        )
        Issue.record("dotted OTel configuration unexpectedly duplicated")
    } catch let error as OTelConfigError {
        #expect(error == .existingSection)
    }
    #expect(try String(contentsOf: config, encoding: .utf8) == original)
}

@Test("OTel config не переопределяет top-level assignment")
func otelConfigPreservesTopLevelAssignments() throws {
    let directory = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    for (index, original) in [
        "otel = false\n",
        "\"otel\" = []\n",
        "'otel' = \"custom\"\n",
    ].enumerated() {
        let config = directory.appendingPathComponent(
            "assignment-\(index).toml"
        )
        try Data(original.utf8).write(to: config)

        do {
            try OTelConfigManager.install(
                capabilityToken: testOTelCapabilityToken,
                configURL: config
            )
            Issue.record("top-level otel assignment unexpectedly redefined")
        } catch let error as OTelConfigError {
            #expect(error == .existingSection)
        }
        #expect(try String(contentsOf: config, encoding: .utf8) == original)
    }
}

@Test("OTel config append сохраняет inode и создаёт private absent file")
func otelConfigAppendsOrCreatesWithoutRewrite() throws {
    let directory = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let existing = directory.appendingPathComponent("existing.toml")
    let original = "[features]\nenabled = true"
    try Data(original.utf8).write(to: existing)
    var beforeInfo = stat()
    #expect(existing.path.withCString { lstat($0, &beforeInfo) } == 0)

    try OTelConfigManager.install(
        capabilityToken: testOTelCapabilityToken,
        configURL: existing
    )
    let appended = try String(contentsOf: existing, encoding: .utf8)
    var afterInfo = stat()
    #expect(existing.path.withCString { lstat($0, &afterInfo) } == 0)
    #expect(afterInfo.st_dev == beforeInfo.st_dev)
    #expect(afterInfo.st_ino == beforeInfo.st_ino)
    #expect((afterInfo.st_mode & mode_t(0o777)) == mode_t(0o600))
    #expect(appended.hasPrefix(original))
    #expect(appended.contains(OTelCapabilityToken.headerName))
    #expect(appended.contains(testOTelCapabilityToken))

    let absent = directory.appendingPathComponent("created.toml")
    try OTelConfigManager.install(
        capabilityToken: testOTelCapabilityToken,
        configURL: absent
    )
    let created = try String(contentsOf: absent, encoding: .utf8)
    var createdInfo = stat()
    #expect(absent.path.withCString { lstat($0, &createdInfo) } == 0)
    #expect((createdInfo.st_mode & mode_t(0o777)) == mode_t(0o600))
    #expect(created.contains(OTelCapabilityToken.headerName))
}

@Test("OTel config откатывает partial append и partial create")
func otelConfigRollsBackPartialWrites() throws {
    let directory = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let existing = directory.appendingPathComponent("existing.toml")
    let original = "[features]\nenabled = true\n"
    try Data(original.utf8).write(to: existing)
    var originalInfo = stat()
    #expect(existing.path.withCString { lstat($0, &originalInfo) } == 0)

    do {
        try OTelConfigManager.install(
            capabilityToken: testOTelCapabilityToken,
            configURL: existing,
            writeLimitForTesting: 7
        )
        Issue.record("partial config append unexpectedly succeeded")
    } catch let error as OTelConfigError {
        guard case .fileAccess(let code) = error else {
            Issue.record("unexpected partial append error: \(error)")
            return
        }
        #expect(code == EIO)
    }
    var restoredInfo = stat()
    #expect(existing.path.withCString { lstat($0, &restoredInfo) } == 0)
    #expect(restoredInfo.st_dev == originalInfo.st_dev)
    #expect(restoredInfo.st_ino == originalInfo.st_ino)
    #expect(try String(contentsOf: existing, encoding: .utf8) == original)

    let absent = directory.appendingPathComponent("absent.toml")
    do {
        try OTelConfigManager.install(
            capabilityToken: testOTelCapabilityToken,
            configURL: absent,
            writeLimitForTesting: 7
        )
        Issue.record("partial config create unexpectedly succeeded")
    } catch let error as OTelConfigError {
        guard case .fileAccess(let code) = error else {
            Issue.record("unexpected partial create error: \(error)")
            return
        }
        #expect(code == EIO)
    }
    #expect(!FileManager.default.fileExists(atPath: absent.path))
}

@Test("OTel config не мигрирует legacy block рядом со вторым OTel section")
func otelConfigRejectsLegacyBlockWithDuplicateSection() throws {
    let directory = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("config.toml")
    let original = """
    # Codex Usage Lens: local token telemetry only.
    [otel]
    environment = "codex-usage-lens"
    log_user_prompt = false
    exporter = { otlp-http = { endpoint = "http://127.0.0.1:4319/v1/logs", protocol = "json" } }

    ["otel"]
    environment = "arbitrary-second-section"
    """
    try Data(original.utf8).write(to: config)

    #expect(
        OTelConfigManager.configurationStatus(in: original) == .existing
    )
    #expect(!OTelConfigManager.canInstall(at: config))
    do {
        try OTelConfigManager.install(
            capabilityToken: testOTelCapabilityToken,
            configURL: config
        )
        Issue.record("duplicate OTel configuration unexpectedly migrated")
    } catch let error as OTelConfigError {
        #expect(error == .existingSection)
    }
    #expect(try String(contentsOf: config, encoding: .utf8) == original)
}

@Test("OTel config не считает изменённые legacy values app-managed")
func otelConfigRejectsLookalikeLegacyValues() {
    let lookalikes = [
        """
        # Codex Usage Lens: local token telemetry only.
        [otel]
        environment = "codex - usage - lens"
        log_user_prompt = false
        exporter = { otlp-http = { endpoint = "http://127.0.0.1:4319/v1/logs", protocol = "json" } }
        """,
        """
        # Codex Usage Lens: local token telemetry only.
        [otel]
        environment = "codex-usage-lens"
        # user annotation that must be preserved
        log_user_prompt = false
        exporter = { otlp-http = { endpoint = "http://127.0.0.1:4319/v1/logs", protocol = "json" } }
        """,
    ]

    for lookalike in lookalikes {
        #expect(
            OTelConfigManager.configurationStatus(in: lookalike)
                == .existing
        )
    }
}

@Test("OTel config обнаруживает lost update перед commit")
func otelConfigDetectsConcurrentModification() throws {
    let directory = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("config.toml")
    try Data("[features]\na = true\n".utf8).write(to: config)
    let concurrent = "[features]\na = false\n"

    do {
        try OTelConfigManager.install(
            capabilityToken: testOTelCapabilityToken,
            configURL: config,
            beforeCommit: {
                try Data(concurrent.utf8).write(to: config, options: .atomic)
            }
        )
        Issue.record("concurrent config update unexpectedly overwritten")
    } catch let error as OTelConfigError {
        #expect(error == .concurrentModification)
    }
    #expect(try String(contentsOf: config, encoding: .utf8) == concurrent)
}

@Test("OTel config сохраняет concurrent in-place и atomic updates")
func otelConfigPreservesConcurrentUpdatesAfterOpen() throws {
    let directory = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    for atomic in [false, true] {
        let config = directory.appendingPathComponent(
            atomic ? "atomic.toml" : "in-place.toml"
        )
        let original = "[features]\na = true\n"
        let concurrent = "# concurrent-\(atomic)\n"
        try Data(original.utf8).write(to: config)

        do {
            try OTelConfigManager.install(
                capabilityToken: testOTelCapabilityToken,
                configURL: config,
                beforeAppend: {
                    if atomic {
                        try Data(concurrent.utf8).write(
                            to: config,
                            options: .atomic
                        )
                    } else {
                        let handle = try FileHandle(forWritingTo: config)
                        defer { try? handle.close() }
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data(concurrent.utf8))
                        try handle.synchronize()
                    }
                }
            )
            Issue.record("concurrent update unexpectedly accepted")
        } catch let error as OTelConfigError {
            #expect(error == .concurrentModification)
        }

        let preserved = try String(contentsOf: config, encoding: .utf8)
        #expect(preserved.contains(concurrent))
        #expect(!preserved.contains(OTelCapabilityToken.headerName))
        if !atomic {
            #expect(preserved.hasPrefix(original))
        }
    }
}

@Test("OTel config absent-create race сохраняет winning writer")
func otelConfigPreservesAbsentCreateRace() throws {
    let directory = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("config.toml")
    let concurrent = "[features]\nwriter = \"winner\"\n"

    do {
        try OTelConfigManager.install(
            capabilityToken: testOTelCapabilityToken,
            configURL: config,
            beforeCommit: {
                try Data(concurrent.utf8).write(to: config)
            }
        )
        Issue.record("absent-file race unexpectedly overwrote winner")
    } catch let error as OTelConfigError {
        #expect(error == .concurrentModification)
    }
    #expect(try String(contentsOf: config, encoding: .utf8) == concurrent)
}

@Test("OTel config install отклоняет symlink и special parent")
func otelConfigRejectsUnsafeParentDirectory() throws {
    let directory = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let realParent = directory.appendingPathComponent(
        "real-parent",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: realParent,
        withIntermediateDirectories: false
    )
    let linkedParent = directory.appendingPathComponent("linked-parent")
    try FileManager.default.createSymbolicLink(
        at: linkedParent,
        withDestinationURL: realParent
    )

    let fifoParent = directory.appendingPathComponent("fifo-parent")
    #expect(fifoParent.path.withCString {
        mkfifo($0, mode_t(0o600))
    } == 0)

    for unsafeParent in [linkedParent, fifoParent] {
        do {
            try OTelConfigManager.install(
                capabilityToken: testOTelCapabilityToken,
                configURL: unsafeParent.appendingPathComponent("config.toml")
            )
            Issue.record("unsafe config parent unexpectedly accepted")
        } catch let error as OTelConfigError {
            #expect(error == .unsafeConfigurationFile)
        }
    }
    #expect(
        !FileManager.default.fileExists(
            atPath: realParent.appendingPathComponent("config.toml").path
        )
    )
}

@Test("OTel config отклоняет symlink, FIFO, oversized и non-UTF8")
func otelConfigRejectsUnsafeFiles() throws {
    let directory = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let target = directory.appendingPathComponent("target.toml")
    try Data("[features]\n".utf8).write(to: target)
    let symlink = directory.appendingPathComponent("symlink.toml")
    try FileManager.default.createSymbolicLink(
        at: symlink,
        withDestinationURL: target
    )
    do {
        _ = try OTelConfigManager.configurationStatus(at: symlink)
        Issue.record("config symlink unexpectedly accepted")
    } catch let error as OTelConfigError {
        #expect(error == .unsafeConfigurationFile)
    }

    let fifo = directory.appendingPathComponent("config.pipe")
    #expect(fifo.path.withCString { mkfifo($0, mode_t(0o600)) } == 0)
    do {
        _ = try OTelConfigManager.configurationStatus(at: fifo)
        Issue.record("config FIFO unexpectedly accepted")
    } catch let error as OTelConfigError {
        #expect(error == .unsafeConfigurationFile)
    }

    let oversized = directory.appendingPathComponent("oversized.toml")
    try Data(
        repeating: 0x61,
        count: OTelConfigManager.maximumConfigurationSize + 1
    ).write(to: oversized)
    do {
        _ = try OTelConfigManager.configurationStatus(at: oversized)
        Issue.record("oversized config unexpectedly accepted")
    } catch let error as OTelConfigError {
        #expect(error == .configurationTooLarge)
    }

    let invalidUTF8 = directory.appendingPathComponent("invalid.toml")
    try Data([0xFF, 0xFE]).write(to: invalidUTF8)
    do {
        _ = try OTelConfigManager.configurationStatus(at: invalidUTF8)
        Issue.record("non-UTF8 config unexpectedly accepted")
    } catch let error as OTelConfigError {
        #expect(error == .invalidConfiguration)
    }
}

@Test("Pricing download buffer имеет истинный incremental limit")
func pricingBufferEnforcesIncrementalLimit() throws {
    var buffer = BoundedPricingBuffer(maximumBytes: 4)
    try buffer.append(Data([1, 2]))
    try buffer.append(Data([3, 4]))
    #expect(buffer.data == Data([1, 2, 3, 4]))
    #expect(throws: PricingCatalogError.self) {
        try buffer.append(Data([5]))
    }
}

@Test("Pricing redirect допускает только exact official HTTPS origin")
func pricingRedirectAllowsOnlyExactOfficialOrigin() throws {
    let allowed = [
        "https://developers.openai.com/api/docs/models/test",
        "HTTPS://DEVELOPERS.OPENAI.COM:443/redirected?q=1#prices",
    ]
    for rawURL in allowed {
        var request = URLRequest(url: try #require(URL(string: rawURL)))
        request.httpMethod = "GET"
        request.setValue("preserved", forHTTPHeaderField: "X-Test")

        let accepted = try #require(
            OfficialPricingCatalog.redirectRequestIfAllowed(request)
        )
        #expect(OfficialPricingCatalog.isOfficialOrigin(accepted.url))
        #expect(accepted.url == request.url)
        #expect(accepted.httpMethod == "GET")
        #expect(
            accepted.value(forHTTPHeaderField: "X-Test") == "preserved"
        )
    }

    let rejected = [
        "http://developers.openai.com/pricing",
        "https://developers.openai.com:444/pricing",
        "https://developers.openai.com./pricing",
        "https://sub.developers.openai.com/pricing",
        "https://developers.openai.com.evil.example/pricing",
        "https://example.com/pricing",
        "https://127.0.0.1/pricing",
        "https://10.0.0.1/pricing",
        "https://user@developers.openai.com/pricing",
        "https://@developers.openai.com/pricing",
        "https://user:password@developers.openai.com/pricing",
    ]
    for rawURL in rejected {
        let request = URLRequest(url: try #require(URL(string: rawURL)))
        #expect(!OfficialPricingCatalog.isOfficialOrigin(request.url))
        #expect(
            OfficialPricingCatalog.redirectRequestIfAllowed(request) == nil
        )
    }
    #expect(!OfficialPricingCatalog.isOfficialOrigin(nil))
}

@Test("Pricing response требует 2xx, official HTTPS HTML и bounded length")
func pricingResponseValidationRejectsUntrustedResponses() throws {
    let expectedURL = try #require(
        URL(string: "https://developers.openai.com/api/docs/models/test")
    )
    let valid = try #require(HTTPURLResponse(
        url: expectedURL,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": "100",
        ]
    ))
    try OfficialPricingCatalog.validate(
        response: valid,
        expectedURL: expectedURL
    )

    let cases: [(HTTPURLResponse, PricingCatalogError)] = [
        (
            try #require(HTTPURLResponse(
                url: expectedURL,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )),
            .invalidStatus(500)
        ),
        (
            try #require(HTTPURLResponse(
                url: URL(string: "https://example.com/pricing")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )),
            .unexpectedOrigin
        ),
        (
            try #require(HTTPURLResponse(
                url: URL(
                    string:
                        "https://developers.openai.com:444/pricing"
                )!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )),
            .unexpectedOrigin
        ),
        (
            try #require(HTTPURLResponse(
                url: URL(
                    string:
                        "https://user@developers.openai.com/pricing"
                )!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )),
            .unexpectedOrigin
        ),
        (
            try #require(HTTPURLResponse(
                url: expectedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )),
            .unexpectedContentType
        ),
        (
            try #require(HTTPURLResponse(
                url: expectedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "text/html",
                    "Content-Length":
                        String(OfficialPricingCatalog.maximumResponseSize + 1),
                ]
            )),
            .responseTooLarge
        ),
    ]

    for (response, expectedError) in cases {
        do {
            try OfficialPricingCatalog.validate(
                response: response,
                expectedURL: expectedURL
            )
            Issue.record("unsafe pricing response unexpectedly accepted")
        } catch let error as PricingCatalogError {
            #expect(error == expectedError)
        }
    }
}

@Test("Pricing loader блокирует cross-origin redirect до target request")
func pricingLoaderBlocksCrossOriginRedirectBeforeTargetRequest() async throws {
    let targetServer = try LoopbackHTTPTestServer {
        Data(
            (
                "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: text/html\r\n"
                    + "Content-Length: 0\r\n"
                    + "Connection: close\r\n\r\n"
            ).utf8
        )
    }
    defer { targetServer.stop() }

    let targetURL =
        "http://127.0.0.1:\(targetServer.port)/probe"
    let redirectServer = try LoopbackHTTPTestServer {
        Data(
            (
                "HTTP/1.1 302 Found\r\n"
                    + "Location: \(targetURL)\r\n"
                    + "Content-Length: 0\r\n"
                    + "Connection: close\r\n\r\n"
            ).utf8
        )
    }
    defer { redirectServer.stop() }
    let redirectURL = try #require(
        URL(
            string:
                "http://127.0.0.1:\(redirectServer.port)/redirect"
        )
    )

    do {
        _ = try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<Data, any Error>
            ) in
            BoundedPricingPageLoader.load(
                url: redirectURL,
                maximumBytes: OfficialPricingCatalog.maximumResponseSize
            ) {
                continuation.resume(with: $0)
            }
        }
        Issue.record("cross-origin redirect response unexpectedly accepted")
    } catch let error as PricingCatalogError {
        #expect(error == .unexpectedOrigin)
    }

    usleep(100_000)
    #expect(
        targetServer.requestCount == 0,
        "cross-origin redirect reached the second loopback origin"
    )
}

@Test("Pricing parser отвергает отрицательные и чрезмерные цены")
func pricingParserRejectsUnsafeNumericValues() throws {
    let invalidInputs = [
        "-1",
        "10001",
        "NaN",
        "999999999999999999999999",
    ]
    for input in invalidInputs {
        let html = """
        <div>Input</div><div>$\(input)</div>
        <div>Cached input</div><div>$0.50</div>
        <div>Output</div><div>$30.00</div>
        """
        #expect(throws: PricingCatalogError.self) {
            try OfficialPricingCatalog.parsePricing(html)
        }
    }
}

@Test("App-server валидирует account counters и bucket cardinality")
func appServerRejectsUnsafeAccountUsage() throws {
    let invalidObjects: [[String: Any]] = [
        [
            "summary": ["lifetimeTokens": -1],
            "dailyUsageBuckets": [],
        ],
        [
            "summary": [
                "lifetimeTokens":
                    CodexAppServerClient.maximumAccountCounter + 1,
            ],
            "dailyUsageBuckets": [],
        ],
        [
            "summary": ["lifetimeTokens": 1],
            "dailyUsageBuckets": [
                ["startDate": "2026-07-26", "tokens": -1],
            ],
        ],
        [
            "summary": ["lifetimeTokens": 1],
            "dailyUsageBuckets": [
                ["startDate": "2026-02-30", "tokens": 1],
            ],
        ],
        [
            "summary": ["lifetimeTokens": 1],
            "dailyUsageBuckets": [
                ["startDate": "2026-07-26", "tokens": 1],
                ["startDate": "2026-07-26", "tokens": 2],
            ],
        ],
        [
            "summary": ["lifetimeTokens": 1],
            "dailyUsageBuckets": Array(
                repeating: [
                    "startDate": "2026-07-26",
                    "tokens": 1,
                ],
                count: CodexAppServerClient.maximumDailyUsageBuckets + 1
            ),
        ],
    ]

    for object in invalidObjects {
        do {
            _ = try CodexAppServerClient.decodeAccountUsage(from: object)
            Issue.record("unsafe account usage unexpectedly accepted")
        } catch let error as CodexAppServerError {
            #expect(error == .invalidResponse)
        }
    }
}

@Test("App-server ограничивает model array и model strings")
func appServerRejectsUnsafeModelLists() throws {
    let tooMany = [
        "data": Array(
            repeating: ["id": "model-a"],
            count: CodexAppServerClient.maximumModelCount + 1
        ),
    ]
    let longString = [
        "data": [[
            "id": String(
                repeating: "m",
                count: CodexAppServerClient.maximumModelStringBytes + 1
            ),
        ]],
    ]

    for object in [tooMany, longString] {
        do {
            _ = try CodexAppServerClient.decodeModels(from: object)
            Issue.record("unsafe model list unexpectedly accepted")
        } catch let error as CodexAppServerError {
            #expect(error == .invalidResponse)
        }
    }

    let models = try CodexAppServerClient.decodeModels(from: [
        "data": [[
            "id": "gpt-5.6-sol",
            "model": "gpt-5.6-sol",
            "displayName": "GPT-5.6 Sol",
            "hidden": false,
            "isDefault": true,
        ]],
    ])
    #expect(models.count == 1)
    #expect(models.first?.id == "gpt-5.6-sol")
}

@Test("Usage response сигналит до optional model/list response")
func appServerUsageDoesNotWaitForModels() throws {
    let input = Pipe()
    defer {
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
    }
    let state = AppServerState(
        input: input.fileHandleForWriting,
        executablePath: "/tmp/codex"
    )
    let line = """
    {"id":1,"result":{"summary":{"lifetimeTokens":42},"dailyUsageBuckets":[]}}

    """
    state.consume(Data(line.utf8))

    #expect(state.usageFinished.wait(timeout: .now() + 0.1) == .success)
    #expect(state.modelsFinished.wait(timeout: .now() + 0.01) == .timedOut)
    #expect(state.snapshot().usage?.summary.lifetimeTokens == 42)
}

@Test("App-server сопоставляет только целые non-boolean JSON-RPC id")
func appServerStrictlyDecodesResponseIDs() throws {
    let usageResult =
        #"{"summary":{"lifetimeTokens":42},"dailyUsageBuckets":[]}"#
    let invalidLines = [
        #"{"id":true,"result":\#(usageResult)}"#,
        #"{"id":false,"error":{"message":"sentinel"}}"#,
        #"{"id":1.5,"result":\#(usageResult)}"#,
        #"{"id":1.0000000000000001,"result":\#(usageResult)}"#,
        #"{"id":1e100,"result":\#(usageResult)}"#,
        #"{"id":"1","result":\#(usageResult)}"#,
    ]

    for line in invalidLines {
        let input = Pipe()
        let state = AppServerState(
            input: input.fileHandleForWriting,
            executablePath: "/tmp/codex"
        )
        state.consume(Data((line + "\n").utf8))

        #expect(
            state.usageFinished.wait(timeout: .now() + 0.01) == .timedOut
        )
        let snapshot = state.snapshot()
        #expect(snapshot.usage == nil)
        #expect(snapshot.error == nil)
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
    }

    let validInput = Pipe()
    defer {
        try? validInput.fileHandleForWriting.close()
        try? validInput.fileHandleForReading.close()
    }
    let validState = AppServerState(
        input: validInput.fileHandleForWriting,
        executablePath: "/tmp/codex"
    )
    validState.consume(
        Data(
            (#"{"id":1,"result":\#(usageResult)}"# + "\n").utf8
        )
    )
    #expect(
        validState.usageFinished.wait(timeout: .now() + 0.1) == .success
    )
    #expect(validState.snapshot().usage?.summary.lifetimeTokens == 42)
}

@Test("App-server stdout имеет line и total byte limits")
func appServerBoundsStdout() throws {
    let linePipe = Pipe()
    defer {
        try? linePipe.fileHandleForWriting.close()
        try? linePipe.fileHandleForReading.close()
    }
    let lineState = AppServerState(
        input: linePipe.fileHandleForWriting,
        executablePath: "/tmp/codex"
    )
    lineState.consume(Data(
        repeating: 0x61,
        count: AppServerState.maximumLineSize + 1
    ))
    let lineError = try #require(
        lineState.snapshot().error as? CodexAppServerError
    )
    #expect(lineError == .outputLimitExceeded)

    let totalPipe = Pipe()
    defer {
        try? totalPipe.fileHandleForWriting.close()
        try? totalPipe.fileHandleForReading.close()
    }
    let totalState = AppServerState(
        input: totalPipe.fileHandleForWriting,
        executablePath: "/tmp/codex"
    )
    var chunk = Data(repeating: 0x61, count: 400_000)
    chunk.append(0x0A)
    for _ in 0..<11 {
        totalState.consume(chunk)
    }
    let totalError = try #require(
        totalState.snapshot().error as? CodexAppServerError
    )
    #expect(totalError == .outputLimitExceeded)
}

@Test("Initialize request сообщает текущую client version")
func appServerInitializeVersionIsCurrent() throws {
    let request = CodexAppServerClient.initializeRequest()
    let params = try #require(request["params"] as? [String: Any])
    let clientInfo = try #require(params["clientInfo"] as? [String: Any])
    #expect(clientInfo["version"] as? String == "1.2.0")
}

@Test("Process cleanup escalates from ignored SIGTERM to SIGKILL")
func processTerminatorEscalatesToSIGKILL() throws {
    let directory = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("ready")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
        "-c",
        "trap '' TERM; : > \"$1\"; exec /bin/sleep 60",
        "codex-usage-process-test",
        marker.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    let readyDeadline = Date().addingTimeInterval(3)
    while
        !FileManager.default.fileExists(atPath: marker.path),
        Date() < readyDeadline
    {
        usleep(10_000)
    }
    guard FileManager.default.fileExists(atPath: marker.path) else {
        Issue.record("SIGTERM-resistant child did not become ready")
        return
    }

    ProcessTerminator.stop(process, gracePeriod: 0.05)
    #expect(!process.isRunning)
    #expect(process.terminationReason == .uncaughtSignal)
    #expect(process.terminationStatus == SIGKILL)
}
