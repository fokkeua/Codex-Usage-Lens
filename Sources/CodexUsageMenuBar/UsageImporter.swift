import Darwin
import CoreFoundation
import Foundation

enum StrictIntegerDecoding {
    static func value(
        from rawValue: Any,
        in allowedRange: ClosedRange<Int>,
        allowNumericString: Bool
    ) -> Int? {
        if let value = rawValue as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else {
                return nil
            }
            guard !CFNumberIsFloatType(value) else {
                return nil
            }
            if let integer = rawValue as? Int {
                return allowedRange.contains(integer) ? integer : nil
            }
            return exactInteger(
                from: value.stringValue,
                in: allowedRange
            )
        }
        if let value = rawValue as? Int {
            return allowedRange.contains(value) ? value : nil
        }
        if
            allowNumericString,
            let value = rawValue as? String,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        {
            return exactInteger(from: value, in: allowedRange)
        }
        return nil
    }

    private static func exactInteger(
        from text: String,
        in allowedRange: ClosedRange<Int>
    ) -> Int? {
        guard
            isJSONNumberLexeme(text),
            let decimal = Decimal(
                string: text,
                locale: Locale(identifier: "en_US_POSIX")
            )
        else {
            return nil
        }
        var source = decimal
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        guard
            rounded == decimal,
            decimal >= Decimal(allowedRange.lowerBound),
            decimal <= Decimal(allowedRange.upperBound)
        else {
            return nil
        }
        let integer = Int(
            NSDecimalNumber(decimal: decimal).int64Value
        )
        return allowedRange.contains(integer) ? integer : nil
    }

    private static func isJSONNumberLexeme(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        var index = 0

        if bytes[index] == 0x2D {
            index += 1
            guard index < bytes.count else { return false }
        }

        if bytes[index] == 0x30 {
            index += 1
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                return false
            }
        } else {
            guard (0x31...0x39).contains(bytes[index]) else {
                return false
            }
            repeat {
                index += 1
            } while
                index < bytes.count
                    && (0x30...0x39).contains(bytes[index])
        }

        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            guard
                index < bytes.count,
                (0x30...0x39).contains(bytes[index])
            else {
                return false
            }
            repeat {
                index += 1
            } while
                index < bytes.count
                    && (0x30...0x39).contains(bytes[index])
        }

        if
            index < bytes.count,
            bytes[index] == 0x65 || bytes[index] == 0x45
        {
            index += 1
            if
                index < bytes.count,
                bytes[index] == 0x2B || bytes[index] == 0x2D
            {
                index += 1
            }
            guard
                index < bytes.count,
                (0x30...0x39).contains(bytes[index])
            else {
                return false
            }
            repeat {
                index += 1
            } while
                index < bytes.count
                    && (0x30...0x39).contains(bytes[index])
        }

        return index == bytes.count
    }
}

enum UsageImporter {
    private static let readChunkSize = 128 * 1024
    static let maximumCSVCells = UsageLimits.maximumJSONStructuralEntries
    private enum IntegerFieldValue: Equatable {
        case missing
        case value(Int)
        case invalid

        var decodedValue: Int? {
            guard case .value(let value) = self else { return nil }
            return value
        }
    }
    private enum CSVFieldState {
        case unquoted
        case quoted
        case quoteClosed
    }

    static func importFile(_ url: URL) throws -> ImportResult {
        let fileExtension = url.pathExtension.lowercased()
        guard ["json", "csv", "jsonl", "ndjson"].contains(fileExtension) else {
            throw UsageImportError.unsupportedFormat(fileExtension)
        }
        if fileExtension == "jsonl" || fileExtension == "ndjson" {
            return try parseJSONLines(from: url)
        }
        let data = try readBoundedFile(url)

        switch fileExtension {
        case "json":
            return try parseJSON(data)
        case "csv":
            return try parseCSV(data)
        default:
            throw UsageImportError.unsupportedFormat(fileExtension)
        }
    }

    static func parseJSON(_ data: Data) throws -> ImportResult {
        try enforceFileSize(data.count)
        guard try preflightJSONBeforeMaterialization(data) else {
            throw UsageImportError.malformed(
                "некорректный синтаксис JSON"
            )
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageImportError.malformed(error.localizedDescription)
        }

        let rawRows: [[String: Any]]
        if let rows = object as? [[String: Any]] {
            rawRows = rows
        } else if
            let envelope = object as? [String: Any],
            let rows =
                (envelope["records"] as? [[String: Any]])
                ?? (envelope["usage"] as? [[String: Any]])
        {
            rawRows = rows
        } else if let row = object as? [String: Any] {
            rawRows = [row]
        } else {
            throw UsageImportError.malformed("ожидался объект или массив объектов")
        }

        try preflightEmbeddedJSONStrings(in: rawRows)
        guard rawRows.count <= UsageLimits.maximumRetainedRecords else {
            throw UsageImportError.tooManyRecords(
                maximum: UsageLimits.maximumRetainedRecords
            )
        }
        return try makeResult(rows: rawRows, format: "JSON")
    }

    private static func preflightJSONBeforeMaterialization(
        _ data: Data,
        maximumDepth: Int = UsageLimits.maximumNestingDepth + 2,
        maximumStructuralEntries: Int =
            UsageLimits.maximumJSONStructuralEntries
    ) throws -> Bool {
        try data.withUnsafeBytes { rawBuffer in
            var scanner = JSONImportRecordPreflightScanner(
                bytes: rawBuffer.bindMemory(to: UInt8.self),
                maximumRecords: UsageLimits.maximumRetainedRecords,
                maximumStructureDepth: maximumDepth,
                maximumStructuralEntries: maximumStructuralEntries
            )
            guard scanner.isUTF8WithoutByteOrderMark else {
                throw UsageImportError.malformed(
                    "JSON должен быть UTF-8 без BOM"
                )
            }

            switch scanner.scan() {
            case .exceedsRecordLimit:
                throw UsageImportError.tooManyRecords(
                    maximum: UsageLimits.maximumRetainedRecords
                )
            case .structureTooDeep:
                throw UsageImportError.malformed(
                    "превышена допустимая глубина JSON"
                )
            case .exceedsObjectMemberLimit:
                throw UsageImportError.malformed(
                    "слишком много полей в JSON-объекте"
                )
            case .exceedsStructureBudget:
                throw UsageImportError.malformed(
                    "JSON содержит слишком много структурных элементов"
                )
            case .withinLimit:
                return true
            case .invalid:
                return false
            }
        }
    }

    private static func preflightEmbeddedJSONStrings(
        in rows: [[String: Any]]
    ) throws {
        for row in rows {
            try preflightEmbeddedJSONStrings(in: row)
        }
    }

    private static func preflightEmbeddedJSONStrings(
        in row: [String: Any]
    ) throws {
        if let bodyText = row["body"] as? String {
            _ = try preflightEmbeddedJSONString(bodyText)
        }
        if
            let body = row["body"] as? [String: Any],
            let stringValue = body["stringValue"] as? String
        {
            _ = try preflightEmbeddedJSONString(stringValue)
        }
    }

    static func preflightEmbeddedJSONString(
        _ text: String,
        maximumDepth: Int = UsageLimits.maximumNestingDepth + 2,
        maximumStructuralEntries: Int =
            UsageLimits.maximumJSONStructuralEntries
    ) throws -> Bool {
        guard
            text.utf8.count <= UsageLimits.maximumLogicalLineBytes,
            looksLikeEmbeddedJSON(text),
            let data = text.data(using: .utf8)
        else {
            return false
        }
        return try preflightJSONBeforeMaterialization(
            data,
            maximumDepth: maximumDepth,
            maximumStructuralEntries: maximumStructuralEntries
        )
    }

    private static func looksLikeEmbeddedJSON(_ text: String) -> Bool {
        var isAtStart = true
        for scalar in text.unicodeScalars {
            if isAtStart, scalar.value == 0xFEFF {
                isAtStart = false
                continue
            }
            isAtStart = false
            switch scalar.value {
            case 0x20, 0x09, 0x0A, 0x0D:
                continue
            case 0x5B, 0x7B:
                return true
            default:
                return false
            }
        }
        return false
    }

    static func parseJSONLines(_ data: Data) throws -> ImportResult {
        try enforceFileSize(data.count)
        var records: [UsageRecord] = []
        var skippedRows = 0
        var logicalRows = 0
        for line in data.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }) {
            try appendLogicalJSONLine(
                line,
                logicalRows: &logicalRows,
                records: &records,
                skippedRows: &skippedRows
            )
        }

        return jsonLinesResult(records: records, skippedRows: skippedRows)
    }

    private static func parseJSONLines(from url: URL) throws -> ImportResult {
        let opened = try openBoundedRegularFile(url)
        let handle = opened.handle
        defer { try? handle.close() }

        var records: [UsageRecord] = []
        var skippedRows = 0
        var logicalRows = 0
        var totalBytes = 0
        var buffer = Data()
        do {
            while let chunk = try handle.read(upToCount: readChunkSize), !chunk.isEmpty {
                totalBytes = UsageLimits.saturatingAdd(totalBytes, chunk.count)
                try enforceFileSize(totalBytes)
                let previouslyScannedCount = buffer.count
                buffer.append(chunk)
                var lineStart = buffer.startIndex
                var searchStart = buffer.index(
                    buffer.startIndex,
                    offsetBy: previouslyScannedCount
                )
                while let separator = buffer[searchStart...].firstIndex(
                    where: { $0 == 0x0A || $0 == 0x0D }
                ) {
                    let line = buffer[lineStart..<separator]
                    try autoreleasepool {
                        try appendLogicalJSONLine(
                            line,
                            logicalRows: &logicalRows,
                            records: &records,
                            skippedRows: &skippedRows
                        )
                    }
                    lineStart = buffer.index(after: separator)
                    searchStart = lineStart
                }
                let unfinishedLineBytes = buffer.distance(
                    from: lineStart,
                    to: buffer.endIndex
                )
                guard unfinishedLineBytes <= UsageLimits.maximumLogicalLineBytes else {
                    throw UsageImportError.lineTooLong(
                        maximumBytes: UsageLimits.maximumLogicalLineBytes
                    )
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
        } catch let error as UsageImportError {
            throw error
        } catch {
            throw UsageImportError.unreadable
        }
        if !buffer.isEmpty {
            try autoreleasepool {
                try appendLogicalJSONLine(
                    buffer,
                    logicalRows: &logicalRows,
                    records: &records,
                    skippedRows: &skippedRows
                )
            }
        }
        return jsonLinesResult(records: records, skippedRows: skippedRows)
    }

    private static func appendLogicalJSONLine(
        _ line: Data,
        logicalRows: inout Int,
        records: inout [UsageRecord],
        skippedRows: inout Int
    ) throws {
        guard !line.isEmpty else { return }
        logicalRows = UsageLimits.saturatingAdd(logicalRows, 1)
        guard logicalRows <= UsageLimits.maximumRetainedRecords else {
            throw UsageImportError.tooManyRecords(
                maximum: UsageLimits.maximumRetainedRecords
            )
        }
        try appendJSONLine(
            line,
            records: &records,
            skippedRows: &skippedRows
        )
    }

    private static func appendJSONLine(
        _ line: Data,
        records: inout [UsageRecord],
        skippedRows: inout Int
    ) throws {
        guard line.count <= UsageLimits.maximumLogicalLineBytes else {
            throw UsageImportError.lineTooLong(
                maximumBytes: UsageLimits.maximumLogicalLineBytes
            )
        }
        let trimmed = line.last == 0x0D ? line.dropLast() : line[...]
        guard !trimmed.isEmpty else { return }
        guard try preflightJSONBeforeMaterialization(Data(trimmed)) else {
            skippedRows = UsageLimits.saturatingAdd(skippedRows, 1)
            return
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: trimmed),
            let row = object as? [String: Any]
        else {
            skippedRows = UsageLimits.saturatingAdd(skippedRows, 1)
            return
        }
        try preflightEmbeddedJSONStrings(in: row)
        guard let record = record(from: row) else {
            skippedRows = UsageLimits.saturatingAdd(skippedRows, 1)
            return
        }
        guard records.count < UsageLimits.maximumRetainedRecords else {
            throw UsageImportError.tooManyRecords(
                maximum: UsageLimits.maximumRetainedRecords
            )
        }
        records.append(record)
    }

    private static func jsonLinesResult(
        records: [UsageRecord],
        skippedRows: Int
    ) -> ImportResult {
        ImportResult(
            records: records.sorted { $0.timestamp > $1.timestamp },
            format: "JSONL / OTel JSONL",
            skippedRows: skippedRows
        )
    }

    static func parseCSV(_ data: Data) throws -> ImportResult {
        try enforceFileSize(data.count)
        let byteOrderMark = Data([0xEF, 0xBB, 0xBF])
        let payload: Data
        if data.starts(with: byteOrderMark) {
            payload = Data(data.dropFirst(byteOrderMark.count))
            guard !payload.starts(with: byteOrderMark) else {
                throw UsageImportError.malformed(
                    "CSV содержит больше одного UTF-8 BOM"
                )
            }
        } else {
            payload = data
        }
        guard let text = String(data: payload, encoding: .utf8) else {
            throw UsageImportError.malformed("файл не является UTF-8")
        }
        guard !text.unicodeScalars.contains(where: { $0.value == 0xFEFF })
        else {
            throw UsageImportError.malformed(
                "CSV содержит больше одного UTF-8 BOM"
            )
        }

        let table = try parseCSVTable(text)
        guard let header = table.first, !header.isEmpty else {
            throw UsageImportError.noRecords
        }

        let normalizedHeaders = header.map(normalizeKey)
        let rows: [[String: Any]] = table.dropFirst().map { values in
            var row: [String: Any] = [:]
            for (index, headerName) in normalizedHeaders.enumerated() where index < values.count {
                row[headerName] = values[index]
            }
            return row
        }

        return try makeResult(rows: rows, format: "CSV")
    }

    private static func makeResult(
        rows: [[String: Any]],
        format: String
    ) throws -> ImportResult {
        guard rows.count <= UsageLimits.maximumRetainedRecords else {
            throw UsageImportError.tooManyRecords(
                maximum: UsageLimits.maximumRetainedRecords
            )
        }
        var records: [UsageRecord] = []
        var skippedRows = 0

        for row in rows {
            if let record = record(from: row) {
                guard records.count < UsageLimits.maximumRetainedRecords else {
                    throw UsageImportError.tooManyRecords(
                        maximum: UsageLimits.maximumRetainedRecords
                    )
                }
                records.append(record)
            } else {
                skippedRows = UsageLimits.saturatingAdd(skippedRows, 1)
            }
        }

        guard !records.isEmpty else {
            return ImportResult(records: [], format: format, skippedRows: skippedRows)
        }

        return ImportResult(
            records: records.sorted { $0.timestamp > $1.timestamp },
            format: format,
            skippedRows: skippedRows
        )
    }

    static func record(from rawRow: [String: Any], defaultSource: String = "import") -> UsageRecord? {
        guard var row = flatten(rawRow) else { return nil }

        if let body = rawRow["body"] as? [String: Any] {
            if let flattenedBody = flatten(body) {
                row.merge(flattenedBody) { current, _ in current }
            }
            if let stringValue = body["stringValue"] as? String {
                row.merge(flattenJSONString(stringValue)) { current, _ in current }
            }
        } else if let bodyText = rawRow["body"] as? String {
            row.merge(flattenJSONString(bodyText)) { current, _ in current }
        }

        let model = stringValue(
            in: row,
            keys: [
                "model",
                "model_id",
                "gen_ai.request.model",
                "gen_ai.response.model",
                "response.model"
            ]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        let inputField = integerFieldValue(
            in: row,
            keys: [
                "input_tokens",
                "inputtokens",
                "input_token_count",
                "gen_ai.usage.input_tokens",
                "usage.input_tokens",
                "response.usage.input_tokens"
            ]
        )
        let outputField = integerFieldValue(
            in: row,
            keys: [
                "output_tokens",
                "outputtokens",
                "output_token_count",
                "gen_ai.usage.output_tokens",
                "usage.output_tokens",
                "response.usage.output_tokens"
            ]
        )

        guard
            let model,
            !model.isEmpty,
            let model = UsageLimits.boundedString(
                model,
                maximumUTF8Bytes: UsageLimits.maximumModelBytes
            ),
            case .value(let input) = inputField,
            case .value(let output) = outputField
        else {
            return nil
        }

        let timestampKeys = [
            "timestamp",
            "time",
            "date",
            "created_at",
            "observed_time",
        ]
        guard let timestamp =
            dateValue(in: row, keys: timestampKeys)
            ?? unixNanoDate(in: row)
        else { return nil }

        let cachedField = integerFieldValue(
            in: row,
            keys: [
                "cached_input_tokens",
                "cachedinputtokens",
                "cache_read_input_tokens",
                "cache_read_tokens",
                "usage.input_tokens_details.cached_tokens",
                "response.usage.input_tokens_details.cached_tokens"
            ]
        )
        let cacheWriteField = integerFieldValue(
            in: row,
            keys: [
                "cache_write_tokens",
                "cachewritetokens",
                "usage.input_tokens_details.cache_write_tokens",
                "response.usage.input_tokens_details.cache_write_tokens"
            ]
        )
        let reasoningOutputField = integerFieldValue(
            in: row,
            keys: [
                "reasoning_output_tokens",
                "reasoningoutputtokens",
                "usage.output_tokens_details.reasoning_tokens",
                "response.usage.output_tokens_details.reasoning_tokens",
            ]
        )
        guard
            cachedField != .invalid,
            cacheWriteField != .invalid,
            reasoningOutputField != .invalid
        else {
            return nil
        }
        let cached = cachedField.decodedValue ?? 0
        let cacheWrite = cacheWriteField.decodedValue ?? 0
        let reasoningOutput = reasoningOutputField.decodedValue
        let serviceTier = stringValue(
            in: row,
            keys: ["service_tier", "servicetier", "openai.service_tier"]
        ).flatMap {
            UsageLimits.boundedString(
                $0,
                maximumUTF8Bytes: UsageLimits.maximumServiceTierBytes
            )
        }
        let sourceCandidate =
            stringValue(in: row, keys: ["source"]) ?? defaultSource
        guard
            let source = UsageLimits.boundedString(
                sourceCandidate,
                maximumUTF8Bytes: UsageLimits.maximumSourceBytes
            )
        else {
            return nil
        }

        return UsageRecord(
            timestamp: timestamp,
            model: model,
            inputTokens: input,
            cachedInputTokens: min(max(0, cached), max(0, input)),
            cacheWriteTokens: min(max(0, cacheWrite), max(0, input - cached)),
            outputTokens: output,
            source: source,
            reasoningOutputTokens: reasoningOutput,
            serviceTier: serviceTier
        )
    }

    private static func flatten(
        _ dictionary: [String: Any],
        prefix: String = ""
    ) -> [String: Any]? {
        var result: [String: Any] = [:]
        var fieldCount = 0
        guard flatten(
            dictionary,
            prefix: prefix,
            depth: 0,
            fieldCount: &fieldCount,
            result: &result
        ) else {
            return nil
        }
        return result
    }

    private static func flatten(
        _ dictionary: [String: Any],
        prefix: String,
        depth: Int,
        fieldCount: inout Int,
        result: inout [String: Any]
    ) -> Bool {
        guard depth <= UsageLimits.maximumNestingDepth else { return false }
        for (key, value) in dictionary {
            guard
                let boundedKey = UsageLimits.boundedString(
                    key,
                    maximumUTF8Bytes: UsageLimits.maximumGenericStringBytes
                )
            else {
                return false
            }
            let normalized = normalizeKey(boundedKey)
            let fullKey = prefix.isEmpty ? normalized : "\(prefix).\(normalized)"

            if let nested = value as? [String: Any] {
                if let scalar = otelScalar(nested) {
                    guard setFlattenedValue(
                        scalar,
                        fullKey: fullKey,
                        normalizedKey: normalized,
                        fieldCount: &fieldCount,
                        result: &result
                    ) else {
                        return false
                    }
                } else if !flatten(
                    nested,
                    prefix: fullKey,
                    depth: depth + 1,
                    fieldCount: &fieldCount,
                    result: &result
                ) {
                    return false
                }
            } else if let attributes = value as? [[String: Any]], normalized == "attributes" {
                guard attributes.count <= UsageLimits.maximumFlattenedFields else {
                    return false
                }
                for attribute in attributes {
                    guard
                        let attributeKey = attribute["key"] as? String,
                        let boundedAttributeKey = UsageLimits.boundedString(
                            attributeKey,
                            maximumUTF8Bytes:
                                UsageLimits.maximumGenericStringBytes
                        )
                    else {
                        continue
                    }
                    if
                        let wrapped = attribute["value"] as? [String: Any],
                        let scalar = otelScalar(wrapped)
                    {
                        let attributeName = normalizeKey(boundedAttributeKey)
                        guard setFlattenedValue(
                            scalar,
                            fullKey: attributeName,
                            normalizedKey: attributeName,
                            fieldCount: &fieldCount,
                            result: &result
                        ) else {
                            return false
                        }
                    }
                }
            } else if
                !setFlattenedValue(
                    value,
                    fullKey: fullKey,
                    normalizedKey: normalized,
                    fieldCount: &fieldCount,
                    result: &result
                )
            {
                return false
            }
        }
        return true
    }

    private static func setFlattenedValue(
        _ value: Any,
        fullKey: String,
        normalizedKey: String,
        fieldCount: inout Int,
        result: inout [String: Any]
    ) -> Bool {
        if
            let text = value as? String,
            text.utf8.count > UsageLimits.maximumGenericStringBytes
        {
            return true
        }
        guard
            value is String
                || value is NSNumber
                || value is Int
                || value is Double
                || value is Date
        else {
            return true
        }

        for key in Set([fullKey, normalizedKey]) where result[key] == nil {
            fieldCount = UsageLimits.saturatingAdd(fieldCount, 1)
            guard fieldCount <= UsageLimits.maximumFlattenedFields else {
                return false
            }
            result[key] = value
        }
        return true
    }

    private static func flattenJSONString(_ text: String) -> [String: Any] {
        guard
            text.utf8.count <= UsageLimits.maximumLogicalLineBytes,
            looksLikeEmbeddedJSON(text),
            let data = text.data(using: .utf8),
            (try? preflightJSONBeforeMaterialization(data)) == true,
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let flattened = flatten(dictionary)
        else {
            return [:]
        }
        return flattened
    }

    private static func otelScalar(_ dictionary: [String: Any]) -> Any? {
        for key in ["stringValue", "intValue", "doubleValue", "boolValue"] {
            if let value = dictionary[key] {
                return value
            }
        }
        return nil
    }

    private static func normalizeKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func stringValue(in row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            let normalized = normalizeKey(key)
            if let value = row[normalized] as? String {
                return UsageLimits.boundedString(
                    value,
                    maximumUTF8Bytes: UsageLimits.maximumGenericStringBytes
                )
            }
            if let value = row[normalized] {
                return UsageLimits.boundedString(
                    String(describing: value),
                    maximumUTF8Bytes: UsageLimits.maximumGenericStringBytes
                )
            }
        }
        return nil
    }

    private static func integerFieldValue(
        in row: [String: Any],
        keys: [String]
    ) -> IntegerFieldValue {
        for key in keys {
            let normalized = normalizeKey(key)
            guard let value = row[normalized] else { continue }
            guard
                let decoded = StrictIntegerDecoding.value(
                    from: value,
                    in: 0...UsageLimits.maximumTokenCount,
                    allowNumericString: true
                )
            else {
                return .invalid
            }
            return .value(decoded)
        }
        return .missing
    }

    private static func dateValue(in row: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            let normalized = normalizeKey(key)
            guard let raw = row[normalized] else { continue }

            if
                let date = raw as? Date,
                UsageLimits.isPlausibleTimestamp(date)
            {
                return date
            }
            if let number = raw as? NSNumber {
                return UsageLimits.dateFromAutoDetectedEpoch(
                    number.doubleValue
                )
            }
            if let text = raw as? String {
                if let epoch = Double(text) {
                    return UsageLimits.dateFromAutoDetectedEpoch(epoch)
                }
                if
                    let parsed = DateParsing.parse(text),
                    UsageLimits.isPlausibleTimestamp(parsed)
                {
                    return parsed
                }
            }
        }
        return nil
    }

    private static func unixNanoDate(in row: [String: Any]) -> Date? {
        for key in ["timeunixnano", "time_unix_nano", "observedtimeunixnano"] {
            guard let raw = row[key] else { continue }
            let value: Double?
            if let number = raw as? NSNumber {
                value = number.doubleValue
            } else if let text = raw as? String {
                value = Double(text)
            } else {
                value = nil
            }
            if let value {
                return UsageLimits.dateFromAutoDetectedEpoch(value)
            }
        }
        return nil
    }

    private static func parseCSVTable(_ text: String) throws -> [[String]] {
        try preflightCSV(text)

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var state = CSVFieldState.unquoted
        var fieldWasQuoted = false
        var index = text.startIndex
        var logicalLineBytes = 0

        func finishField() throws {
            guard row.count < UsageLimits.maximumFlattenedFields else {
                throw UsageImportError.malformed(
                    "слишком много полей в CSV-записи"
                )
            }
            row.append(
                fieldWasQuoted
                    ? field
                    : field.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            field = ""
            fieldWasQuoted = false
            state = .unquoted
        }

        func finishRow() throws {
            try finishField()
            if row.contains(where: { !$0.isEmpty }) {
                guard rows.count <= UsageLimits.maximumRetainedRecords else {
                    throw UsageImportError.tooManyRecords(
                        maximum: UsageLimits.maximumRetainedRecords
                    )
                }
                rows.append(row)
            }
            row = []
            logicalLineBytes = 0
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            logicalLineBytes = UsageLimits.saturatingAdd(
                logicalLineBytes,
                text[index..<next].utf8.count
            )
            guard logicalLineBytes <= UsageLimits.maximumLogicalLineBytes else {
                throw UsageImportError.lineTooLong(
                    maximumBytes: UsageLimits.maximumLogicalLineBytes
                )
            }

            switch state {
            case .quoted:
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        logicalLineBytes = UsageLimits.saturatingAdd(
                            logicalLineBytes,
                            text[next...next].utf8.count
                        )
                        index = text.index(after: next)
                        continue
                    }
                    state = .quoteClosed
                } else {
                    field.append(character)
                }
            case .quoteClosed:
                if character == "," {
                    try finishField()
                } else if character == "\n" || character == "\r\n" {
                    try finishRow()
                } else if character == "\r" {
                    try finishRow()
                    if next < text.endIndex, text[next] == "\n" {
                        index = text.index(after: next)
                        continue
                    }
                } else {
                    throw UsageImportError.malformed(
                        "символ после закрывающей quote в CSV"
                    )
                }
            case .unquoted:
                if character == "\"" {
                    guard field.isEmpty else {
                        throw UsageImportError.malformed(
                            "quote внутри unquoted CSV-поля"
                        )
                    }
                    fieldWasQuoted = true
                    state = .quoted
                } else if character == "," {
                    try finishField()
                } else if character == "\n" || character == "\r\n" {
                    try finishRow()
                } else if character == "\r" {
                    try finishRow()
                    if next < text.endIndex, text[next] == "\n" {
                        index = text.index(after: next)
                        continue
                    }
                } else {
                    field.append(character)
                }
            }

            index = next
        }

        guard state != .quoted else {
            throw UsageImportError.malformed(
                "незакрытое quoted-поле в CSV"
            )
        }
        if !field.isEmpty || !row.isEmpty || fieldWasQuoted {
            try finishRow()
        }
        return rows
    }

    private static func preflightCSV(_ text: String) throws {
        var state = CSVFieldState.unquoted
        var index = text.startIndex
        var cellCount = 0
        var hasPendingRow = false
        var unquotedFieldHasContent = false

        func countCell() throws {
            cellCount = UsageLimits.saturatingAdd(cellCount, 1)
            guard cellCount <= maximumCSVCells else {
                throw UsageImportError.malformed(
                    "CSV содержит больше \(maximumCSVCells) ячеек"
                )
            }
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            switch state {
            case .quoted:
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        index = text.index(after: next)
                        continue
                    }
                    state = .quoteClosed
                }
                hasPendingRow = true
            case .quoteClosed:
                if character == "," {
                    try countCell()
                    state = .unquoted
                    unquotedFieldHasContent = false
                    hasPendingRow = true
                } else if
                    character == "\n"
                        || character == "\r"
                        || character == "\r\n"
                {
                    try countCell()
                    state = .unquoted
                    unquotedFieldHasContent = false
                    hasPendingRow = false
                    if
                        character == "\r",
                        next < text.endIndex,
                        text[next] == "\n"
                    {
                        index = text.index(after: next)
                        continue
                    }
                } else {
                    throw UsageImportError.malformed(
                        "символ после закрывающей quote в CSV"
                    )
                }
            case .unquoted:
                if character == "\"" {
                    guard !unquotedFieldHasContent else {
                        throw UsageImportError.malformed(
                            "quote внутри unquoted CSV-поля"
                        )
                    }
                    state = .quoted
                    hasPendingRow = true
                } else if character == "," {
                    try countCell()
                    unquotedFieldHasContent = false
                    hasPendingRow = true
                } else if
                    character == "\n"
                        || character == "\r"
                        || character == "\r\n"
                {
                    try countCell()
                    unquotedFieldHasContent = false
                    hasPendingRow = false
                    if
                        character == "\r",
                        next < text.endIndex,
                        text[next] == "\n"
                    {
                        index = text.index(after: next)
                        continue
                    }
                } else {
                    unquotedFieldHasContent = true
                    hasPendingRow = true
                }
            }

            index = next
        }

        guard state != .quoted else {
            throw UsageImportError.malformed(
                "незакрытое quoted-поле в CSV"
            )
        }
        if hasPendingRow {
            try countCell()
        }
    }

    private static func readBoundedFile(_ url: URL) throws -> Data {
        let opened = try openBoundedRegularFile(url)
        let handle = opened.handle
        defer { try? handle.close() }

        var data = Data()
        do {
            while let chunk = try handle.read(upToCount: readChunkSize),
                  !chunk.isEmpty
            {
                let nextSize = UsageLimits.saturatingAdd(
                    data.count,
                    chunk.count
                )
                try enforceFileSize(nextSize)
                data.append(chunk)
            }
        } catch let error as UsageImportError {
            throw error
        } catch {
            throw UsageImportError.unreadable
        }
        return data
    }

    private static func openBoundedRegularFile(
        _ url: URL
    ) throws -> (handle: FileHandle, byteCount: Int) {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw UsageImportError.unsafeFile
            }
            throw UsageImportError.unreadable
        }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            Darwin.close(descriptor)
            throw UsageImportError.unreadable
        }
        guard
            (metadata.st_mode & S_IFMT) == S_IFREG,
            metadata.st_size >= 0
        else {
            Darwin.close(descriptor)
            throw UsageImportError.unsafeFile
        }
        guard metadata.st_size <= off_t(UsageLimits.maximumImportFileBytes)
        else {
            Darwin.close(descriptor)
            throw UsageImportError.fileTooLarge(
                maximumBytes: UsageLimits.maximumImportFileBytes
            )
        }
        return (
            FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            Int(metadata.st_size)
        )
    }

    private static func enforceFileSize(_ byteCount: Int) throws {
        guard byteCount <= UsageLimits.maximumImportFileBytes else {
            throw UsageImportError.fileTooLarge(
                maximumBytes: UsageLimits.maximumImportFileBytes
            )
        }
    }
}

private struct JSONImportRecordPreflightScanner {
    enum Result {
        case withinLimit
        case exceedsRecordLimit
        case exceedsObjectMemberLimit
        case exceedsStructureBudget
        case structureTooDeep
        case invalid
    }

    private static let trueLiteral = Array("true".utf8)
    private static let falseLiteral = Array("false".utf8)
    private static let nullLiteral = Array("null".utf8)

    private let bytes: UnsafeBufferPointer<UInt8>
    private let maximumRecords: Int
    private let maximumStructureDepth: Int
    private let maximumStructuralEntries: Int
    private var index = 0
    private var structuralEntryCount = 0

    init(
        bytes: UnsafeBufferPointer<UInt8>,
        maximumRecords: Int,
        maximumStructureDepth: Int,
        maximumStructuralEntries: Int
    ) {
        self.bytes = bytes
        self.maximumRecords = maximumRecords
        self.maximumStructureDepth = maximumStructureDepth
        self.maximumStructuralEntries = maximumStructuralEntries
    }

    var isUTF8WithoutByteOrderMark: Bool {
        guard !hasByteOrderMark else { return false }

        var cursor = 0
        while cursor < bytes.count {
            let byte = bytes[cursor]
            switch byte {
            case 0x01...0x7F:
                cursor += 1
            case 0xC2...0xDF:
                guard isContinuation(at: cursor + 1) else {
                    return false
                }
                cursor += 2
            case 0xE0:
                guard
                    hasByte(at: cursor + 1, in: 0xA0...0xBF),
                    isContinuation(at: cursor + 2)
                else {
                    return false
                }
                cursor += 3
            case 0xE1...0xEC, 0xEE...0xEF:
                guard
                    isContinuation(at: cursor + 1),
                    isContinuation(at: cursor + 2)
                else {
                    return false
                }
                cursor += 3
            case 0xED:
                guard
                    hasByte(at: cursor + 1, in: 0x80...0x9F),
                    isContinuation(at: cursor + 2)
                else {
                    return false
                }
                cursor += 3
            case 0xF0:
                guard
                    hasByte(at: cursor + 1, in: 0x90...0xBF),
                    isContinuation(at: cursor + 2),
                    isContinuation(at: cursor + 3)
                else {
                    return false
                }
                cursor += 4
            case 0xF1...0xF3:
                guard
                    isContinuation(at: cursor + 1),
                    isContinuation(at: cursor + 2),
                    isContinuation(at: cursor + 3)
                else {
                    return false
                }
                cursor += 4
            case 0xF4:
                guard
                    hasByte(at: cursor + 1, in: 0x80...0x8F),
                    isContinuation(at: cursor + 2),
                    isContinuation(at: cursor + 3)
                else {
                    return false
                }
                cursor += 4
            default:
                // A raw NUL is invalid in UTF-8 JSON and also catches
                // BOM-less UTF-16/32 encodings before JSONSerialization.
                return false
            }
        }
        return true
    }

    mutating func scan() -> Result {
        skipWhitespace()
        guard index < bytes.count else { return .invalid }

        let result = scanValue(depth: 0)
        guard case .withinLimit = result else {
            return result
        }
        skipWhitespace()
        return index == bytes.count ? .withinLimit : .invalid
    }

    private mutating func scanValue(depth: Int) -> Result {
        skipWhitespace()
        guard index < bytes.count else { return .invalid }

        switch bytes[index] {
        case 0x22:
            return scanString() ? .withinLimit : .invalid
        case 0x5B:
            return scanArray(depth: depth)
        case 0x7B:
            return scanObject(depth: depth)
        case 0x74:
            return consumeLiteral(Self.trueLiteral)
                ? .withinLimit : .invalid
        case 0x66:
            return consumeLiteral(Self.falseLiteral)
                ? .withinLimit : .invalid
        case 0x6E:
            return consumeLiteral(Self.nullLiteral)
                ? .withinLimit : .invalid
        case 0x2D, 0x30...0x39:
            return scanNumber() ? .withinLimit : .invalid
        default:
            return .invalid
        }
    }

    private mutating func scanArray(depth: Int) -> Result {
        guard depth <= maximumStructureDepth else {
            return .structureTooDeep
        }
        guard consumeStructuralEntry() else {
            return .exceedsStructureBudget
        }
        guard consume(0x5B) else { return .invalid }
        skipWhitespace()
        if consume(0x5D) {
            return .withinLimit
        }

        var count = 0
        while index < bytes.count {
            count = UsageLimits.saturatingAdd(count, 1)
            guard count <= maximumRecords else {
                return .exceedsRecordLimit
            }
            guard consumeStructuralEntry() else {
                return .exceedsStructureBudget
            }

            let elementResult = scanValue(depth: depth + 1)
            guard case .withinLimit = elementResult else {
                return elementResult
            }

            skipWhitespace()
            if consume(0x2C) {
                skipWhitespace()
                continue
            }
            guard consume(0x5D) else { return .invalid }
            return .withinLimit
        }

        return .invalid
    }

    private mutating func scanObject(depth: Int) -> Result {
        guard depth <= maximumStructureDepth else {
            return .structureTooDeep
        }
        guard consumeStructuralEntry() else {
            return .exceedsStructureBudget
        }
        guard consume(0x7B) else { return .invalid }
        skipWhitespace()
        if consume(0x7D) {
            return .withinLimit
        }

        var memberCount = 0
        while index < bytes.count {
            memberCount = UsageLimits.saturatingAdd(memberCount, 1)
            guard memberCount <= UsageLimits.maximumFlattenedFields else {
                return .exceedsObjectMemberLimit
            }
            guard consumeStructuralEntry() else {
                return .exceedsStructureBudget
            }
            guard scanString() else { return .invalid }
            skipWhitespace()
            guard consume(0x3A) else { return .invalid }

            let valueResult = scanValue(depth: depth + 1)
            guard case .withinLimit = valueResult else {
                return valueResult
            }
            skipWhitespace()

            if consume(0x2C) {
                skipWhitespace()
                continue
            }
            guard consume(0x7D) else { return .invalid }
            return .withinLimit
        }

        return .invalid
    }

    private mutating func scanNumber() -> Bool {
        _ = consume(0x2D)
        guard index < bytes.count else { return false }

        if consume(0x30) {
            // A leading zero is complete; any following digit will be
            // rejected by the surrounding container/root delimiter check.
        } else {
            guard bytes[index] >= 0x31, bytes[index] <= 0x39 else {
                return false
            }
            index += 1
            while
                index < bytes.count,
                bytes[index] >= 0x30,
                bytes[index] <= 0x39
            {
                index += 1
            }
        }

        if consume(0x2E) {
            guard
                index < bytes.count,
                bytes[index] >= 0x30,
                bytes[index] <= 0x39
            else {
                return false
            }
            repeat {
                index += 1
            } while
                index < bytes.count
                    && bytes[index] >= 0x30
                    && bytes[index] <= 0x39
        }

        if
            index < bytes.count,
            bytes[index] == 0x65 || bytes[index] == 0x45
        {
            index += 1
            if
                index < bytes.count,
                bytes[index] == 0x2B || bytes[index] == 0x2D
            {
                index += 1
            }
            guard
                index < bytes.count,
                bytes[index] >= 0x30,
                bytes[index] <= 0x39
            else {
                return false
            }
            repeat {
                index += 1
            } while
                index < bytes.count
                    && bytes[index] >= 0x30
                    && bytes[index] <= 0x39
        }

        return true
    }

    private mutating func scanString() -> Bool {
        guard consume(0x22) else { return false }

        while index < bytes.count {
            let byte = bytes[index]
            index += 1

            if byte == 0x22 {
                return true
            }
            guard byte >= 0x20 else { return false }
            guard byte == 0x5C else { continue }
            guard index < bytes.count else { return false }

            let escape = bytes[index]
            index += 1
            switch escape {
            case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                continue
            case 0x75:
                guard consumeHexQuad() != nil else { return false }
            default:
                return false
            }
        }

        return false
    }

    private mutating func consumeLiteral(_ literal: [UInt8]) -> Bool {
        guard index + literal.count <= bytes.count else {
            return false
        }
        for byte in literal {
            guard bytes[index] == byte else { return false }
            index += 1
        }
        return true
    }

    private mutating func consumeHexQuad() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = hexValue(bytes[index]) else { return nil }
            result = result * 16 + digit
            index += 1
        }
        return result
    }

    private func hexValue(_ byte: UInt8) -> UInt32? {
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

    private mutating func skipWhitespace() {
        while index < bytes.count, isWhitespace(bytes[index]) {
            index += 1
        }
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else {
            return false
        }
        index += 1
        return true
    }

    private mutating func consumeStructuralEntry() -> Bool {
        structuralEntryCount = UsageLimits.saturatingAdd(
            structuralEntryCount,
            1
        )
        return
            structuralEntryCount <= maximumStructuralEntries
    }

    private var hasByteOrderMark: Bool {
        if
            bytes.count >= 3,
            bytes[0] == 0xEF,
            bytes[1] == 0xBB,
            bytes[2] == 0xBF
        {
            return true
        }
        if
            bytes.count >= 2,
            (bytes[0] == 0xFF && bytes[1] == 0xFE)
                || (bytes[0] == 0xFE && bytes[1] == 0xFF)
        {
            return true
        }
        return
            bytes.count >= 4
                && bytes[0] == 0x00
                && bytes[1] == 0x00
                && bytes[2] == 0xFE
                && bytes[3] == 0xFF
    }

    private func isContinuation(at position: Int) -> Bool {
        hasByte(at: position, in: 0x80...0xBF)
    }

    private func hasByte(
        at position: Int,
        in range: ClosedRange<UInt8>
    ) -> Bool {
        position < bytes.count && range.contains(bytes[position])
    }
}

enum DateParsing {
    private static let formatters = DateFormatterPool()

    static func parse(_ text: String) -> Date? {
        formatters.parse(text)
    }

    static func format(_ date: Date) -> String {
        formatters.format(date)
    }
}

private final class DateFormatterPool: @unchecked Sendable {
    private let lock = NSLock()
    private let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let standardISO8601 = ISO8601DateFormatter()
    private let legacyDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    private let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    func parse(_ text: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if
            let dot = text.firstIndex(of: "."),
            let fractionEnd = text[dot...].firstIndex(where: {
                !$0.isNumber && $0 != "."
            }),
            fractionEnd > text.index(after: dot)
        {
            let digits = text[text.index(after: dot)..<fractionEnd]
            let baseText = String(text[..<dot]) + String(text[fractionEnd...])
            if
                let base = standardISO8601.date(from: baseText),
                let fraction = Double("0." + digits)
            {
                return base.addingTimeInterval(fraction)
            }
        }
        if let date = fractionalISO8601.date(from: text) {
            return date
        }
        if let date = standardISO8601.date(from: text) {
            return date
        }
        return legacyDateTime.date(from: text) ?? dateOnly.date(from: text)
    }

    func format(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }

        var wholeSeconds = floor(date.timeIntervalSince1970)
        var microseconds = Int(
            ((date.timeIntervalSince1970 - wholeSeconds) * 1_000_000).rounded()
        )
        if microseconds == 1_000_000 {
            wholeSeconds += 1
            microseconds = 0
        }

        let base = standardISO8601.string(
            from: Date(timeIntervalSince1970: wholeSeconds)
        )
        guard microseconds > 0, base.hasSuffix("Z") else {
            return base
        }
        return base.dropLast() + String(format: ".%06dZ", microseconds)
    }
}
