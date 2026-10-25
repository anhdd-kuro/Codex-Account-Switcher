import Foundation

// Cursor token usage for the Analytics tab. Cursor has no local logs; like TokenTracker (MIT) this reads the
// account's usage export and treats it as authoritative, replacing the Cursor buckets it can rebuild.

struct AnalyticsCursorRecord: Equatable {
    let seconds: Int64
    let model: String
    let input: Int
    let cacheWrite: Int
    let cacheRead: Int
    let output: Int

    var counts: AnalyticsCounts {
        var counts = AnalyticsCounts()
        counts.input = input
        counts.cached = cacheRead
        counts.cacheCreation = cacheWrite
        counts.output = output
        counts.total = input.saturatingAdd(cacheWrite).saturatingAdd(cacheRead).saturatingAdd(output)
        return counts
    }
}

enum AnalyticsCursorCSV {
    /// RFC 4180 style rows: quoted fields may hold commas, doubled quotes and newlines; CRLF and a BOM are tolerated.
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var previousWasQuote = false
        func endField() { row.append(field.trimmingCharacters(in: .whitespaces)); field = "" }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }
        var scalars = Substring(text)
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
        for character in scalars {
            if inQuotes {
                if character == "\"" {
                    if previousWasQuote { field.append("\""); previousWasQuote = false } else { previousWasQuote = true }
                } else {
                    if previousWasQuote { inQuotes = false; previousWasQuote = false; handleUnquoted(character) } else { field.append(character) }
                }
            } else {
                handleUnquoted(character)
            }
        }
        func handleUnquoted(_ character: Character) {
            switch character {
            case "\"": inQuotes = true
            case ",": endField()
            case "\n", "\r\n": endRow()
            case "\r": break
            default: field.append(character)
            }
        }
        if inQuotes && previousWasQuote { inQuotes = false }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Clamps a token count so a hostile or corrupt cell can never trap `Int(_:)`.
    static func number(_ text: String) -> Int {
        guard let value = Double(text), value.isFinite else { return 0 }
        return Int(min(max(value, 0), 1e15))
    }

    /// Columns are resolved by header name because Cursor has inserted new ones before.
    static func parse(_ text: String) -> [AnalyticsCursorRecord] {
        let table = rows(text)
        guard table.count > 1 else { return [] }
        let header = table[0]
        func column(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let date = column("Date"), let model = column("Model"), let inputWith = column("Input (w/ Cache Write)"),
              let inputWithout = column("Input (w/o Cache Write)"), let cacheRead = column("Cache Read"),
              let output = column("Output Tokens") else { return [] }
        let needed = [date, model, inputWith, inputWithout, cacheRead, output].max()! + 1
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        var records: [AnalyticsCursorRecord] = []
        for row in table.dropFirst() {
            guard row.count >= needed, let when = formatter.date(from: row[date]) ?? plain.date(from: row[date]) else { continue }
            let withWrite = number(row[inputWith]), withoutWrite = number(row[inputWithout])
            let record = AnalyticsCursorRecord(seconds: Int64(when.timeIntervalSince1970), model: row[model].isEmpty ? "unknown" : row[model],
                                               input: withoutWrite, cacheWrite: max(0, withWrite - withoutWrite),
                                               cacheRead: number(row[cacheRead]), output: number(row[output]))
            if record.counts.total > 0 { records.append(record) }
        }
        return records
    }
}

extension AnalyticsStore {
    /// Replaces every Cursor bucket from the earliest exported event onward, so corrections and backfills win and
    /// a windowed export can never erase older history. Returns whether anything changed.
    @discardableResult
    mutating func replaceCursorUsage(_ records: [AnalyticsCursorRecord]) -> Bool {
        guard let earliest = records.map({ AnalyticsTime.halfHour(Double($0.seconds)) }).min() else { return false }
        var rebuilt: [AnalyticsBucketKey: AnalyticsBucket] = [:]
        for record in records {
            let key = AnalyticsBucketKey(source: .cursor, model: record.model, halfHour: AnalyticsTime.halfHour(Double(record.seconds)))
            rebuilt[key, default: AnalyticsBucket()].add(record.counts, conversations: 1, tier: nil)
        }
        let before = buckets.filter { $0.key.source == .cursor && $0.key.halfHour >= earliest }
        // The earliest half hour may also hold older events outside a windowed export; never shrink it.
        for (key, bucket) in rebuilt where key.halfHour == earliest {
            if let stored = before[key], stored.counts.total > bucket.counts.total { rebuilt[key] = stored }
        }
        guard before != rebuilt else { return false }
        for key in before.keys { buckets[key] = nil }
        for (key, bucket) in rebuilt { buckets[key] = bucket }
        return true
    }
}
