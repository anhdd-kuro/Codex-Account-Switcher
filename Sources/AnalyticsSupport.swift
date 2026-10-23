import Foundation

/// Stable 64-bit FNV-1a; Swift's `Hasher` is seeded per process, so it cannot key persisted sets.
enum AnalyticsHash {
    static func of(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

enum AnalyticsFingerprint {
    static let span = 4096

    /// FNV-1a over the first `span` bytes and the `span` bytes ending at `offset`.
    static func of(path: String, upTo offset: Int64) -> UInt64? {
        guard offset > 0, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let length = Int(min(Int64(span), offset))
        guard let head = try? handle.read(upToCount: length),
              (try? handle.seek(toOffset: UInt64(offset - Int64(length)))) != nil,
              let tail = try? handle.read(upToCount: length), head.count == length, tail.count == length else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in head + tail {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

typealias AnalyticsLine = UnsafeRawBufferPointer

extension UnsafeRawBufferPointer {
    func contains(_ needle: StaticString) -> Bool {
        guard let base = baseAddress, count >= needle.utf8CodeUnitCount else { return false }
        return memmem(base, count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    func hasPrefix(_ needle: StaticString) -> Bool {
        guard let base = baseAddress, count >= needle.utf8CodeUnitCount else { return false }
        return memcmp(base, needle.utf8Start, needle.utf8CodeUnitCount) == 0
    }

    /// The string value of the first `"key":"…"` occurrence, without JSON-parsing the line.
    func firstStringValue(after key: StaticString, within limit: Int = .max) -> String? {
        guard let base = baseAddress else { return nil }
        let span = Swift.min(count, limit)
        guard let hit = memmem(base, span, key.utf8Start, key.utf8CodeUnitCount) else { return nil }
        let start = hit.assumingMemoryBound(to: UInt8.self) + key.utf8CodeUnitCount
        let end = base.assumingMemoryBound(to: UInt8.self) + count
        var cursor = start
        while cursor < end, cursor.pointee != UInt8(ascii: "\"") { cursor += 1 }
        guard cursor < end else { return nil }
        return String(decoding: UnsafeBufferPointer(start: start, count: cursor - start), as: UTF8.self)
    }

    func jsonObject() -> [String: Any]? {
        guard let base = baseAddress, count > 1 else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum AnalyticsLines {
    /// Calls `body` for every newline-terminated line of `buffer`; returns the bytes consumed.
    /// With `includeTail`, a final unterminated line is delivered too (immutable snapshots).
    /// Largest token count accepted from one usage field.
    static let maxTokenCount = 1_000_000_000_000

    /// Longest record handed to a parser; anything longer is skipped and reported (no real log line is near this).
    static let maxRecordBytes = 64 << 20

    /// Lines longer than `maxRecordBytes` are dropped and reported through `oversized`.
    @discardableResult
    static func forEach(in buffer: UnsafeRawBufferPointer, includeTail: Bool, oversized: () -> Void = {}, _ body: (AnalyticsLine) -> Void) -> Int {
        guard let base = buffer.baseAddress else { return 0 }
        func deliver(_ start: Int, _ length: Int) {
            guard length > 0 else { return }
            guard length <= maxRecordBytes else { return oversized() }
            body(UnsafeRawBufferPointer(start: base + start, count: length))
        }
        var start = 0
        while start < buffer.count {
            guard let newline = memchr(base + start, 0x0A, buffer.count - start) else {
                if includeTail { deliver(start, buffer.count - start) }
                return includeTail ? buffer.count : start
            }
            let end = UnsafeRawPointer(newline) - base
            var length = end - start
            if length > 0, (base + start + length - 1).load(as: UInt8.self) == 0x0D { length -= 1 }
            deliver(start, length)
            start = end + 1
        }
        return start
    }

    /// Streams `path` from `offset` in fixed chunks and returns the offset after the last complete line.
    static func stream(path: String, from offset: Int64, chunkSize: Int = 8 << 20, progress: (Int) -> Void,
                       oversized: () -> Void = {}, _ body: (AnalyticsLine) -> Void) -> Int64 {
        streamRecords(path: path, from: offset, discardingFrom: nil, chunkSize: chunkSize, progress: progress, oversized: oversized, body).offset
    }

    struct StreamResult {
        /// End of the last complete record handled (delivered or discarded).
        let offset: Int64
        /// Read position inside an oversized record still being discarded at EOF; resume there next time.
        let discardingFrom: Int64?
    }

    /// Never reads the whole file; a trailing partial line under the cap is left for the next scan
    /// (spec §1.2). A record longer than `maxRecordBytes` is reported once, when the cap is crossed,
    /// and discarded up to its newline without being kept; `discardingFrom` carries that state across scans.
    static func streamRecords(path: String, from offset: Int64, discardingFrom: Int64?, chunkSize: Int = 8 << 20,
                              progress: (Int) -> Void, oversized: () -> Void = {}, _ body: (AnalyticsLine) -> Void) -> StreamResult {
        let readStart = discardingFrom ?? offset
        guard let handle = FileHandle(forReadingAtPath: path) else { return StreamResult(offset: offset, discardingFrom: discardingFrom) }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(readStart)) } catch { return StreamResult(offset: offset, discardingFrom: discardingFrom) }
        var committed = offset
        var position = readStart
        var carry = Data()
        var skipping = discardingFrom != nil
        var reading = true
        while reading {
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    reading = false
                    return
                }
                progress(chunk.count)
                let chunkStart = position
                position += Int64(chunk.count)
                var buffer = chunk
                var pending = carry
                carry = Data()
                if skipping || (!pending.isEmpty && pending.count + chunk.count > maxRecordBytes) {
                    let newline = chunk.firstIndex(of: 0x0A).map { $0 - chunk.startIndex }
                    let fits = !skipping && newline.map { pending.count + $0 <= maxRecordBytes } == true
                    if !fits {
                        if !skipping {
                            skipping = true
                            oversized()
                        }
                        pending = Data()
                        guard let newline else { return }
                        committed = chunkStart + Int64(newline + 1)
                        skipping = false
                        buffer = chunk.subdata(in: (chunk.startIndex + newline + 1)..<chunk.endIndex)
                    }
                }
                if !pending.isEmpty {
                    pending.append(chunk)
                    buffer = pending
                    pending = Data()
                }
                let consumed = buffer.withUnsafeBytes { forEach(in: $0, includeTail: false, oversized: oversized, body) }
                committed += Int64(consumed)
                carry = consumed == 0 ? buffer : (consumed < buffer.count ? buffer.subdata(in: consumed..<buffer.count) : Data())
            }
        }
        return StreamResult(offset: committed, discardingFrom: skipping ? position : nil)
    }
}

extension Int {
    /// Overflow-safe sum for token aggregates; clamps instead of trapping.
    func saturatingAdd(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }
}

extension Sequence {
    func saturatingSum(_ value: (Element) -> Int) -> Int {
        reduce(0) { $0.saturatingAdd(value($1)) }
    }
}

enum AnalyticsTime {
    /// Parses `YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM)` into Unix seconds.
    static func parse(_ text: String) -> Double? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 19, bytes[4] == 45, bytes[7] == 45, bytes[10] == 84 || bytes[10] == 32,
              bytes[13] == 58, bytes[16] == 58 else { return nil }
        func number(_ from: Int, _ length: Int) -> Int? {
            var value = 0
            for i in from..<(from + length) {
                let digit = Int(bytes[i]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        var index = 19
        var fraction = 0.0
        if index < bytes.count, bytes[index] == 46 {
            var scale = 0.1
            index += 1
            while index < bytes.count, (48...57).contains(bytes[index]) {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        var offset = 0
        if index < bytes.count {
            let sign = bytes[index]
            if sign == 43 || sign == 45, index + 6 <= bytes.count, let h = number(index + 1, 2), let m = number(index + 4, 2) {
                offset = (h * 3600 + m * 60) * (sign == 45 ? -1 : 1)
            } else if sign != 90 {
                return nil
            }
        }
        let days = daysFromCivil(year, month, day)
        return Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset) + fraction
    }

    /// Start of the UTC half-hour containing `seconds` (spec §0.1).
    static func halfHour(_ seconds: Double) -> Int64 {
        Int64((seconds / 1800).rounded(.down)) * 1800
    }

    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

struct AnalyticsFileStat: Equatable {
    let inode: UInt64
    let size: Int64
    let mtime: Double

    static func of(_ path: String) -> AnalyticsFileStat? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return AnalyticsFileStat(inode: UInt64(info.st_ino), size: Int64(info.st_size), mtime: mtime)
    }
}

extension Dictionary where Key == String, Value == Any {
    func object(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func string(_ key: String) -> String? { self[key] as? String }

    func trimmedString(_ key: String) -> String? {
        guard let value = self[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `Number(x)` floored at 0, as TokenTracker's `toNonNegativeInt`. Values above `maxTokenCount`
    /// (e.g. 1e100) are rejected as 0 instead of trapping in the Int conversion.
    func count(_ key: String) -> Int {
        guard let number = self[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value <= Double(AnalyticsLines.maxTokenCount) else { return 0 }
        return Int(value.rounded(.down))
    }

    /// Mirrors `Number.isFinite(Number(x)) && x >= 0`: null counts as 0, a missing key does not.
    func hasNumber(_ key: String) -> Bool {
        if self[key] is NSNull { return true }
        guard let number = self[key] as? NSNumber else { return false }
        return number.doubleValue.isFinite && number.doubleValue >= 0
    }
}
