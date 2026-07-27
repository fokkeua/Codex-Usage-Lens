import Darwin
import Foundation
import Testing
@testable import CodexUsageMenuBar

@Test("Импорт нормализованного JSON")
func importsNormalizedJSON() throws {
    let json = """
    [
      {
        "timestamp": "2026-07-26T10:00:00Z",
        "model": "gpt-5.6-terra",
        "input_tokens": 1200,
        "cached_input_tokens": 400,
        "cache_write_tokens": 100,
        "output_tokens": 300
      }
    ]
    """

    let result = try UsageImporter.parseJSON(Data(json.utf8))
    let record = try #require(result.records.first)
    #expect(record.model == "gpt-5.6-terra")
    #expect(record.inputTokens == 1200)
    #expect(record.cachedInputTokens == 400)
    #expect(record.cacheWriteTokens == 100)
    #expect(record.outputTokens == 300)
}

@Test("JSON importer сохраняет object, array и envelope contracts")
func importsSupportedJSONContainers() throws {
    let row = """
    {
      "timestamp":"2026-07-26T10:00:00Z",
      "model":"model-a",
      "input_tokens":10,
      "output_tokens":2,
      "source":"quoted, [value]"
    }
    """
    let payloads = [
        row,
        "[\(row)]",
        "{\"records\":[\(row)]}",
        "{\"usage\":[\(row)]}",
        "{\"records\":null,\"usage\":[\(row)]}",
        #"{ "rec\u006frds": [\#(row)] }"#,
    ]

    for payload in payloads {
        let result = try UsageImporter.parseJSON(Data(payload.utf8))
        #expect(result.records.count == 1)
        #expect(result.records.first?.model == "model-a")
    }
}

@Test("JSON preflight отклоняет compact array свыше record limit")
func jsonPreflightRejectsLargeCompactArray() throws {
    let boundary = compactJSONObjectArray(
        count: UsageLimits.maximumRetainedRecords
    )
    let boundaryResult = try UsageImporter.parseJSON(boundary)
    #expect(
        boundaryResult.skippedRows
            == UsageLimits.maximumRetainedRecords
    )

    let data = compactJSONObjectArray(
        count: UsageLimits.maximumRetainedRecords + 1
    )

    #expect(data.count < UsageLimits.maximumImportFileBytes)
    expectTooManyJSONRecords(data)
}

@Test("JSON preflight ограничивает records и usage envelope до materialization")
func jsonPreflightRejectsOversizedEnvelopeArrays() {
    let array = compactJSONObjectArray(
        count: UsageLimits.maximumRetainedRecords + 1
    )
    let prefixes = [
        Data(#"{"records":"#.utf8),
        Data(#"{"usage":"#.utf8),
        Data(#"{"rec\u006frds":"#.utf8),
    ]

    for prefix in prefixes {
        var data = prefix
        data.append(array)
        data.append(0x7D)
        expectTooManyJSONRecords(data)
    }
}

@Test("JSON preflight проверяет каждый records/usage array независимо")
func jsonPreflightRejectsEveryEnvelopeArray() {
    let array = compactJSONObjectArray(
        count: UsageLimits.maximumRetainedRecords + 1
    )
    let wrappers = [
        (
            Data(#"{"records":null,"usage":"#.utf8),
            Data("}".utf8)
        ),
        (
            Data(#"{"records":[],"records":"#.utf8),
            Data("}".utf8)
        ),
        (
            Data(#"{"usage":[],"records":null,"usage":"#.utf8),
            Data("}".utf8)
        ),
    ]

    for (prefix, suffix) in wrappers {
        var data = prefix
        data.append(array)
        data.append(suffix)
        expectTooManyJSONRecords(data)
    }
}

@Test("JSON preflight ограничивает nested и unrelated arrays")
func jsonPreflightRejectsOversizedNestedArrays() throws {
    let oversizedArray = compactJSONObjectArray(
        count: UsageLimits.maximumRetainedRecords + 1
    )
    let prefixes = [
        Data(
            #"{"timestamp":"2026-07-26T10:00:00Z","model":"m","input_tokens":1,"output_tokens":1,"junk":"#.utf8
        ),
        Data(
            #"{"timestamp":"2026-07-26T10:00:00Z","model":"m","input_tokens":1,"output_tokens":1,"junk":{"values":"#.utf8
        ),
    ]
    let suffixes = [Data("}".utf8), Data("}}".utf8)]

    for (prefix, suffix) in zip(prefixes, suffixes) {
        var data = prefix
        data.append(oversizedArray)
        data.append(suffix)
        expectTooManyJSONRecords(data)
    }

    var boundary = prefixes[0]
    boundary.append(
        compactJSONObjectArray(
            count: UsageLimits.maximumRetainedRecords
        )
    )
    boundary.append(suffixes[0])
    let result = try UsageImporter.parseJSON(boundary)
    #expect(result.records.count == 1)
}

@Test("JSON preflight отклоняет BOM и UTF-16/32 до materialization")
func jsonPreflightRejectsAlternateEncodings() throws {
    let oversizedArray = compactJSONObjectArray(
        count: UsageLimits.maximumRetainedRecords + 1
    )

    var utf8WithBOM = Data([0xEF, 0xBB, 0xBF])
    utf8WithBOM.append(oversizedArray)
    expectMalformedJSONPreflight(utf8WithBOM, context: "UTF-8 BOM")

    let text = String(decoding: oversizedArray, as: UTF8.self)
    let utf16 = try #require(
        text.data(using: .utf16LittleEndian)
    )
    let utf32 = try #require(
        text.data(using: .utf32BigEndian)
    )
    expectMalformedJSONPreflight(utf16, context: "UTF-16")
    expectMalformedJSONPreflight(utf32, context: "UTF-32")
}

@Test("JSON preflight ограничивает members каждого object")
func jsonPreflightRejectsOversizedObjects() throws {
    let boundary = compactJSONObject(
        memberCount: UsageLimits.maximumFlattenedFields
    )
    let boundaryResult = try UsageImporter.parseJSON(boundary)
    #expect(boundaryResult.skippedRows == 1)

    let amplified = compactJSONObject(
        memberCount: UsageLimits.maximumRetainedRecords + 1
    )
    #expect(amplified.count < UsageLimits.maximumImportFileBytes)
    expectMalformedJSONPreflight(
        amplified,
        context: "oversized root object"
    )

    var nested = Data(#"{"junk":"#.utf8)
    nested.append(
        compactJSONObject(
            memberCount: UsageLimits.maximumFlattenedFields + 1
        )
    )
    nested.append(0x7D)
    expectMalformedJSONPreflight(
        nested,
        context: "oversized nested object"
    )
}

@Test("JSON preflight ограничивает aggregate structural budget")
func jsonPreflightRejectsAggregateStructureAmplification() {
    let nestingDepth = UsageLimits.maximumNestingDepth
    let entriesPerBranch = 1 + 2 * nestingDepth
    let branchCount =
        UsageLimits.maximumJSONStructuralEntries / entriesPerBranch + 1
    let data = repeatedNestedArrayPayload(
        branchCount: branchCount,
        nestingDepth: nestingDepth
    )

    #expect(branchCount < UsageLimits.maximumRetainedRecords)
    #expect(data.count < UsageLimits.maximumImportFileBytes)
    expectMalformedJSONPreflight(
        data,
        context: "aggregate nested-array amplification"
    )
}

@Test("JSON preflight проверяет embedded JSON до materialization")
func jsonPreflightRejectsOversizedEmbeddedJSON() throws {
    let oversizedText = String(
        decoding: compactJSONObjectArray(
            count: UsageLimits.maximumRetainedRecords + 1
        ),
        as: UTF8.self
    )
    let oversizedOuter = try JSONSerialization.data(
        withJSONObject: [
            "timestamp": "2026-07-26T10:00:00Z",
            "model": "outer",
            "input_tokens": 1,
            "output_tokens": 1,
            "body": oversizedText,
        ]
    )
    expectTooManyJSONRecords(oversizedOuter)

    let smallEmbedded = """
    {"timestamp":"2026-07-26T10:00:00Z","model":"embedded","input_tokens":3,"output_tokens":1}
    """
    let supportedOuter = try JSONSerialization.data(
        withJSONObject: ["body": smallEmbedded]
    )
    let result = try UsageImporter.parseJSON(supportedOuter)
    #expect(result.records.count == 1)
    #expect(result.records.first?.model == "embedded")
    #expect(result.records.first?.inputTokens == 3)
}

@Test("JSON preflight fail-closed на trailing-comma bypass")
func jsonPreflightRejectsTrailingCommaBeforeOversizedArray() {
    let data = trailingCommaBypassPayload(
        arrayCount: UsageLimits.maximumRetainedRecords + 1
    )

    #expect(data.count < UsageLimits.maximumImportFileBytes)
    expectMalformedJSONPreflight(
        data,
        context: "trailing-comma root bypass"
    )
}

@Test("JSONL пропускает invalid trailing-comma line без materialization")
func jsonLinesPreflightSkipsTrailingCommaBypass() throws {
    let data = trailingCommaBypassPayload(
        arrayCount: UsageLimits.maximumRetainedRecords + 1
    )

    let result = try UsageImporter.parseJSONLines(data)
    #expect(result.records.isEmpty)
    #expect(result.skippedRows == 1)
}

@Test("Embedded invalid JSON игнорируется fail-closed")
func embeddedJSONPreflightIgnoresTrailingCommaBypass() throws {
    let embedded = String(
        decoding: trailingCommaBypassPayload(
            arrayCount: UsageLimits.maximumRetainedRecords + 1
        ),
        as: UTF8.self
    )
    let outer = try JSONSerialization.data(
        withJSONObject: [
            "timestamp": "2026-07-26T10:00:00Z",
            "model": "outer",
            "input_tokens": 2,
            "output_tokens": 1,
            "body": embedded,
        ]
    )

    let result = try UsageImporter.parseJSON(outer)
    #expect(result.records.count == 1)
    #expect(result.records.first?.model == "outer")
}

@Test("Malformed root отклоняется, malformed JSONL line пропускается")
func jsonPreflightPreservesMalformedInputSemantics() throws {
    let malformed = Data(#"{"timestamp":}"#.utf8)
    expectMalformedJSONPreflight(
        malformed,
        context: "ordinary malformed root"
    )

    let valid = """
    {"timestamp":"2026-07-26T10:00:00Z","model":"valid","input_tokens":2,"output_tokens":1}
    """
    var jsonLines = malformed
    jsonLines.append(0x0A)
    jsonLines.append(Data(valid.utf8))

    let result = try UsageImporter.parseJSONLines(jsonLines)
    #expect(result.records.count == 1)
    #expect(result.records.first?.model == "valid")
    #expect(result.skippedRows == 1)
}

@Test("Импорт CSV с цитированными полями")
func importsCSV() throws {
    let csv = """
    timestamp,model,input_tokens,cached_input_tokens,output_tokens,source
    2026-07-26T10:00:00Z,"gpt-5.6-sol",2000,750,350,"manual, export"
    """

    let result = try UsageImporter.parseCSV(Data(csv.utf8))
    let record = try #require(result.records.first)
    #expect(record.model == "gpt-5.6-sol")
    #expect(record.inputTokens == 2000)
    #expect(record.source == "manual, export")
}

@Test("CSV preflight ограничивает aggregate cells и незакрытые quotes")
func csvPreflightRejectsAmplificationAndUnterminatedQuotes() throws {
    let excessiveCells = Data(
        String(
            repeating: ",",
            count: UsageImporter.maximumCSVCells
        ).utf8
    )
    do {
        _ = try UsageImporter.parseCSV(excessiveCells)
        Issue.record("excessive CSV cell count unexpectedly succeeded")
    } catch let error as UsageImportError {
        guard case .malformed(let message) = error else {
            Issue.record("unexpected CSV cell-limit error: \(error)")
            return
        }
        #expect(message.contains("ячеек"))
    }

    let unterminated = Data(
        """
        timestamp,model,input_tokens,output_tokens
        2026-07-26T10:00:00Z,"model-a,1,1
        """.utf8
    )
    do {
        _ = try UsageImporter.parseCSV(unterminated)
        Issue.record("unterminated CSV quote unexpectedly succeeded")
    } catch let error as UsageImportError {
        guard case .malformed(let message) = error else {
            Issue.record("unexpected unterminated CSV error: \(error)")
            return
        }
        #expect(message.contains("незакрытое"))
    }

    for malformed in [
        """
        timestamp,model,input_tokens,output_tokens
        2026-07-26T10:00:00Z,mo"del,1,1
        """,
        """
        timestamp,model,input_tokens,output_tokens
        2026-07-26T10:00:00Z,"model-a"x,1,1
        """,
    ] {
        #expect(throws: UsageImportError.self) {
            try UsageImporter.parseCSV(Data(malformed.utf8))
        }
    }

    let escapedCRLF = Data(
        "timestamp,model,input_tokens,output_tokens\r\n"
            .appending(
                "2026-07-26T10:00:00Z,\"model-\"\"quoted\",1,1\r\n"
            )
            .utf8
    )
    let escapedResult = try UsageImporter.parseCSV(escapedCRLF)
    let escapedRecord = try #require(
        escapedResult.records.first
    )
    #expect(escapedRecord.model == "model-\"quoted")
}

@Test("CSV поддерживает ровно один leading UTF-8 BOM")
func csvHandlesSingleLeadingBOM() throws {
    let csv = """
    timestamp,model,input_tokens,output_tokens
    2026-07-26T10:00:00Z,model-a,1,1
    """
    var singleBOM = Data([0xEF, 0xBB, 0xBF])
    singleBOM.append(Data(csv.utf8))
    #expect(try UsageImporter.parseCSV(singleBOM).records.count == 1)

    var doubleBOM = Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF])
    doubleBOM.append(Data(csv.utf8))
    #expect(throws: UsageImportError.self) {
        try UsageImporter.parseCSV(doubleBOM)
    }
}

@Test("Импорт JSONL с OTLP attributes")
func importsOTelAttributesJSONL() throws {
    let jsonl = """
    {"timeUnixNano":"1785060000000000000","attributes":[{"key":"gen_ai.response.model","value":{"stringValue":"gpt-5.6-luna"}},{"key":"gen_ai.usage.input_tokens","value":{"intValue":"900"}},{"key":"gen_ai.usage.output_tokens","value":{"intValue":"120"}},{"key":"cache_read_tokens","value":{"intValue":"300"}}]}
    """

    let result = try UsageImporter.parseJSONLines(Data(jsonl.utf8))
    let record = try #require(result.records.first)
    #expect(record.model == "gpt-5.6-luna")
    #expect(record.inputTokens == 900)
    #expect(record.cachedInputTokens == 300)
    #expect(record.outputTokens == 120)
}

@Test("JSONL preflight ограничивает outer line до materialization")
func jsonLinesPreflightRejectsOversizedArrays() throws {
    var oversizedLine = Data(#"{"junk":"#.utf8)
    oversizedLine.append(
        compactJSONObjectArray(
            count: UsageLimits.maximumRetainedRecords + 1
        )
    )
    oversizedLine.append(0x7D)

    do {
        _ = try UsageImporter.parseJSONLines(oversizedLine)
        Issue.record("oversized JSONL array unexpectedly succeeded")
    } catch let error as UsageImportError {
        guard case .tooManyRecords(let maximum) = error else {
            Issue.record("unexpected JSONL preflight error: \(error)")
            return
        }
        #expect(maximum == UsageLimits.maximumRetainedRecords)
    }

    let supportedLine = """
    {"timestamp":"2026-07-26T10:00:00Z","model":"model-a","input_tokens":2,"output_tokens":1}
    """
    let result = try UsageImporter.parseJSONLines(
        Data(supportedLine.utf8)
    )
    #expect(result.records.count == 1)
}

@Test("Файловый JSONL поддерживает bare CR и max-size CRLF/LF lines")
func jsonLinesFileSupportsCRAndMaximumLineEndings() throws {
    let maximum = UsageLimits.maximumLogicalLineBytes
    let crlfLine = paddedNormalizedJSONLine(
        byteCount: maximum,
        model: "max-crlf"
    )
    let lfLine = paddedNormalizedJSONLine(
        byteCount: maximum,
        model: "max-lf"
    )
    #expect(crlfLine.count == maximum)
    #expect(lfLine.count == maximum)

    var contents = normalizedJSONLine(model: "bare-cr-1")
    contents.append(0x0D)
    contents.append(normalizedJSONLine(model: "bare-cr-2"))
    contents.append(0x0D)
    contents.append(crlfLine)
    contents.append(contentsOf: [0x0D, 0x0A])
    contents.append(lfLine)
    contents.append(0x0A)

    let result = try importTemporaryJSONLines(contents)
    #expect(result.records.count == 4)
    #expect(Set(result.records.map(\.model)) == [
        "bare-cr-1",
        "bare-cr-2",
        "max-crlf",
        "max-lf",
    ])
}

@Test("Файловый JSONL обрабатывает CRLF на границе read chunk")
func jsonLinesFileHandlesChunkBoundarySeparator() throws {
    let readChunkSize = 128 * 1024
    let boundaryLine = paddedNormalizedJSONLine(
        byteCount: readChunkSize - 1,
        model: "chunk-boundary"
    )
    #expect(boundaryLine.count + 1 == readChunkSize)

    var contents = boundaryLine
    contents.append(contentsOf: [0x0D, 0x0A])
    contents.append(normalizedJSONLine(model: "after-boundary"))
    contents.append(0x0A)

    let result = try importTemporaryJSONLines(contents)
    #expect(result.records.count == 2)
    #expect(Set(result.records.map(\.model)) == [
        "chunk-boundary",
        "after-boundary",
    ])
}

@Test("Пустые mixed JSONL separators не расходуют record limit")
func jsonLinesFileIgnoresMixedBlankSeparators() throws {
    var contents = Data()
    contents.reserveCapacity(
        3 * (UsageLimits.maximumRetainedRecords + 1) + 128
    )
    for _ in 0...UsageLimits.maximumRetainedRecords {
        contents.append(contentsOf: [0x0A, 0x0D, 0x0A])
    }
    contents.append(normalizedJSONLine(model: "after-blanks"))
    contents.append(0x0D)

    let result = try importTemporaryJSONLines(contents)
    #expect(result.records.count == 1)
    #expect(result.records.first?.model == "after-blanks")
    #expect(result.skippedRows == 0)
}

@Test("Importer требует timestamp и распознаёт epoch seconds/ms/us/ns")
func importerRequiresAndAutodetectsTimestampUnits() throws {
    let epochSeconds = 1_785_060_000.0
    let base: [String: Any] = [
        "model": "model-a",
        "input_tokens": 100,
        "output_tokens": 10,
    ]

    #expect(UsageImporter.record(from: base) == nil)

    let values = [
        epochSeconds,
        epochSeconds * 1_000,
        epochSeconds * 1_000_000,
        epochSeconds * 1_000_000_000,
    ]
    let timestamps = values.compactMap { value in
        UsageImporter.record(
            from: base.merging(["timestamp": value]) { _, new in new }
        )?.timestamp
    }

    #expect(timestamps.count == values.count)
    for timestamp in timestamps {
        #expect(abs(timestamp.timeIntervalSince1970 - epochSeconds) < 0.001)
    }

    #expect(
        UsageImporter.record(
            from: base.merging(["timestamp": 1]) { _, new in new }
        ) == nil
    )
    #expect(
        UsageImporter.record(
            from: base.merging(["timestamp": 9.9e30]) { _, new in new }
        ) == nil
    )
}

@Test("Importer отклоняет counters и строки выше общего domain cap")
func importerEnforcesCounterAndStringCaps() {
    let timestamp = "2026-07-26T10:00:00Z"
    let oversizedModel = String(
        repeating: "m",
        count: UsageLimits.maximumModelBytes + 1
    )

    #expect(
        UsageImporter.record(
            from: [
                "timestamp": timestamp,
                "model": "model-a",
                "input_tokens": UsageLimits.maximumTokenCount + 1,
                "output_tokens": 1,
            ]
        ) == nil
    )
    #expect(
        UsageImporter.record(
            from: [
                "timestamp": timestamp,
                "model": oversizedModel,
                "input_tokens": 1,
                "output_tokens": 1,
            ]
        ) == nil
    )

    let boundary = UsageImporter.record(
        from: [
            "timestamp": timestamp,
            "model": String(
                repeating: "m",
                count: UsageLimits.maximumModelBytes
            ),
            "input_tokens": UsageLimits.maximumTokenCount,
            "output_tokens": UsageLimits.maximumTokenCount,
        ]
    )
    #expect(boundary?.inputTokens == UsageLimits.maximumTokenCount)
    #expect(boundary?.totalTokens == 2 * UsageLimits.maximumTokenCount)
}

@Test("Importer принимает только конечные целые token counters")
func importerStrictlyDecodesTokenCounters() throws {
    let base: [String: Any] = [
        "timestamp": "2026-07-26T10:00:00Z",
        "model": "model-a",
        "input_tokens": 1,
        "output_tokens": 1,
    ]
    let invalidValues: [Any] = [
        true,
        false,
        1.5,
        "2.5",
        "1.0000000000000001",
        "1e300",
        NSNumber(value: Double.nan),
        NSNumber(value: Double.infinity),
    ]

    for invalidValue in invalidValues {
        let row = base.merging(["input_tokens": invalidValue]) { _, new in new }
        #expect(UsageImporter.record(from: row) == nil)
    }

    #expect(
        UsageImporter.record(
            from: base.merging(["cached_input_tokens": true]) { _, new in new }
        ) == nil
    )

    let numericString = try #require(
        UsageImporter.record(
            from: base.merging([
                "input_tokens": "42",
                "output_tokens": "7.0",
            ]) { _, new in new }
        )
    )
    #expect(numericString.inputTokens == 42)
    #expect(numericString.outputTokens == 7)

    let roundedFractionJSON = Data(
        """
        [{"timestamp":"2026-07-26T10:00:00Z","model":"model-a","input_tokens":1.0000000000000001,"output_tokens":1}]
        """.utf8
    )
    #expect(try UsageImporter.parseJSON(roundedFractionJSON).records.isEmpty)
}

@Test("Importer возвращает явные ошибки file, line и record limits")
func importerReportsExplicitLimits() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let oversizedFile = directory.appendingPathComponent("oversized.json")
    #expect(FileManager.default.createFile(atPath: oversizedFile.path, contents: nil))
    let handle = try FileHandle(forWritingTo: oversizedFile)
    try handle.truncate(
        atOffset: UInt64(UsageLimits.maximumImportFileBytes + 1)
    )
    try handle.close()

    do {
        _ = try UsageImporter.importFile(oversizedFile)
        Issue.record("oversized import unexpectedly succeeded")
    } catch let error as UsageImportError {
        guard case .fileTooLarge(let maximumBytes) = error else {
            Issue.record("unexpected file-limit error: \(error)")
            return
        }
        #expect(maximumBytes == UsageLimits.maximumImportFileBytes)
    }

    let oversizedLine = Data(
        String(
            repeating: "x",
            count: UsageLimits.maximumLogicalLineBytes + 1
        ).utf8
    )
    do {
        _ = try UsageImporter.parseJSONLines(oversizedLine)
        Issue.record("oversized JSONL line unexpectedly succeeded")
    } catch let error as UsageImportError {
        guard case .lineTooLong(let maximumBytes) = error else {
            Issue.record("unexpected line-limit error: \(error)")
            return
        }
        #expect(maximumBytes == UsageLimits.maximumLogicalLineBytes)
    }

    let tooManyRows = Data(
        String(
            repeating: "{}\n",
            count: UsageLimits.maximumRetainedRecords + 1
        ).utf8
    )
    do {
        _ = try UsageImporter.parseJSONLines(tooManyRows)
        Issue.record("record-limit JSONL unexpectedly succeeded")
    } catch let error as UsageImportError {
        guard case .tooManyRecords(let maximum) = error else {
            Issue.record("unexpected record-limit error: \(error)")
            return
        }
        #expect(maximum == UsageLimits.maximumRetainedRecords)
    }
}

@Test("Importer no-follow отклоняет symlink и FIFO без блокировки")
func importerRejectsSymlinkAndSpecialFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let target = directory.appendingPathComponent("target.json")
    try Data(
        """
        {"timestamp":"2026-07-26T10:00:00Z","model":"model-a","input_tokens":1,"output_tokens":1}
        """.utf8
    ).write(to: target)
    let link = directory.appendingPathComponent("linked.json")
    try FileManager.default.createSymbolicLink(
        at: link,
        withDestinationURL: target
    )

    for url in [link] {
        do {
            _ = try UsageImporter.importFile(url)
            Issue.record("unsafe import unexpectedly succeeded")
        } catch let error as UsageImportError {
            guard case .unsafeFile = error else {
                Issue.record("unexpected unsafe-file error: \(error)")
                return
            }
        }
    }

    let fifo = directory.appendingPathComponent("pipe.json")
    let status = fifo.path.withCString {
        Darwin.mkfifo($0, mode_t(0o600))
    }
    #expect(status == 0)
    do {
        _ = try UsageImporter.importFile(fifo)
        Issue.record("FIFO import unexpectedly succeeded")
    } catch let error as UsageImportError {
        guard case .unsafeFile = error else {
            Issue.record("unexpected FIFO error: \(error)")
            return
        }
    }
}

private func compactJSONObjectArray(count: Int) -> Data {
    var data = Data()
    data.reserveCapacity(2 + count * 3)
    data.append(0x5B)
    for index in 0..<count {
        if index > 0 {
            data.append(0x2C)
        }
        data.append(0x7B)
        data.append(0x7D)
    }
    data.append(0x5D)
    return data
}

private func compactJSONObject(memberCount: Int) -> Data {
    var data = Data()
    data.reserveCapacity(2 + memberCount * 12)
    data.append(0x7B)
    for index in 0..<memberCount {
        if index > 0 {
            data.append(0x2C)
        }
        data.append(Data(#""k\#(index)":0"#.utf8))
    }
    data.append(0x7D)
    return data
}

private func repeatedNestedArrayPayload(
    branchCount: Int,
    nestingDepth: Int
) -> Data {
    var branch = Data(repeating: 0x5B, count: nestingDepth)
    branch.append(0x30)
    branch.append(
        Data(repeating: 0x5D, count: nestingDepth)
    )

    var data = Data()
    data.reserveCapacity(2 + branchCount * (branch.count + 1))
    data.append(0x5B)
    for index in 0..<branchCount {
        if index > 0 {
            data.append(0x2C)
        }
        data.append(branch)
    }
    data.append(0x5D)
    return data
}

private func trailingCommaBypassPayload(arrayCount: Int) -> Data {
    var data = Data(
        #"{"prefix":[0,],"timestamp":"2026-07-26T10:00:00Z","model":"outer","input_tokens":1,"output_tokens":1,"junk":"#.utf8
    )
    data.append(compactJSONObjectArray(count: arrayCount))
    data.append(0x7D)
    return data
}

private func normalizedJSONLine(model: String) -> Data {
    Data(
        """
        {"timestamp":"2026-07-26T10:00:00Z","model":"\(model)","input_tokens":2,"output_tokens":1}
        """.utf8
    )
}

private func paddedNormalizedJSONLine(
    byteCount: Int,
    model: String
) -> Data {
    let prefix = Data(
        """
        {"timestamp":"2026-07-26T10:00:00Z","model":"\(model)","input_tokens":2,"output_tokens":1,"padding":"
        """.utf8
    )
    let suffix = Data(#""}"#.utf8)
    precondition(byteCount >= prefix.count + suffix.count)

    var data = prefix
    data.append(
        Data(
            repeating: 0x78,
            count: byteCount - prefix.count - suffix.count
        )
    )
    data.append(suffix)
    return data
}

private func importTemporaryJSONLines(_ data: Data) throws -> ImportResult {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("usage.jsonl")
    try data.write(to: file)
    return try UsageImporter.importFile(file)
}

private func expectTooManyJSONRecords(_ data: Data) {
    do {
        _ = try UsageImporter.parseJSON(data)
        Issue.record("oversized JSON import unexpectedly succeeded")
    } catch let error as UsageImportError {
        guard case .tooManyRecords(let maximum) = error else {
            Issue.record("unexpected JSON record-limit error: \(error)")
            return
        }
        #expect(maximum == UsageLimits.maximumRetainedRecords)
    } catch {
        Issue.record("unexpected JSON import error: \(error)")
    }
}

private func expectMalformedJSONPreflight(
    _ data: Data,
    context: String
) {
    do {
        _ = try UsageImporter.parseJSON(data)
        Issue.record("\(context) unexpectedly succeeded")
    } catch let error as UsageImportError {
        guard case .malformed = error else {
            Issue.record("unexpected \(context) error: \(error)")
            return
        }
    } catch {
        Issue.record("unexpected \(context) error: \(error)")
    }
}
