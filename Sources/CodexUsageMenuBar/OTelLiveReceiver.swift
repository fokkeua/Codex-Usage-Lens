import Foundation
import Network
import Darwin

enum OTelCapabilityToken {
    static let headerName = "x-codex-usage-lens-token"
    private static let allowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    )

    static func isValid(_ token: String) -> Bool {
        guard (32...128).contains(token.utf8.count) else { return false }
        return token.unicodeScalars.allSatisfy(allowedCharacters.contains)
    }

    static func securelyMatches(_ supplied: String, expected: String) -> Bool {
        let suppliedBytes = Array(supplied.utf8)
        let expectedBytes = Array(expected.utf8)
        guard suppliedBytes.count == expectedBytes.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(suppliedBytes, expectedBytes) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

enum OTelRecordAcceptance: Sendable, Equatable {
    case accepted
    case temporarilyUnavailable
    case insufficientStorage
}

final class OTelLiveReceiver: @unchecked Sendable {
    static let port: NWEndpoint.Port = 4319
    static let maximumBodySize = 2 * 1024 * 1024
    static let maximumHeaderSize = 16 * 1024
    static let maximumRequestSize = maximumBodySize
    static let maximumConcurrentConnections = 16
    static let incompleteRequestTimeout: TimeInterval = 5
    static let deliveryTimeout: TimeInterval = 30

    private let queue = DispatchQueue(label: "CodexUsageLens.OTelReceiver")
    private let listenerLock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var onRecords: (
        @MainActor @Sendable (
            [UsageRecord],
            @escaping @Sendable (OTelRecordAcceptance) -> Void
        ) -> Void
    )?
    private var onStatus: (@MainActor @Sendable (String, Bool) -> Void)?

    func start(
        capabilityToken: String,
        onRecords: @escaping @MainActor @Sendable (
            [UsageRecord],
            @escaping @Sendable (OTelRecordAcceptance) -> Void
        ) -> Void,
        onStatus: @escaping @MainActor @Sendable (String, Bool) -> Void
    ) {
        self.onRecords = onRecords
        self.onStatus = onStatus
        guard OTelCapabilityToken.isValid(capabilityToken) else {
            report("Некорректный capability token OTel receiver", running: false)
            return
        }
        listenerLock.lock()
        guard listener == nil else {
            listenerLock.unlock()
            return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: Self.port
            )
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listenerLock.unlock()
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection, capabilityToken: capabilityToken)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.report("Слушает 127.0.0.1:\(Self.port.rawValue)", running: true)
                case .failed(let error):
                    self?.report("Ошибка OTel receiver: \(error.localizedDescription)", running: false)
                    self?.stop()
                case .waiting(let error):
                    self?.report("OTel receiver ожидает: \(error.localizedDescription)", running: false)
                case .cancelled:
                    self?.report("Live OTel выключен", running: false)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {
            listenerLock.unlock()
            report("Не удалось запустить OTel receiver: \(error.localizedDescription)", running: false)
        }
    }

    @available(*, deprecated, message: "Pass the persisted OTel capability token")
    func start(
        onRecords: @escaping @MainActor @Sendable (
            [UsageRecord],
            @escaping @Sendable (OTelRecordAcceptance) -> Void
        ) -> Void,
        onStatus: @escaping @MainActor @Sendable (String, Bool) -> Void
    ) {
        self.onRecords = onRecords
        self.onStatus = onStatus
        report("Live OTel требует capability token", running: false)
    }

    func stop() {
        listenerLock.lock()
        let listener = listener
        self.listener = nil
        listenerLock.unlock()
        listener?.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            let activeConnections = self.connections.values
            self.connections.removeAll(keepingCapacity: true)
            for connection in activeConnections {
                connection.cancel()
            }
        }
    }

    static func admitsConnection(activeCount: Int) -> Bool {
        activeCount >= 0 && activeCount < maximumConcurrentConnections
    }

    static func shouldExpireIncompleteRequest(
        hasCompletedRequest: Bool,
        elapsed: TimeInterval
    ) -> Bool {
        !hasCompletedRequest && elapsed >= incompleteRequestTimeout
    }

    private func handle(_ connection: NWConnection, capabilityToken: String) {
        guard Self.admitsConnection(activeCount: connections.count) else {
            connection.cancel()
            return
        }
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .cancelled, .failed:
                guard let self, let connection else { return }
                self.connections.removeValue(forKey: ObjectIdentifier(connection))
            default:
                break
            }
        }
        connection.start(queue: queue)
        let state = HTTPConnectionBuffer()
        receive(
            connection,
            state: state,
            capabilityToken: capabilityToken
        )
        queue.asyncAfter(
            deadline: .now() + Self.incompleteRequestTimeout
        ) { [weak self, weak connection, weak state] in
            guard
                let self,
                let connection,
                let state,
                Self.shouldExpireIncompleteRequest(
                    hasCompletedRequest: state.hasCompletedRequest,
                    elapsed: Self.incompleteRequestTimeout
                ),
                self.connections.removeValue(forKey: identifier) != nil
            else {
                return
            }
            connection.cancel()
        }
        queue.asyncAfter(deadline: .now() + Self.deliveryTimeout) {
            [weak self, weak connection] in
            guard
                let self,
                let connection,
                self.connections.removeValue(forKey: identifier) != nil
            else {
                return
            }
            connection.cancel()
        }
    }

    private func receive(
        _ connection: NWConnection,
        state: HTTPConnectionBuffer,
        capabilityToken: String
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                let maximumBufferedSize =
                    Self.maximumHeaderSize + Self.maximumBodySize + 4
                guard data.count <= maximumBufferedSize - state.data.count else {
                    self.respond(connection, status: .payloadTooLarge)
                    return
                }
                state.data.append(data)
            }

            switch HTTPRequest.parse(state.data) {
            case .complete(let request):
                state.hasCompletedRequest = true
                let outcome = OTelHTTPRequestProcessor.process(
                    request,
                    capabilityToken: capabilityToken
                )
                guard
                    outcome.status == .ok,
                    !outcome.records.isEmpty
                else {
                    self.respond(
                        connection,
                        status: outcome.status,
                        additionalHeaders: outcome.additionalHeaders
                    )
                    return
                }
                self.deliver(
                    outcome.records,
                    connection,
                    state: state
                )
            case .malformed(let parseError):
                self.respond(connection, status: parseError.responseStatus)
            case .incomplete:
                if error != nil {
                    self.finish(connection)
                } else if isComplete {
                    self.respond(connection, status: .badRequest)
                } else {
                    self.receive(
                        connection,
                        state: state,
                        capabilityToken: capabilityToken
                    )
                }
            }
        }
    }

    private func deliver(
        _ records: [UsageRecord],
        _ connection: NWConnection,
        state: HTTPConnectionBuffer
    ) {
        DispatchQueue.main.async { [weak self, weak connection] in
            guard let self, let connection else { return }
            guard let onRecords = self.onRecords else {
                self.queue.async {
                    self.respondAfterDelivery(
                        connection,
                        state: state,
                        acceptance: .temporarilyUnavailable
                    )
                }
                return
            }
            onRecords(records) { [weak self, weak connection] acceptance in
                guard let self, let connection else { return }
                self.queue.async {
                    self.respondAfterDelivery(
                        connection,
                        state: state,
                        acceptance: acceptance
                    )
                }
            }
        }
    }

    private func respondAfterDelivery(
        _ connection: NWConnection,
        state: HTTPConnectionBuffer,
        acceptance: OTelRecordAcceptance
    ) {
        let identifier = ObjectIdentifier(connection)
        guard
            connections[identifier] != nil,
            !state.hasStartedResponse
        else {
            return
        }
        state.hasStartedResponse = true
        respond(
            connection,
            status: Self.responseStatus(for: acceptance)
        )
    }

    static func responseStatus(
        for acceptance: OTelRecordAcceptance
    ) -> HTTPResponseStatus {
        switch acceptance {
        case .accepted:
            .ok
        case .temporarilyUnavailable:
            .serviceUnavailable
        case .insufficientStorage:
            .insufficientStorage
        }
    }

    private func respond(
        _ connection: NWConnection,
        status: HTTPResponseStatus,
        additionalHeaders: [String: String] = [:]
    ) {
        let body = Data("{}".utf8)
        let extra = additionalHeaders
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)\r\n" }
            .joined()
        let header = Data(
            "HTTP/1.1 \(status.rawValue)\r\nContent-Type: application/json\r\n"
                .appending("Cache-Control: no-store\r\n")
                .appending(extra)
                .appending("Content-Length: \(body.count)\r\nConnection: close\r\n\r\n")
                .utf8
        )
        connection.send(content: header + body, completion: .contentProcessed { _ in
            self.finish(connection)
        })
    }

    private func finish(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    private func report(_ message: String, running: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(message, running)
        }
    }
}

private final class HTTPConnectionBuffer: @unchecked Sendable {
    var data = Data()
    var hasCompletedRequest = false
    var hasStartedResponse = false
}

struct HTTPRequest {
    private static let headerSeparator = Data("\r\n\r\n".utf8)

    let method: String
    let path: String
    let version: String
    let headers: [String: String]
    let body: Data

    func header(named name: String) -> String? {
        headers[name.lowercased()]
    }

    static func parse(_ data: Data) -> HTTPRequestParseResult {
        guard let headerRange = data.range(of: headerSeparator) else {
            return data.count > OTelLiveReceiver.maximumHeaderSize
                ? .malformed(.headerTooLarge)
                : .incomplete
        }
        guard headerRange.lowerBound <= OTelLiveReceiver.maximumHeaderSize else {
            return .malformed(.headerTooLarge)
        }
        guard
            let header = String(
                data: data[..<headerRange.lowerBound],
                encoding: .utf8
            )
        else {
            return .malformed(.invalidHeaderEncoding)
        }
        let lines = header.components(separatedBy: "\r\n")
        guard
            let firstLine = lines.first,
            !firstLine.isEmpty
        else {
            return .malformed(.malformedRequestLine)
        }

        let requestLine = firstLine.split(
            separator: " ",
            omittingEmptySubsequences: true
        )
        guard
            requestLine.count == 3,
            requestLine[2] == "HTTP/1.1"
        else {
            return .malformed(.malformedRequestLine)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard
                !line.isEmpty,
                let separator = line.firstIndex(of: ":"),
                separator != line.startIndex
            else {
                return .malformed(.malformedHeader)
            }
            let rawName = String(line[..<separator])
            guard rawName.utf8.allSatisfy(isHTTPTokenByte) else {
                return .malformed(.malformedHeader)
            }
            let name = rawName.lowercased()
            guard headers[name] == nil else {
                return .malformed(.duplicateHeader)
            }
            headers[name] = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
        }

        guard headers["transfer-encoding"] == nil else {
            return .malformed(.unsupportedTransferEncoding)
        }
        guard
            let rawContentLength = headers["content-length"],
            let contentLength = Int(rawContentLength),
            contentLength >= 0
        else {
            return .malformed(.invalidContentLength)
        }
        guard contentLength <= OTelLiveReceiver.maximumBodySize else {
            return .malformed(.bodyTooLarge)
        }

        let bodyStart = headerRange.upperBound
        guard bodyStart <= data.count else {
            return .incomplete
        }
        let availableBodyBytes = data.count - bodyStart
        guard availableBodyBytes >= contentLength else {
            return .incomplete
        }
        guard availableBodyBytes == contentLength else {
            return .malformed(.unexpectedTrailingData)
        }

        return .complete(HTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            version: String(requestLine[2]),
            headers: headers,
            body: Data(data[bodyStart..<(bodyStart + contentLength)])
        ))
    }

    private static func isHTTPTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122:
            true
        case 33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
            true
        default:
            false
        }
    }
}

enum HTTPRequestParseResult {
    case incomplete
    case malformed(HTTPRequestParseError)
    case complete(HTTPRequest)
}

enum HTTPRequestParseError: Error, Equatable {
    case headerTooLarge
    case invalidHeaderEncoding
    case malformedRequestLine
    case malformedHeader
    case duplicateHeader
    case unsupportedTransferEncoding
    case invalidContentLength
    case bodyTooLarge
    case unexpectedTrailingData

    var responseStatus: HTTPResponseStatus {
        switch self {
        case .headerTooLarge:
            .requestHeaderFieldsTooLarge
        case .bodyTooLarge:
            .payloadTooLarge
        default:
            .badRequest
        }
    }
}

enum HTTPResponseStatus: String, Equatable {
    case ok = "200 OK"
    case badRequest = "400 Bad Request"
    case notFound = "404 Not Found"
    case methodNotAllowed = "405 Method Not Allowed"
    case payloadTooLarge = "413 Payload Too Large"
    case unsupportedMediaType = "415 Unsupported Media Type"
    case requestHeaderFieldsTooLarge = "431 Request Header Fields Too Large"
    case serviceUnavailable = "503 Service Unavailable"
    case insufficientStorage = "507 Insufficient Storage"
}

struct OTelHTTPOutcome {
    let status: HTTPResponseStatus
    let records: [UsageRecord]
    let additionalHeaders: [String: String]
}

enum OTelHTTPRequestProcessor {
    static func process(
        _ request: HTTPRequest,
        capabilityToken: String
    ) -> OTelHTTPOutcome {
        guard request.path == "/v1/logs" else {
            return outcome(.notFound)
        }
        guard request.method == "POST" else {
            return outcome(.methodNotAllowed, headers: ["Allow": "POST"])
        }
        guard isLoopbackHost(request.header(named: "host")) else {
            return outcome(.badRequest)
        }
        guard isJSONContentType(request.header(named: "content-type")) else {
            return outcome(.unsupportedMediaType)
        }
        guard
            let suppliedToken = request.header(named: OTelCapabilityToken.headerName),
            OTelCapabilityToken.securelyMatches(
                suppliedToken,
                expected: capabilityToken
            )
        else {
            return outcome(.notFound)
        }

        do {
            return OTelHTTPOutcome(
                status: .ok,
                records: try OTelJSONParser.records(from: request.body),
                additionalHeaders: [:]
            )
        } catch let error as OTelJSONParserError {
            switch error {
            case .limitExceeded:
                return outcome(.payloadTooLarge)
            default:
                return outcome(.badRequest)
            }
        } catch {
            return outcome(.badRequest)
        }
    }

    private static func isLoopbackHost(_ rawHost: String?) -> Bool {
        guard let host = rawHost?.lowercased() else { return false }
        return host == "127.0.0.1"
            || host == "127.0.0.1:\(OTelLiveReceiver.port.rawValue)"
    }

    private static func isJSONContentType(_ rawContentType: String?) -> Bool {
        guard let rawContentType else { return false }
        let mediaType = rawContentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType == "application/json"
    }

    private static func outcome(
        _ status: HTTPResponseStatus,
        headers: [String: String] = [:]
    ) -> OTelHTTPOutcome {
        OTelHTTPOutcome(
            status: status,
            records: [],
            additionalHeaders: headers
        )
    }
}

enum OTelJSONParser {
    static let maximumResourceLogs = 32
    static let maximumScopeLogs = 256
    static let maximumLogRecords = 2_048
    static let maximumAttributesPerEntity = 256
    static let maximumTotalAttributes = 262_144
    static let maximumStringLength = 64 * 1024
    static let maximumJSONNodes = 100_000
    static let maximumJSONDepth = 16

    private static let supportedEventNames = [
        "codex.sse_event",
        "codex.websocket_event",
    ]

    static func records(from data: Data) throws -> [UsageRecord] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OTelJSONParserError.malformedJSON
        }
        var budget = JSONValueBudget()
        try validateJSONValue(object, depth: 0, budget: &budget)

        guard
            let envelope = object as? [String: Any],
            let resourceLogs = envelope["resourceLogs"] as? [[String: Any]]
        else {
            throw OTelJSONParserError.invalidEnvelope
        }
        guard resourceLogs.count <= maximumResourceLogs else {
            throw OTelJSONParserError.limitExceeded(.resourceLogs)
        }

        var records: [UsageRecord] = []
        var scopeCount = 0
        var logRecordCount = 0
        var attributeCount = 0

        for resourceLog in resourceLogs {
            let resourceAttributes = try attributes(
                from: (resourceLog["resource"] as? [String: Any])?["attributes"],
                totalAttributeCount: &attributeCount
            )
            let scopeLogs = try objectArray(
                resourceLog["scopeLogs"],
                field: "scopeLogs"
            )
            scopeCount += scopeLogs.count
            guard scopeCount <= maximumScopeLogs else {
                throw OTelJSONParserError.limitExceeded(.scopeLogs)
            }

            for scopeLog in scopeLogs {
                let logRecords = try objectArray(
                    scopeLog["logRecords"],
                    field: "logRecords"
                )
                logRecordCount += logRecords.count
                guard logRecordCount <= maximumLogRecords else {
                    throw OTelJSONParserError.limitExceeded(.logRecords)
                }

                for logRecord in logRecords {
                    let recordAttributes = try attributes(
                        from: logRecord["attributes"],
                        totalAttributeCount: &attributeCount
                    )
                    let body = try bodyValue(from: logRecord["body"])
                    guard try isCompletedUsageEvent(
                        logRecord: logRecord,
                        resourceAttributes: resourceAttributes,
                        recordAttributes: recordAttributes,
                        body: body
                    ) else {
                        continue
                    }

                    var row = resourceAttributes
                    row.merge(recordAttributes) { _, recordValue in
                        recordValue
                    }
                    normalizeOfficialUsageAliases(in: &row)
                    copyIfPresent("timeUnixNano", from: logRecord, to: &row)
                    copyIfPresent("observedTimeUnixNano", from: logRecord, to: &row)
                    if let body {
                        row["body"] = body
                    }
                    row["source"] = "otel-live"

                    guard let record = UsageImporter.record(
                        from: row,
                        defaultSource: "otel-live"
                    ) else {
                        throw OTelJSONParserError.invalidCompletedEvent
                    }
                    records.append(record)
                    guard records.count <= maximumLogRecords else {
                        throw OTelJSONParserError.limitExceeded(.parsedRecords)
                    }
                }
            }
        }
        return records
    }

    private static func objectArray(
        _ value: Any?,
        field: String
    ) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let array = value as? [[String: Any]] else {
            throw OTelJSONParserError.invalidField(field)
        }
        return array
    }

    private static func attributes(
        from value: Any?,
        totalAttributeCount: inout Int
    ) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let attributes = value as? [[String: Any]] else {
            throw OTelJSONParserError.invalidField("attributes")
        }
        guard attributes.count <= maximumAttributesPerEntity else {
            throw OTelJSONParserError.limitExceeded(.attributesPerEntity)
        }
        totalAttributeCount += attributes.count
        guard totalAttributeCount <= maximumTotalAttributes else {
            throw OTelJSONParserError.limitExceeded(.totalAttributes)
        }

        var result: [String: Any] = [:]
        result.reserveCapacity(attributes.count)
        for attribute in attributes {
            guard
                let key = attribute["key"] as? String,
                !key.isEmpty,
                key.utf8.count <= 256,
                result[key] == nil,
                let wrapped = attribute["value"] as? [String: Any],
                let scalar = scalar(from: wrapped)
            else {
                throw OTelJSONParserError.invalidField("attribute")
            }
            if let text = scalar as? String,
               text.utf8.count > maximumStringLength
            {
                throw OTelJSONParserError.limitExceeded(.stringLength)
            }
            result[key] = scalar
        }
        return result
    }

    private static func scalar(from wrapped: [String: Any]) -> Any? {
        let supportedKeys = [
            "stringValue",
            "intValue",
            "doubleValue",
            "boolValue",
        ]
        let present = supportedKeys.compactMap { key in
            wrapped[key].map { (key, $0) }
        }
        guard present.count == 1 else { return nil }
        return present[0].1
    }

    private static func bodyValue(from value: Any?) throws -> Any? {
        guard let value else { return nil }
        guard let wrapped = value as? [String: Any] else {
            throw OTelJSONParserError.invalidField("body")
        }
        if let string = wrapped["stringValue"] as? String {
            guard string.utf8.count <= maximumStringLength else {
                throw OTelJSONParserError.limitExceeded(.stringLength)
            }
            return string
        }
        if let dictionary = wrapped["kvlistValue"] as? [String: Any],
           let values = dictionary["values"] as? [[String: Any]]
        {
            var count = 0
            return try attributes(
                from: values,
                totalAttributeCount: &count
            )
        }
        throw OTelJSONParserError.invalidField("body")
    }

    private static func isCompletedUsageEvent(
        logRecord: [String: Any],
        resourceAttributes: [String: Any],
        recordAttributes: [String: Any],
        body: Any?
    ) throws -> Bool {
        let bodyDictionary = try bodyDictionary(from: body)

        let eventName = try resolvedEventIdentity(
            primary: [
            logRecord["eventName"],
            recordAttributes["event.name"],
            recordAttributes["otel.name"],
            resourceAttributes["event.name"],
            resourceAttributes["otel.name"],
            bodyDictionary?["event.name"],
            bodyDictionary?["event_name"],
            ],
            fallback: [
                recordAttributes["name"],
                resourceAttributes["name"],
                bodyDictionary?["name"],
                body is String ? body : nil,
            ],
            field: "event.name"
        )
        let eventKind = try resolvedEventIdentity(
            primary: [
            recordAttributes["event.kind"],
            recordAttributes["event.type"],
            resourceAttributes["event.kind"],
            resourceAttributes["event.type"],
            logRecord["eventKind"],
            logRecord["eventType"],
            bodyDictionary?["event.kind"],
            bodyDictionary?["event_kind"],
            ],
            fallback: [
                recordAttributes["type"],
                resourceAttributes["type"],
                bodyDictionary?["type"],
            ],
            field: "event.kind"
        )
        return eventName.map(supportedEventNames.contains) == true
            && eventKind == "response.completed"
    }

    private static func resolvedEventIdentity(
        primary: [Any?],
        fallback: [Any?],
        field: String
    ) throws -> String? {
        func strings(from candidates: [Any?]) throws -> [String] {
            try candidates.compactMap { candidate in
                guard let candidate else { return nil }
                guard let value = candidate as? String else {
                    throw OTelJSONParserError.invalidField(field)
                }
                return value
            }
        }

        let primaryValues = try strings(from: primary)
        let values = primaryValues.isEmpty
            ? try strings(from: fallback)
            : primaryValues
        guard let first = values.first else { return nil }
        guard values.dropFirst().allSatisfy({ $0 == first }) else {
            throw OTelJSONParserError.invalidField(field)
        }
        return first
    }

    private static func bodyDictionary(
        from body: Any?
    ) throws -> [String: Any]? {
        if let dictionary = body as? [String: Any] {
            return dictionary
        }
        guard
            let text = body as? String,
            text.utf8.first(where: {
                $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D
            }) == 0x7B,
            let data = text.data(using: .utf8)
        else {
            return nil
        }
        do {
            guard
                try UsageImporter.preflightEmbeddedJSONString(
                    text,
                    maximumDepth: maximumJSONDepth,
                    maximumStructuralEntries: maximumJSONNodes
                )
            else {
                throw OTelJSONParserError.invalidField("body")
            }
        } catch let error as OTelJSONParserError {
            throw error
        } catch {
            throw OTelJSONParserError.limitExceeded(.jsonNodes)
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw OTelJSONParserError.invalidField("body")
        }
        return object
    }

    private static func normalizeOfficialUsageAliases(
        in row: inout [String: Any]
    ) {
        copyAlias("input_token_count", to: "input_tokens", in: &row)
        copyAlias("output_token_count", to: "output_tokens", in: &row)
        copyAlias("cached_token_count", to: "cached_input_tokens", in: &row)
        copyAlias(
            "cached_input_token_count",
            to: "cached_input_tokens",
            in: &row
        )
        copyAlias("cache_write_token_count", to: "cache_write_tokens", in: &row)
        copyAlias(
            "cache_write_input_token_count",
            to: "cache_write_tokens",
            in: &row
        )
        copyAlias(
            "reasoning_token_count",
            to: "reasoning_output_tokens",
            in: &row
        )
        copyAlias(
            "reasoning_output_token_count",
            to: "reasoning_output_tokens",
            in: &row
        )
        copyAlias("conversation.id", to: "thread_id", in: &row)
        copyAlias("event.timestamp", to: "timestamp", in: &row)
        if row["model"] == nil, let slug = row["slug"] {
            row["model"] = slug
        }
    }

    private static func copyAlias(
        _ source: String,
        to destination: String,
        in row: inout [String: Any]
    ) {
        if row[destination] == nil, let value = row[source] {
            row[destination] = value
        }
    }

    private static func copyIfPresent(
        _ key: String,
        from source: [String: Any],
        to destination: inout [String: Any]
    ) {
        if let value = source[key] {
            destination[key] = value
        }
    }

    private static func validateJSONValue(
        _ value: Any,
        depth: Int,
        budget: inout JSONValueBudget
    ) throws {
        guard depth <= maximumJSONDepth else {
            throw OTelJSONParserError.limitExceeded(.jsonDepth)
        }
        budget.nodes += 1
        guard budget.nodes <= maximumJSONNodes else {
            throw OTelJSONParserError.limitExceeded(.jsonNodes)
        }

        if let string = value as? String {
            guard string.utf8.count <= maximumStringLength else {
                throw OTelJSONParserError.limitExceeded(.stringLength)
            }
        } else if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                guard key.utf8.count <= 256 else {
                    throw OTelJSONParserError.limitExceeded(.stringLength)
                }
                try validateJSONValue(
                    nested,
                    depth: depth + 1,
                    budget: &budget
                )
            }
        } else if let array = value as? [Any] {
            for nested in array {
                try validateJSONValue(
                    nested,
                    depth: depth + 1,
                    budget: &budget
                )
            }
        }
    }
}

private struct JSONValueBudget {
    var nodes = 0
}

enum OTelParserLimit: String, Equatable {
    case resourceLogs
    case scopeLogs
    case logRecords
    case parsedRecords
    case attributesPerEntity
    case totalAttributes
    case stringLength
    case jsonDepth
    case jsonNodes
}

enum OTelJSONParserError: Error, Equatable {
    case malformedJSON
    case invalidEnvelope
    case invalidField(String)
    case invalidCompletedEvent
    case limitExceeded(OTelParserLimit)
}

private enum TOMLOTelConfigurationScanner {
    private enum MultilineString: Equatable {
        case none
        case basic
        case literal
    }

    static func containsOTelConfiguration(in text: String) -> Bool {
        var multilineString = MultilineString.none
        for line in text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let bytes = Array(line.utf8)
            if multilineString == .none,
               startsOTelStatement(bytes)
            {
                return true
            }
            updateMultilineStringState(
                through: bytes,
                state: &multilineString
            )
        }
        return false
    }

    private static func startsOTelStatement(_ bytes: [UInt8]) -> Bool {
        var index = 0
        skipHorizontalWhitespace(bytes, index: &index)
        guard index < bytes.count, bytes[index] != ascii("#") else {
            return false
        }

        let isTable = bytes[index] == ascii("[")
        if isTable {
            index += 1
            if index < bytes.count, bytes[index] == ascii("[") {
                index += 1
            }
            skipHorizontalWhitespace(bytes, index: &index)
        }

        guard
            let firstKey = parseKeySegment(bytes, index: &index),
            firstKey == "otel"
        else {
            return false
        }
        skipHorizontalWhitespace(bytes, index: &index)
        guard index < bytes.count else { return false }
        if isTable {
            return bytes[index] == ascii(".")
                || bytes[index] == ascii("]")
        }
        return bytes[index] == ascii(".")
            || bytes[index] == ascii("=")
    }

    private static func parseKeySegment(
        _ bytes: [UInt8],
        index: inout Int
    ) -> String? {
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case ascii("\""):
            return parseBasicQuotedKey(bytes, index: &index)
        case ascii("'"):
            return parseLiteralQuotedKey(bytes, index: &index)
        default:
            let start = index
            while
                index < bytes.count,
                isBareKeyByte(bytes[index])
            {
                index += 1
            }
            guard index > start else { return nil }
            return String(
                bytes: bytes[start..<index],
                encoding: .utf8
            )
        }
    }

    private static func parseBasicQuotedKey(
        _ bytes: [UInt8],
        index: inout Int
    ) -> String? {
        index += 1
        var decoded = ""
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == ascii("\"") {
                return decoded
            }
            if byte == ascii("\\") {
                guard index < bytes.count else { return nil }
                let escape = bytes[index]
                index += 1
                switch escape {
                case ascii("b"):
                    decoded.append("\u{0008}")
                case ascii("t"):
                    decoded.append("\t")
                case ascii("n"):
                    decoded.append("\n")
                case ascii("f"):
                    decoded.append("\u{000C}")
                case ascii("r"):
                    decoded.append("\r")
                case ascii("\""):
                    decoded.append("\"")
                case ascii("\\"):
                    decoded.append("\\")
                case ascii("u"):
                    guard
                        let scalar = parseUnicodeEscape(
                            bytes,
                            index: &index,
                            digitCount: 4
                        )
                    else {
                        return nil
                    }
                    decoded.unicodeScalars.append(scalar)
                case ascii("U"):
                    guard
                        let scalar = parseUnicodeEscape(
                            bytes,
                            index: &index,
                            digitCount: 8
                        )
                    else {
                        return nil
                    }
                    decoded.unicodeScalars.append(scalar)
                default:
                    return nil
                }
            } else {
                guard byte >= 0x20, byte < 0x80 else {
                    // A non-ASCII raw key cannot decode to the ASCII "otel".
                    return nil
                }
                decoded.unicodeScalars.append(
                    UnicodeScalar(Int(byte))!
                )
            }
        }
        return nil
    }

    private static func parseLiteralQuotedKey(
        _ bytes: [UInt8],
        index: inout Int
    ) -> String? {
        index += 1
        let start = index
        while index < bytes.count, bytes[index] != ascii("'") {
            index += 1
        }
        guard index < bytes.count else { return nil }
        let decoded = String(
            bytes: bytes[start..<index],
            encoding: .utf8
        )
        index += 1
        return decoded
    }

    private static func parseUnicodeEscape(
        _ bytes: [UInt8],
        index: inout Int,
        digitCount: Int
    ) -> UnicodeScalar? {
        guard index <= bytes.count - digitCount else { return nil }
        var value: UInt32 = 0
        for _ in 0..<digitCount {
            guard let digit = hexValue(bytes[index]) else {
                return nil
            }
            value = value * 16 + digit
            index += 1
        }
        return UnicodeScalar(value)
    }

    private static func updateMultilineStringState(
        through bytes: [UInt8],
        state: inout MultilineString
    ) {
        var index = 0
        while index < bytes.count {
            switch state {
            case .basic:
                if hasTripleQuote(
                    bytes,
                    at: index,
                    quote: ascii("\"")
                ) {
                    state = .none
                    index += 3
                } else if bytes[index] == ascii("\\") {
                    index = min(index + 2, bytes.count)
                } else {
                    index += 1
                }
            case .literal:
                if hasTripleQuote(
                    bytes,
                    at: index,
                    quote: ascii("'")
                ) {
                    state = .none
                    index += 3
                } else {
                    index += 1
                }
            case .none:
                switch bytes[index] {
                case ascii("#"):
                    return
                case ascii("\""):
                    if hasTripleQuote(
                        bytes,
                        at: index,
                        quote: ascii("\"")
                    ) {
                        state = .basic
                        index += 3
                    } else {
                        skipSingleLineBasicString(bytes, index: &index)
                    }
                case ascii("'"):
                    if hasTripleQuote(
                        bytes,
                        at: index,
                        quote: ascii("'")
                    ) {
                        state = .literal
                        index += 3
                    } else {
                        skipSingleLineLiteralString(bytes, index: &index)
                    }
                default:
                    index += 1
                }
            }
        }
    }

    private static func skipSingleLineBasicString(
        _ bytes: [UInt8],
        index: inout Int
    ) {
        index += 1
        while index < bytes.count {
            if bytes[index] == ascii("\\") {
                index = min(index + 2, bytes.count)
            } else if bytes[index] == ascii("\"") {
                index += 1
                return
            } else {
                index += 1
            }
        }
    }

    private static func skipSingleLineLiteralString(
        _ bytes: [UInt8],
        index: inout Int
    ) {
        index += 1
        while index < bytes.count {
            if bytes[index] == ascii("'") {
                index += 1
                return
            }
            index += 1
        }
    }

    private static func hasTripleQuote(
        _ bytes: [UInt8],
        at index: Int,
        quote: UInt8
    ) -> Bool {
        index <= bytes.count - 3
            && bytes[index] == quote
            && bytes[index + 1] == quote
            && bytes[index + 2] == quote
    }

    private static func skipHorizontalWhitespace(
        _ bytes: [UInt8],
        index: inout Int
    ) {
        while
            index < bytes.count,
            bytes[index] == 0x20 || bytes[index] == 0x09
        {
            index += 1
        }
    }

    private static func isBareKeyByte(_ byte: UInt8) -> Bool {
        (ascii("A")...ascii("Z")).contains(byte)
            || (ascii("a")...ascii("z")).contains(byte)
            || (ascii("0")...ascii("9")).contains(byte)
            || byte == ascii("_")
            || byte == ascii("-")
    }

    private static func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case ascii("0")...ascii("9"):
            UInt32(byte - ascii("0"))
        case ascii("a")...ascii("f"):
            UInt32(byte - ascii("a") + 10)
        case ascii("A")...ascii("F"):
            UInt32(byte - ascii("A") + 10)
        default:
            nil
        }
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }
}

enum OTelConfigManager {
    static let maximumConfigurationSize = 1024 * 1024
    private static let managedMarker =
        "# Codex Usage Lens: local token telemetry only."

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
    }

    static func block(capabilityToken: String) throws -> String {
        guard OTelCapabilityToken.isValid(capabilityToken) else {
            throw OTelConfigError.invalidCapabilityToken
        }
        return """

        # Codex Usage Lens: local token telemetry only.
        [otel]
        environment = "codex-usage-lens"
        log_user_prompt = false
        exporter = { otlp-http = { endpoint = "http://127.0.0.1:4319/v1/logs", protocol = "json", headers = { "\(OTelCapabilityToken.headerName)" = "\(capabilityToken)" } } }
        """
    }

    static func hasExistingSection() -> Bool {
        hasExistingSection(at: configURL)
    }

    static func hasExistingSection(at url: URL) -> Bool {
        guard let status = try? configurationStatus(at: url) else {
            return true
        }
        return status != .absent
    }

    static func canInstall() -> Bool {
        canInstall(at: configURL)
    }

    static func canInstall(at url: URL) -> Bool {
        guard let status = try? configurationStatus(at: url) else {
            return false
        }
        return status == .absent
    }

    static func configurationStatus(
        at url: URL
    ) throws -> OTelConfigurationStatus {
        let directory: OTelConfigDirectory
        do {
            directory = try openPinnedDirectory(
                url.deletingLastPathComponent(),
                createIfMissing: false
            )
        } catch OTelConfigError.fileAccess(let code) where code == ENOENT {
            return .absent
        }
        defer { close(directory.descriptor) }
        let filename = url.lastPathComponent
        guard isSafeFilename(filename) else {
            throw OTelConfigError.unsafeConfigurationFile
        }
        let snapshot = try readSnapshot(
            named: filename,
            in: directory.descriptor
        )
        guard let data = snapshot.data else { return .absent }
        guard let text = String(data: data, encoding: .utf8) else {
            throw OTelConfigError.invalidConfiguration
        }
        return configurationStatus(in: text)
    }

    static func configurationStatus(
        in text: String
    ) -> OTelConfigurationStatus {
        if let managedRange = managedLegacyLineRange(in: text) {
            var remainingLines = text.components(separatedBy: "\n")
            remainingLines.removeSubrange(managedRange)
            guard !containsOTelConfiguration(
                in: remainingLines.joined(separator: "\n")
            ) else {
                return .existing
            }
            return .managedLegacy
        }
        return containsOTelConfiguration(in: text) ? .existing : .absent
    }

    static func containsOTelConfiguration(in text: String) -> Bool {
        TOMLOTelConfigurationScanner.containsOTelConfiguration(in: text)
    }

    static func install(
        capabilityToken: String,
        configURL: URL = OTelConfigManager.configURL,
        beforeCommit: (() throws -> Void)? = nil,
        beforeAppend: (() throws -> Void)? = nil,
        writeLimitForTesting: Int? = nil
    ) throws {
        let block = try block(capabilityToken: capabilityToken)
        let directory = configURL.deletingLastPathComponent()
        let pinnedDirectory = try openPinnedDirectory(
            directory,
            createIfMissing: true
        )
        defer { close(pinnedDirectory.descriptor) }
        let filename = configURL.lastPathComponent
        guard isSafeFilename(filename) else {
            throw OTelConfigError.unsafeConfigurationFile
        }

        let originalSnapshot = try readSnapshot(
            named: filename,
            in: pinnedDirectory.descriptor
        )
        let existing: String
        if let originalData = originalSnapshot.data {
            guard let decoded = String(data: originalData, encoding: .utf8) else {
                throw OTelConfigError.invalidConfiguration
            }
            existing = decoded
        } else {
            existing = ""
        }
        switch configurationStatus(in: existing) {
        case .existing:
            throw OTelConfigError.existingSection
        case .managedLegacy:
            throw OTelConfigError.managedLegacyRequiresManualRemoval
        case .absent:
            break
        }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let appendData = Data((separator + block + "\n").utf8)
        guard
            appendData.count <= maximumConfigurationSize,
            originalSnapshot.data?.count ?? 0
                <= maximumConfigurationSize - appendData.count
        else {
            throw OTelConfigError.configurationTooLarge
        }
        try beforeCommit?()

        if originalSnapshot.data == nil {
            try createPrivateConfiguration(
                appendData,
                filename: filename,
                in: pinnedDirectory,
                writeLimit: writeLimitForTesting
            )
        } else {
            try appendPrivateConfiguration(
                appendData,
                filename: filename,
                originalSnapshot: originalSnapshot,
                in: pinnedDirectory,
                beforeAppend: beforeAppend,
                writeLimit: writeLimitForTesting
            )
        }
    }

    @available(*, deprecated, message: "Pass the persisted OTel capability token")
    static func install() throws {
        throw OTelConfigError.invalidCapabilityToken
    }

    private static func managedLegacyLineRange(
        in text: String
    ) -> Range<Int>? {
        let lines = text.components(separatedBy: "\n")
        let expected = [
            "[otel]",
            #"environment="codex-usage-lens""#,
            "log_user_prompt=false",
            #"exporter={otlp-http={endpoint="http://127.0.0.1:4319/v1/logs",protocol="json"}}"#,
        ]

        for markerIndex in lines.indices
        where lines[markerIndex].trimmingCharacters(in: .whitespaces)
            == managedMarker
        {
            var headerIndex = markerIndex + 1
            while headerIndex < lines.count,
                  lines[headerIndex]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            {
                headerIndex += 1
            }
            guard headerIndex < lines.count else { continue }

            var endIndex = headerIndex + 1
            while endIndex < lines.count {
                let trimmed = lines[endIndex]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("[") {
                    break
                }
                endIndex += 1
            }

            let significant = lines[headerIndex..<endIndex]
                .map(removingUnquotedWhitespace)
                .filter { !$0.isEmpty }
            if significant == expected {
                return markerIndex..<endIndex
            }
        }
        return nil
    }

    private static func removingUnquotedWhitespace(
        from line: String
    ) -> String {
        var result = ""
        var quote: Character?
        var escaped = false

        for character in line {
            if let currentQuote = quote {
                result.append(character)
                if currentQuote == "\"", character == "\\", !escaped {
                    escaped = true
                } else {
                    if character == currentQuote, !escaped {
                        quote = nil
                    }
                    escaped = false
                }
            } else if character == "\"" || character == "'" {
                quote = character
                result.append(character)
            } else if !character.isWhitespace {
                result.append(character)
            }
        }
        return result
    }

    private static func openPinnedDirectory(
        _ url: URL,
        createIfMissing: Bool
    ) throws -> OTelConfigDirectory {
        let descriptor: Int32
        do {
            descriptor = if createIfMissing {
                try DescriptorDirectory.openOrCreate(at: url)
            } else {
                try DescriptorDirectory.openExisting(at: url)
            }
        } catch DescriptorDirectoryError.invalidAbsolutePath {
            throw OTelConfigError.unsafeConfigurationFile
        } catch DescriptorDirectoryError.unsafeComponent {
            throw OTelConfigError.unsafeConfigurationFile
        } catch DescriptorDirectoryError.missing {
            throw OTelConfigError.fileAccess(ENOENT)
        } catch DescriptorDirectoryError.posix(let code) {
            throw OTelConfigError.fileAccess(code)
        }

        var openedInfo = stat()
        guard
            fstat(descriptor, &openedInfo) == 0,
            openedInfo.st_mode & S_IFMT == S_IFDIR
        else {
            close(descriptor)
            throw OTelConfigError.concurrentModification
        }

        return OTelConfigDirectory(
            descriptor: descriptor,
            url: url,
            device: UInt64(openedInfo.st_dev),
            inode: UInt64(openedInfo.st_ino)
        )
    }

    private static func isSafeFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename != "."
            && filename != ".."
            && !filename.contains("/")
            && !filename.contains("\0")
    }

    private static func readSnapshot(
        named filename: String,
        in directoryDescriptor: Int32
    ) throws -> OTelConfigFileSnapshot {
        let descriptor = openat(
            directoryDescriptor,
            filename,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return .missing
            }
            if errno == ELOOP {
                throw OTelConfigError.unsafeConfigurationFile
            }
            throw OTelConfigError.fileAccess(errno)
        }
        defer { close(descriptor) }

        let snapshot = try snapshot(
            from: descriptor,
            dataRequired: true
        )
        guard try pathMatches(
            snapshot,
            filename: filename,
            directoryDescriptor: directoryDescriptor
        ) else {
            throw OTelConfigError.concurrentModification
        }
        return snapshot
    }

    private static func snapshot(
        from descriptor: Int32,
        dataRequired: Bool
    ) throws -> OTelConfigFileSnapshot {
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0 else {
            throw OTelConfigError.fileAccess(errno)
        }
        guard
            openedInfo.st_mode & S_IFMT == S_IFREG,
            openedInfo.st_nlink == 1,
            openedInfo.st_size >= 0
        else {
            throw OTelConfigError.unsafeConfigurationFile
        }
        guard openedInfo.st_size <= maximumConfigurationSize else {
            throw OTelConfigError.configurationTooLarge
        }

        var data: Data?
        if dataRequired {
            let handle = FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: false
            )
            var collected = Data()
            while true {
                let readLimit = min(
                    64 * 1024,
                    maximumConfigurationSize + 1 - collected.count
                )
                guard readLimit > 0 else {
                    throw OTelConfigError.configurationTooLarge
                }
                guard
                    let chunk = try handle.read(upToCount: readLimit),
                    !chunk.isEmpty
                else {
                    break
                }
                collected.append(chunk)
                guard collected.count <= maximumConfigurationSize else {
                    throw OTelConfigError.configurationTooLarge
                }
            }
            data = collected
        }

        var completedInfo = stat()
        guard
            fstat(descriptor, &completedInfo) == 0,
            completedInfo.st_mode & S_IFMT == S_IFREG,
            completedInfo.st_nlink == 1,
            completedInfo.st_dev == openedInfo.st_dev,
            completedInfo.st_ino == openedInfo.st_ino,
            completedInfo.st_size == openedInfo.st_size,
            completedInfo.st_mtimespec.tv_sec
                == openedInfo.st_mtimespec.tv_sec,
            completedInfo.st_mtimespec.tv_nsec
                == openedInfo.st_mtimespec.tv_nsec
        else {
            throw OTelConfigError.concurrentModification
        }
        return OTelConfigFileSnapshot(
            data: data,
            device: UInt64(completedInfo.st_dev),
            inode: UInt64(completedInfo.st_ino),
            byteCount: Int64(completedInfo.st_size),
            linkCount: UInt64(completedInfo.st_nlink),
            modificationSeconds: Int64(completedInfo.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(completedInfo.st_mtimespec.tv_nsec)
        )
    }

    private static func createPrivateConfiguration(
        _ data: Data,
        filename: String,
        in directory: OTelConfigDirectory,
        writeLimit: Int?
    ) throws {
        let descriptor = openat(
            directory.descriptor,
            filename,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == EEXIST || errno == ELOOP {
                throw OTelConfigError.concurrentModification
            }
            throw OTelConfigError.fileAccess(errno)
        }
        defer { close(descriptor) }

        var openedInfo = stat()
        guard
            fstat(descriptor, &openedInfo) == 0,
            openedInfo.st_mode & S_IFMT == S_IFREG,
            openedInfo.st_nlink == 1
        else {
            throw OTelConfigError.unsafeConfigurationFile
        }
        do {
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw OTelConfigError.fileAccess(errno)
            }
            let written = try writeSingleAppend(
                data,
                to: descriptor,
                writeLimit: writeLimit
            )
            guard written == data.count else {
                throw OTelConfigError.fileAccess(EIO)
            }
            guard fsync(descriptor) == 0 else {
                throw OTelConfigError.fileAccess(errno)
            }

            let candidate = try snapshot(
                from: descriptor,
                dataRequired: false
            )
            guard
                candidate.byteCount == Int64(data.count),
                try pathMatches(
                    candidate,
                    filename: filename,
                    directoryDescriptor: directory.descriptor
                ),
                directoryPathMatches(directory)
            else {
                throw OTelConfigError.concurrentModification
            }
            guard fsync(directory.descriptor) == 0 else {
                throw OTelConfigError.fileAccess(errno)
            }
        } catch {
            let originalError = error
            try removeCreatedConfiguration(
                descriptor: descriptor,
                metadata: openedInfo,
                filename: filename,
                in: directory
            )
            throw originalError
        }
    }

    private static func appendPrivateConfiguration(
        _ data: Data,
        filename: String,
        originalSnapshot: OTelConfigFileSnapshot,
        in directory: OTelConfigDirectory,
        beforeAppend: (() throws -> Void)?,
        writeLimit: Int?
    ) throws {
        let descriptor = openat(
            directory.descriptor,
            filename,
            O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw OTelConfigError.concurrentModification
            }
            if errno == ELOOP {
                throw OTelConfigError.unsafeConfigurationFile
            }
            throw OTelConfigError.fileAccess(errno)
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw OTelConfigError.concurrentModification
            }
            throw OTelConfigError.fileAccess(errno)
        }
        guard try configurationStillMatches(
            originalSnapshot,
            descriptor: descriptor,
            filename: filename,
            directory: directory
        ) else {
            throw OTelConfigError.concurrentModification
        }

        try beforeAppend?()
        guard try configurationStillMatches(
            originalSnapshot,
            descriptor: descriptor,
            filename: filename,
            directory: directory
        ) else {
            throw OTelConfigError.concurrentModification
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw OTelConfigError.fileAccess(errno)
        }

        let written = try writeSingleAppend(
            data,
            to: descriptor,
            writeLimit: writeLimit
        )
        guard written == data.count else {
            try rollbackPartialAppend(
                writtenByteCount: written,
                descriptor: descriptor,
                filename: filename,
                originalSnapshot: originalSnapshot,
                in: directory
            )
            throw OTelConfigError.fileAccess(EIO)
        }
        guard fsync(descriptor) == 0 else {
            throw OTelConfigError.fileAccess(errno)
        }

        let completed = try snapshot(
            from: descriptor,
            dataRequired: false
        )
        guard
            let originalByteCount = originalSnapshot.byteCount,
            originalByteCount <= Int64.max - Int64(data.count),
            completed.byteCount == originalByteCount + Int64(data.count),
            try pathMatches(
                completed,
                filename: filename,
                directoryDescriptor: directory.descriptor
            ),
            directoryPathMatches(directory)
        else {
            throw OTelConfigError.concurrentModification
        }
    }

    private static func rollbackPartialAppend(
        writtenByteCount: Int,
        descriptor: Int32,
        filename: String,
        originalSnapshot: OTelConfigFileSnapshot,
        in directory: OTelConfigDirectory
    ) throws {
        guard
            writtenByteCount >= 0,
            let device = originalSnapshot.device,
            let inode = originalSnapshot.inode,
            let originalByteCount = originalSnapshot.byteCount,
            originalByteCount <= Int64.max - Int64(writtenByteCount)
        else {
            throw OTelConfigError.concurrentModification
        }
        var info = stat()
        guard
            fstat(descriptor, &info) == 0,
            info.st_mode & S_IFMT == S_IFREG,
            info.st_nlink == 1,
            UInt64(info.st_dev) == device,
            UInt64(info.st_ino) == inode,
            Int64(info.st_size)
                == originalByteCount + Int64(writtenByteCount),
            try pathIdentityMatches(
                device: device,
                inode: inode,
                filename: filename,
                directoryDescriptor: directory.descriptor
            ),
            directoryPathMatches(directory)
        else {
            throw OTelConfigError.concurrentModification
        }
        guard ftruncate(descriptor, off_t(originalByteCount)) == 0 else {
            throw OTelConfigError.fileAccess(errno)
        }
        guard fsync(descriptor) == 0 else {
            throw OTelConfigError.fileAccess(errno)
        }

        var restored = stat()
        guard
            fstat(descriptor, &restored) == 0,
            restored.st_mode & S_IFMT == S_IFREG,
            restored.st_nlink == 1,
            UInt64(restored.st_dev) == device,
            UInt64(restored.st_ino) == inode,
            Int64(restored.st_size) == originalByteCount,
            try pathIdentityMatches(
                device: device,
                inode: inode,
                filename: filename,
                directoryDescriptor: directory.descriptor
            ),
            directoryPathMatches(directory)
        else {
            throw OTelConfigError.concurrentModification
        }
    }

    private static func removeCreatedConfiguration(
        descriptor: Int32,
        metadata: stat,
        filename: String,
        in directory: OTelConfigDirectory
    ) throws {
        let device = UInt64(metadata.st_dev)
        let inode = UInt64(metadata.st_ino)
        var openedInfo = stat()
        guard
            fstat(descriptor, &openedInfo) == 0,
            openedInfo.st_mode & S_IFMT == S_IFREG,
            openedInfo.st_nlink == 1,
            UInt64(openedInfo.st_dev) == device,
            UInt64(openedInfo.st_ino) == inode,
            try pathIdentityMatches(
                device: device,
                inode: inode,
                filename: filename,
                directoryDescriptor: directory.descriptor
            ),
            directoryPathMatches(directory)
        else {
            throw OTelConfigError.concurrentModification
        }
        guard unlinkat(directory.descriptor, filename, 0) == 0 else {
            throw OTelConfigError.fileAccess(errno)
        }
        guard fsync(directory.descriptor) == 0 else {
            throw OTelConfigError.fileAccess(errno)
        }
    }

    private static func configurationStillMatches(
        _ snapshot: OTelConfigFileSnapshot,
        descriptor: Int32,
        filename: String,
        directory: OTelConfigDirectory
    ) throws -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw OTelConfigError.fileAccess(errno)
        }
        guard metadata(info, matches: snapshot) else {
            return false
        }
        guard try pathMatches(
            snapshot,
            filename: filename,
            directoryDescriptor: directory.descriptor
        ) else {
            return false
        }
        return directoryPathMatches(directory)
    }

    private static func metadata(
        _ info: stat,
        matches snapshot: OTelConfigFileSnapshot
    ) -> Bool {
        info.st_mode & S_IFMT == S_IFREG
            && info.st_nlink == 1
            && UInt64(info.st_dev) == snapshot.device
            && UInt64(info.st_ino) == snapshot.inode
            && Int64(info.st_size) == snapshot.byteCount
            && UInt64(info.st_nlink) == snapshot.linkCount
            && Int64(info.st_mtimespec.tv_sec)
                == snapshot.modificationSeconds
            && Int64(info.st_mtimespec.tv_nsec)
                == snapshot.modificationNanoseconds
    }

    private static func pathMatches(
        _ snapshot: OTelConfigFileSnapshot,
        filename: String,
        directoryDescriptor: Int32
    ) throws -> Bool {
        var info = stat()
        guard
            fstatat(
                directoryDescriptor,
                filename,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        else {
            if errno == ENOENT {
                return false
            }
            throw OTelConfigError.fileAccess(errno)
        }
        return metadata(info, matches: snapshot)
    }

    private static func pathIdentityMatches(
        device: UInt64,
        inode: UInt64,
        filename: String,
        directoryDescriptor: Int32
    ) throws -> Bool {
        var info = stat()
        guard
            fstatat(
                directoryDescriptor,
                filename,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        else {
            if errno == ENOENT {
                return false
            }
            throw OTelConfigError.fileAccess(errno)
        }
        return info.st_mode & S_IFMT == S_IFREG
            && info.st_nlink == 1
            && UInt64(info.st_dev) == device
            && UInt64(info.st_ino) == inode
    }

    private static func directoryPathMatches(
        _ directory: OTelConfigDirectory
    ) -> Bool {
        var info = stat()
        guard
            directory.url.path.withCString({ lstat($0, &info) }) == 0,
            info.st_mode & S_IFMT == S_IFDIR
        else {
            return false
        }
        return UInt64(info.st_dev) == directory.device
            && UInt64(info.st_ino) == directory.inode
    }

    private static func writeSingleAppend(
        _ data: Data,
        to descriptor: Int32,
        writeLimit: Int?
    ) throws -> Int {
        let written: Int = data.withUnsafeBytes { buffer in
            let requestedByteCount = min(
                buffer.count,
                max(0, writeLimit ?? buffer.count)
            )
            while true {
                let result = Darwin.write(
                    descriptor,
                    buffer.baseAddress,
                    requestedByteCount
                )
                if result < 0, errno == EINTR {
                    continue
                }
                return result
            }
        }
        guard written >= 0 else {
            throw OTelConfigError.fileAccess(errno)
        }
        return written
    }
}

enum OTelConfigurationStatus: Equatable {
    case absent
    case managedLegacy
    case existing
}

private struct OTelConfigFileSnapshot: Equatable {
    let data: Data?
    let device: UInt64?
    let inode: UInt64?
    let byteCount: Int64?
    let linkCount: UInt64?
    let modificationSeconds: Int64?
    let modificationNanoseconds: Int64?

    static let missing = OTelConfigFileSnapshot(
        data: nil,
        device: nil,
        inode: nil,
        byteCount: nil,
        linkCount: nil,
        modificationSeconds: nil,
        modificationNanoseconds: nil
    )
}

private struct OTelConfigDirectory {
    let descriptor: Int32
    let url: URL
    let device: UInt64
    let inode: UInt64
}

enum OTelConfigError: LocalizedError, Equatable {
    case existingSection
    case managedLegacyRequiresManualRemoval
    case concurrentModification
    case invalidCapabilityToken
    case invalidConfiguration
    case unsafeConfigurationFile
    case configurationTooLarge
    case fileAccess(Int32)

    var errorDescription: String? {
        switch self {
        case .existingSection:
            "В ~/.codex/config.toml уже есть [otel]. Приложение не перезаписывает его автоматически."
        case .managedLegacyRequiresManualRemoval:
            "В ~/.codex/config.toml найден прежний блок Codex Usage Lens. Удалите его вручную, затем добавьте защищённую OTel-настройку снова."
        case .concurrentModification:
            "~/.codex/config.toml изменился во время установки; изменения не записаны."
        case .invalidCapabilityToken:
            "Некорректный capability token для Live OTel."
        case .invalidConfiguration:
            "~/.codex/config.toml не является корректным UTF-8 файлом."
        case .unsafeConfigurationFile:
            "~/.codex/config.toml или его каталог является ссылкой либо не обычным файлом."
        case .configurationTooLarge:
            "~/.codex/config.toml превышает безопасный лимит размера."
        case .fileAccess(let code):
            "Не удалось безопасно обновить ~/.codex/config.toml (errno \(code))."
        }
    }
}
