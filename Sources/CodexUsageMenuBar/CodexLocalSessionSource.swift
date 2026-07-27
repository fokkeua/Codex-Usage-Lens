import Darwin
import Foundation

enum CodexLocalSessionSource {
    private static let readChunkSize = 128 * 1024
    static let modificationDateOverlap: TimeInterval = 2
    private static let typeMemberName = Array("type".utf8)
    private static let tokenCountType = Array("token_count".utf8)
    private static let turnContextType = Array("turn_context".utf8)
    private static let threadSettingsAppliedType =
        Array("thread_settings_applied".utf8)

    private enum JSONStringTargetSet: Equatable {
        case typeMemberName
        case relevantTypeValue
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    static func scan(
        root: URL = defaultRoot,
        modifiedAfter: Date? = nil
    ) throws -> LocalScanResult {
        try validateRoot(root)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw LocalSessionError.sessionsNotFound
        }

        var files: [URL] = []
        var enumeratedEntries = 0
        var declaredBytes = 0
        for case let url as URL in enumerator {
            enumeratedEntries = UsageLimits.saturatingAdd(enumeratedEntries, 1)
            guard enumeratedEntries <= UsageLimits.maximumSessionEntries else {
                throw LocalSessionError.tooManyEntries(
                    maximum: UsageLimits.maximumSessionEntries
                )
            }
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            guard
                let values = try? url.resourceValues(
                    forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey,
                        .contentModificationDateKey,
                    ]
                ),
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else {
                continue
            }
            if let modifiedAfter {
                let inclusiveThreshold = modifiedAfter.addingTimeInterval(
                    -modificationDateOverlap
                )
                if
                    let modified = values.contentModificationDate,
                    modified < inclusiveThreshold
                {
                    continue
                }
            }
            guard files.count < UsageLimits.maximumSessionFiles else {
                throw LocalSessionError.tooManyFiles(
                    maximum: UsageLimits.maximumSessionFiles
                )
            }
            if let fileSize = values.fileSize {
                declaredBytes = UsageLimits.saturatingAdd(
                    declaredBytes,
                    fileSize
                )
                guard
                    declaredBytes <= UsageLimits.maximumSessionAggregateBytes
                else {
                    throw LocalSessionError.aggregateTooLarge(
                        maximumBytes:
                            UsageLimits.maximumSessionAggregateBytes
                    )
                }
            }
            files.append(url)
        }
        return try scan(files: files.sorted { $0.path < $1.path })
    }

    static func scan(files: [URL]) throws -> LocalScanResult {
        guard files.count <= UsageLimits.maximumSessionFiles else {
            throw LocalSessionError.tooManyFiles(
                maximum: UsageLimits.maximumSessionFiles
            )
        }
        var records: [UsageRecord] = []
        var tokenEvents = 0
        var missingModel = 0
        var malformedLines = 0
        var filesScanned = 0
        var aggregateBytes = 0

        for file in files {
            var currentModel: String?
            var currentServiceTier = "default"

            let wasScanned = try forEachLine(
                in: file,
                aggregateBytes: &aggregateBytes,
                onOversizedLine: {
                    malformedLines = UsageLimits.saturatingAdd(
                        malformedLines,
                        1
                    )
                }
            ) { line in
                guard isRelevant(line) else { return }
                try autoreleasepool {
                    guard
                        let object = try? JSONSerialization.jsonObject(with: line),
                        let event = object as? [String: Any],
                        let type = event["type"] as? String,
                        let payload = event["payload"] as? [String: Any]
                    else {
                        malformedLines = UsageLimits.saturatingAdd(
                            malformedLines,
                            1
                        )
                        return
                    }

                    switch type {
                    case "turn_context":
                        currentModel = nil
                        currentServiceTier = "default"
                        if let rawModel = payload["model"] {
                            if
                                let model = rawModel as? String,
                                let bounded = UsageLimits.boundedString(
                                model,
                                maximumUTF8Bytes:
                                    UsageLimits.maximumModelBytes
                                ),
                                !bounded.isEmpty
                            {
                                currentModel = bounded
                            } else {
                                malformedLines = UsageLimits.saturatingAdd(
                                    malformedLines,
                                    1
                                )
                            }
                        }
                        if let rawTier = payload["service_tier"] {
                            if
                                let tier = rawTier as? String,
                                let bounded = UsageLimits.boundedString(
                                    tier,
                                    maximumUTF8Bytes:
                                        UsageLimits.maximumServiceTierBytes
                                ),
                                !bounded.isEmpty
                            {
                                currentServiceTier = bounded
                            } else {
                                malformedLines = UsageLimits.saturatingAdd(
                                    malformedLines,
                                    1
                                )
                            }
                        }
                    case "event_msg":
                        guard let eventType = payload["type"] as? String else { return }
                        if eventType == "thread_settings_applied" {
                            if let settings = payload["thread_settings"] as? [String: Any] {
                                if
                                    let model = settings["model"] as? String,
                                    let bounded = UsageLimits.boundedString(
                                        model,
                                        maximumUTF8Bytes:
                                            UsageLimits.maximumModelBytes
                                    )
                                {
                                    currentModel = bounded
                                }
                                if
                                    let tier =
                                        settings["service_tier"] as? String,
                                    let bounded = UsageLimits.boundedString(
                                        tier,
                                        maximumUTF8Bytes:
                                            UsageLimits
                                                .maximumServiceTierBytes
                                    )
                                {
                                    currentServiceTier = bounded
                                }
                            }
                            return
                        }
                        guard
                            eventType == "token_count",
                            let info = payload["info"] as? [String: Any],
                            let usage = info["last_token_usage"] as? [String: Any],
                            let rawTimestamp = event["timestamp"] as? String,
                            let timestamp = DateParsing.parse(rawTimestamp),
                            UsageLimits.isPlausibleTimestamp(timestamp)
                        else {
                            return
                        }

                        guard
                            records.count < UsageLimits.maximumRetainedRecords
                        else {
                            throw LocalSessionError.tooManyRecords(
                                maximum: UsageLimits.maximumRetainedRecords
                            )
                        }
                        tokenEvents = UsageLimits.saturatingAdd(tokenEvents, 1)
                        guard
                            let input = integer(usage["input_tokens"]),
                            let cachedValue = integer(
                                usage["cached_input_tokens"]
                            ),
                            let cacheWriteValue = integer(
                                usage["cache_write_input_tokens"]
                            ),
                            let output = integer(usage["output_tokens"]),
                            let reasoning = integer(
                                usage["reasoning_output_tokens"]
                            )
                        else {
                            malformedLines = UsageLimits.saturatingAdd(
                                malformedLines,
                                1
                            )
                            return
                        }
                        if currentModel == nil {
                            missingModel = UsageLimits.saturatingAdd(
                                missingModel,
                                1
                            )
                        }
                        let cached = min(cachedValue, input)
                        let cacheWrite = min(
                            cacheWriteValue,
                            max(0, input - cached)
                        )

                        records.append(
                            UsageRecord(
                                timestamp: timestamp,
                                model: currentModel ?? "unknown",
                                inputTokens: input,
                                cachedInputTokens: cached,
                                cacheWriteTokens: cacheWrite,
                                outputTokens: output,
                                source: "codex-local-rollout",
                                reasoningOutputTokens: reasoning,
                                serviceTier: currentServiceTier
                            )
                        )
                    default:
                        return
                    }
                }
            }
            if wasScanned {
                filesScanned = UsageLimits.saturatingAdd(filesScanned, 1)
            }
        }

        // Fork/import flows can reuse a rollout prefix. Exact usage signatures
        // identify those repeats without reading prompts or message bodies.
        var signatures = Set<UsageRecordSignature>()
        let unique = records.filter { signatures.insert($0.exactUsageSignature).inserted }

        return LocalScanResult(
            records: unique.sorted { $0.timestamp > $1.timestamp },
            filesScanned: filesScanned,
            tokenEvents: tokenEvents,
            duplicatesRemoved: records.count - unique.count,
            missingModel: missingModel,
            malformedLines: malformedLines
        )
    }

    private static func isRelevant(_ line: Data) -> Bool {
        var cursor = line.startIndex

        while cursor < line.endIndex {
            guard line[cursor] == 0x22 else {
                cursor = line.index(after: cursor)
                continue
            }
            guard
                let memberName = scanJSONString(
                    in: line,
                    startingAt: cursor,
                    matching: .typeMemberName
                )
            else {
                return false
            }

            var separator = skippingJSONWhitespace(
                in: line,
                startingAt: memberName.endIndex
            )
            guard
                memberName.matchedTargetIndex == 0,
                separator < line.endIndex,
                line[separator] == 0x3A
            else {
                cursor = memberName.endIndex
                continue
            }

            separator = line.index(after: separator)
            let valueStart = skippingJSONWhitespace(
                in: line,
                startingAt: separator
            )
            guard valueStart < line.endIndex, line[valueStart] == 0x22 else {
                cursor = valueStart
                continue
            }
            guard
                let value = scanJSONString(
                    in: line,
                    startingAt: valueStart,
                    matching: .relevantTypeValue
                )
            else {
                return false
            }
            if value.matchedTargetIndex != nil {
                return true
            }
            cursor = value.endIndex
        }

        return false
    }

    private static func scanJSONString(
        in data: Data,
        startingAt openingQuote: Data.Index,
        matching targetSet: JSONStringTargetSet
    ) -> (endIndex: Data.Index, matchedTargetIndex: Int?)? {
        guard data[openingQuote] == 0x22 else { return nil }

        var candidates: UInt8 = targetSet == .typeMemberName ? 0b0001 : 0b0111
        var decodedByteIndex = 0
        var cursor = data.index(after: openingQuote)

        func consumeDecodedByte(_ byte: UInt8?) {
            updateJSONStringCandidates(
                byte,
                at: decodedByteIndex,
                targetSet: targetSet,
                candidates: &candidates
            )
            decodedByteIndex = UsageLimits.saturatingAdd(decodedByteIndex, 1)
        }

        while cursor < data.endIndex {
            let byte = data[cursor]
            cursor = data.index(after: cursor)

            if byte == 0x22 {
                let matchedTargetIndex = matchedJSONStringTarget(
                    targetSet,
                    candidates: candidates,
                    decodedByteCount: decodedByteIndex
                )
                return (cursor, matchedTargetIndex)
            }
            guard byte >= 0x20 else { return nil }
            guard byte == 0x5C else {
                consumeDecodedByte(byte < 0x80 ? byte : nil)
                continue
            }
            guard cursor < data.endIndex else { return nil }

            let escape = data[cursor]
            cursor = data.index(after: cursor)
            switch escape {
            case 0x22, 0x5C, 0x2F:
                consumeDecodedByte(escape)
            case 0x62:
                consumeDecodedByte(0x08)
            case 0x66:
                consumeDecodedByte(0x0C)
            case 0x6E:
                consumeDecodedByte(0x0A)
            case 0x72:
                consumeDecodedByte(0x0D)
            case 0x74:
                consumeDecodedByte(0x09)
            case 0x75:
                var scalar: UInt32 = 0
                for _ in 0..<4 {
                    guard
                        cursor < data.endIndex,
                        let digit = hexadecimalValue(data[cursor])
                    else {
                        return nil
                    }
                    scalar = scalar * 16 + digit
                    cursor = data.index(after: cursor)
                }
                consumeDecodedByte(
                    scalar <= UInt32(UInt8.max) ? UInt8(scalar) : nil
                )
            default:
                return nil
            }
        }

        return nil
    }

    private static func updateJSONStringCandidates(
        _ byte: UInt8?,
        at decodedByteIndex: Int,
        targetSet: JSONStringTargetSet,
        candidates: inout UInt8
    ) {
        guard let byte else {
            candidates = 0
            return
        }

        switch targetSet {
        case .typeMemberName:
            if
                decodedByteIndex >= typeMemberName.count
                    || typeMemberName[decodedByteIndex] != byte
            {
                candidates = 0
            }
        case .relevantTypeValue:
            if
                candidates & 0b0001 != 0,
                decodedByteIndex >= tokenCountType.count
                    || tokenCountType[decodedByteIndex] != byte
            {
                candidates &= ~0b0001
            }
            if
                candidates & 0b0010 != 0,
                decodedByteIndex >= turnContextType.count
                    || turnContextType[decodedByteIndex] != byte
            {
                candidates &= ~0b0010
            }
            if
                candidates & 0b0100 != 0,
                decodedByteIndex >= threadSettingsAppliedType.count
                    || threadSettingsAppliedType[decodedByteIndex] != byte
            {
                candidates &= ~0b0100
            }
        }
    }

    private static func matchedJSONStringTarget(
        _ targetSet: JSONStringTargetSet,
        candidates: UInt8,
        decodedByteCount: Int
    ) -> Int? {
        switch targetSet {
        case .typeMemberName:
            return
                candidates & 0b0001 != 0
                    && decodedByteCount == typeMemberName.count
                ? 0 : nil
        case .relevantTypeValue:
            if
                candidates & 0b0001 != 0,
                decodedByteCount == tokenCountType.count
            {
                return 0
            }
            if
                candidates & 0b0010 != 0,
                decodedByteCount == turnContextType.count
            {
                return 1
            }
            if
                candidates & 0b0100 != 0,
                decodedByteCount == threadSettingsAppliedType.count
            {
                return 2
            }
            return nil
        }
    }

    private static func skippingJSONWhitespace(
        in data: Data,
        startingAt start: Data.Index
    ) -> Data.Index {
        var cursor = start
        while cursor < data.endIndex {
            switch data[cursor] {
            case 0x20, 0x09, 0x0A, 0x0D:
                cursor = data.index(after: cursor)
            default:
                return cursor
            }
        }
        return cursor
    }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39:
            UInt32(byte - 0x30)
        case 0x41...0x46:
            UInt32(byte - 0x41 + 10)
        case 0x61...0x66:
            UInt32(byte - 0x61 + 10)
        default:
            nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value else { return 0 }
        return StrictIntegerDecoding.value(
            from: value,
            in: 0...UsageLimits.maximumTokenCount,
            allowNumericString: true
        )
    }

    private static func forEachLine(
        in url: URL,
        aggregateBytes: inout Int,
        onOversizedLine: () -> Void,
        body: (Data) throws -> Void
    ) throws -> Bool {
        guard let opened = openRegularFileWithoutFollowingLinks(url) else {
            return false
        }
        let handle = opened.handle
        defer { try? handle.close() }
        guard
            opened.byteCount <= UsageLimits.maximumSessionAggregateBytes
                - aggregateBytes
        else {
            throw LocalSessionError.aggregateTooLarge(
                maximumBytes: UsageLimits.maximumSessionAggregateBytes
            )
        }
        var buffer = Data()
        var isSkippingOversizedLine = false

        while let chunk = try handle.read(upToCount: readChunkSize), !chunk.isEmpty {
            aggregateBytes = UsageLimits.saturatingAdd(
                aggregateBytes,
                chunk.count
            )
            guard
                aggregateBytes <= UsageLimits.maximumSessionAggregateBytes
            else {
                throw LocalSessionError.aggregateTooLarge(
                    maximumBytes: UsageLimits.maximumSessionAggregateBytes
                )
            }

            var unreadChunk = chunk[chunk.startIndex..<chunk.endIndex]
            if isSkippingOversizedLine {
                guard let newline = unreadChunk.firstIndex(of: 0x0A) else {
                    continue
                }
                isSkippingOversizedLine = false
                unreadChunk = unreadChunk[
                    unreadChunk.index(after: newline)..<unreadChunk.endIndex
                ]
            }

            let previouslyScannedCount = buffer.count
            buffer.append(contentsOf: unreadChunk)

            var lineStart = buffer.startIndex
            var searchStart = buffer.index(
                buffer.startIndex,
                offsetBy: previouslyScannedCount
            )
            while let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
                let line = buffer[lineStart..<newline]
                if line.count <= UsageLimits.maximumLogicalLineBytes {
                    try body(line)
                } else {
                    onOversizedLine()
                }
                lineStart = buffer.index(after: newline)
                searchStart = lineStart
            }

            let unfinishedLineBytes = buffer.distance(
                from: lineStart,
                to: buffer.endIndex
            )
            if unfinishedLineBytes > UsageLimits.maximumLogicalLineBytes {
                onOversizedLine()
                isSkippingOversizedLine = true
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            if lineStart != buffer.startIndex {
                if lineStart == buffer.endIndex {
                    buffer.removeAll(keepingCapacity: true)
                } else if buffer.count > UsageLimits.maximumLogicalLineBytes {
                    buffer = Data(buffer[lineStart...])
                } else {
                    buffer.removeSubrange(buffer.startIndex..<lineStart)
                }
            }
        }

        if !isSkippingOversizedLine, !buffer.isEmpty {
            try body(buffer)
        }
        return true
    }

    private static func openRegularFileWithoutFollowingLinks(
        _ url: URL
    ) -> (handle: FileHandle, byteCount: Int)? {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }

        var metadata = stat()
        guard
            Darwin.fstat(descriptor, &metadata) == 0,
            (metadata.st_mode & S_IFMT) == S_IFREG,
            metadata.st_size >= 0
        else {
            Darwin.close(descriptor)
            return nil
        }

        return (
            FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            Int(metadata.st_size)
        )
    }

    private static func validateRoot(_ url: URL) throws {
        var metadata = stat()
        let status = url.path.withCString {
            Darwin.lstat($0, &metadata)
        }
        guard status == 0 else {
            throw LocalSessionError.sessionsNotFound
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw LocalSessionError.unsafeRoot
        }
    }
}

enum LocalSessionError: LocalizedError {
    case sessionsNotFound
    case unsafeRoot
    case tooManyEntries(maximum: Int)
    case tooManyFiles(maximum: Int)
    case aggregateTooLarge(maximumBytes: Int)
    case lineTooLong(maximumBytes: Int)
    case tooManyRecords(maximum: Int)

    var errorDescription: String? {
        switch self {
        case .sessionsNotFound:
            "Папка ~/.codex/sessions не найдена."
        case .unsafeRoot:
            "Корень session history должен быть обычным каталогом, не symbolic link."
        case .tooManyEntries(let maximum):
            "Каталог session history содержит больше \(maximum) элементов."
        case .tooManyFiles(let maximum):
            "Локальная история содержит больше \(maximum) файлов."
        case .aggregateTooLarge(let maximumBytes):
            "Локальная история превышает предел \(maximumBytes) байт."
        case .lineTooLong(let maximumBytes):
            "Строка session JSONL превышает предел \(maximumBytes) байт."
        case .tooManyRecords(let maximum):
            "Локальная история содержит больше \(maximum) записей."
        }
    }
}
