import Foundation

/// Minimal Zstandard decoder (RFC 8878) for Codex's compressed rollouts (`rollout-*.jsonl.zst`).
/// No dictionaries; checksums are skipped. Single-segment frames need the whole output as the
/// window, so the result is materialized in memory (spec §1.1: TokenTracker caps it at 256 MiB).
enum AnalyticsZstd {
    enum Failure: Error { case corrupt, tooLarge }

    static func decompress(_ data: Data, limit: Int) throws -> Data {
        try data.withUnsafeBytes { raw -> Data in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return Data() }
            var decoder = Decoder(input: base, count: raw.count, limit: limit)
            try decoder.run()
            return decoder.output.takeData()
        }
    }
}

private final class OutputBuffer {
    private(set) var ptr: UnsafeMutablePointer<UInt8>
    private(set) var count = 0
    private var capacity: Int

    init(capacity: Int) {
        self.capacity = max(capacity, 1 << 16)
        ptr = malloc(self.capacity)!.assumingMemoryBound(to: UInt8.self)
    }

    deinit { if capacity > 0 { free(ptr) } }

    func reserve(_ extra: Int, limit: Int) throws {
        guard extra >= 0, extra <= limit - count else { throw AnalyticsZstd.Failure.tooLarge }
        let needed = count + extra
        guard needed > capacity else { return }
        var next = capacity
        while next < needed { next *= 2 }
        next = min(max(next, needed), limit)
        guard let grown = realloc(ptr, next) else { throw AnalyticsZstd.Failure.tooLarge }
        ptr = grown.assumingMemoryBound(to: UInt8.self)
        capacity = next
    }

    func append(_ source: UnsafePointer<UInt8>, _ length: Int) {
        (ptr + count).update(from: source, count: length)
        count += length
    }

    func appendRepeated(_ byte: UInt8, _ length: Int) {
        (ptr + count).initialize(repeating: byte, count: length)
        count += length
    }

    /// Byte-wise so overlapping matches (offset < length) replicate correctly.
    func copyMatch(offset: Int, length: Int) {
        var src = ptr + (count - offset)
        var dst = ptr + count
        if offset >= length {
            dst.update(from: src, count: length)
        } else {
            for _ in 0..<length {
                dst.pointee = src.pointee
                dst += 1
                src += 1
            }
        }
        count += length
    }

    func takeData() -> Data {
        let data = Data(bytesNoCopy: ptr, count: count, deallocator: .free)
        capacity = 0
        return data
    }
}

private struct ForwardBits {
    let base: UnsafePointer<UInt8>
    let count: Int
    var bit = 0

    mutating func read(_ n: Int) throws -> Int {
        var value = 0
        for i in 0..<n {
            let byte = (bit + i) >> 3
            guard byte < count else { throw AnalyticsZstd.Failure.corrupt }
            value |= Int((base[byte] >> UInt8((bit + i) & 7)) & 1) << i
        }
        bit += n
        return value
    }

    var bytesConsumed: Int { (bit + 7) >> 3 }
}

/// Reads a zstd backward bitstream: starts at the highest set bit of the last byte, moves to bit 0.
private struct ReverseBits {
    let base: UnsafePointer<UInt8>
    let count: Int
    private(set) var offset: Int

    init(_ base: UnsafePointer<UInt8>, _ count: Int) throws {
        guard count > 0, base[count - 1] != 0 else { throw AnalyticsZstd.Failure.corrupt }
        self.base = base
        self.count = count
        offset = (count - 1) * 8 + (7 - base[count - 1].leadingZeroBitCount)
    }

    var overflowed: Bool { offset < 0 }

    mutating func read(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        offset -= n
        if offset >= 0 { return peek(offset, n) }
        let available = n + offset
        return available > 0 ? peek(0, available) << (-offset) : 0
    }

    private func peek(_ position: Int, _ n: Int) -> Int {
        let byte = position >> 3
        var word: UInt64 = 0
        if byte + 8 <= count {
            word = UnsafeRawPointer(base + byte).loadUnaligned(as: UInt64.self)
        } else {
            for i in 0..<(count - byte) { word |= UInt64(base[byte + i]) << UInt64(i * 8) }
        }
        return Int((word >> UInt64(position & 7)) & ((1 << UInt64(n)) - 1))
    }
}

private struct FSETable {
    var accuracyLog = 0
    var symbols: [UInt8] = []
    var bits: [UInt8] = []
    var base: [Int] = []

    static func rle(_ symbol: UInt8) -> FSETable {
        FSETable(accuracyLog: 0, symbols: [symbol], bits: [0], base: [0])
    }

    init() {}

    init(accuracyLog: Int, symbols: [UInt8], bits: [UInt8], base: [Int]) {
        self.accuracyLog = accuracyLog
        self.symbols = symbols
        self.bits = bits
        self.base = base
    }

    init(frequencies: [Int], accuracyLog: Int) throws {
        let size = 1 << accuracyLog
        var symbols = [UInt8](repeating: 0, count: size)
        var next = [Int](repeating: 0, count: frequencies.count)
        var high = size
        for (symbol, frequency) in frequencies.enumerated() where frequency == -1 {
            high -= 1
            symbols[high] = UInt8(symbol)
            next[symbol] = 1
        }
        let step = (size >> 1) + (size >> 3) + 3
        var position = 0
        for (symbol, frequency) in frequencies.enumerated() where frequency > 0 {
            next[symbol] = frequency
            for _ in 0..<frequency {
                symbols[position] = UInt8(symbol)
                repeat { position = (position + step) & (size - 1) } while position >= high
            }
        }
        guard position == 0 else { throw AnalyticsZstd.Failure.corrupt }
        var bits = [UInt8](repeating: 0, count: size)
        var base = [Int](repeating: 0, count: size)
        for state in 0..<size {
            let symbol = Int(symbols[state])
            let value = next[symbol]
            next[symbol] += 1
            let nb = accuracyLog - (Int.bitWidth - 1 - value.leadingZeroBitCount)
            bits[state] = UInt8(nb)
            base[state] = (value << nb) - size
        }
        self.init(accuracyLog: accuracyLog, symbols: symbols, bits: bits, base: base)
    }

    /// Normalized-count header (RFC 8878 §4.1.1). Returns the table and the header byte length.
    static func read(_ base: UnsafePointer<UInt8>, _ count: Int, maxLog: Int, maxSymbol: Int) throws -> (FSETable, Int) {
        var bits = ForwardBits(base: base, count: count)
        let accuracyLog = try bits.read(4) + 5
        guard accuracyLog <= maxLog else { throw AnalyticsZstd.Failure.corrupt }
        var remaining = 1 << accuracyLog
        var frequencies: [Int] = []
        while remaining > 0 && frequencies.count <= maxSymbol {
            let width = (Int.bitWidth - (remaining + 1).leadingZeroBitCount)
            var value = try bits.read(width)
            let lowerMask = (1 << (width - 1)) - 1
            let threshold = (1 << width) - 1 - (remaining + 1)
            if value & lowerMask < threshold {
                bits.bit -= 1
                value &= lowerMask
            } else if value > lowerMask {
                value -= threshold
            }
            let probability = value - 1
            remaining -= abs(probability)
            frequencies.append(probability)
            if probability == 0 {
                var repeats = try bits.read(2)
                while true {
                    for _ in 0..<repeats where frequencies.count <= maxSymbol { frequencies.append(0) }
                    if repeats == 3 { repeats = try bits.read(2) } else { break }
                }
            }
        }
        guard remaining == 0, frequencies.count <= maxSymbol + 1 else { throw AnalyticsZstd.Failure.corrupt }
        return (try FSETable(frequencies: frequencies, accuracyLog: accuracyLog), bits.bytesConsumed)
    }

    func initialState(_ stream: inout ReverseBits) -> Int { stream.read(accuracyLog) }

    func update(_ state: inout Int, _ stream: inout ReverseBits) {
        state = base[state] + stream.read(Int(bits[state]))
    }
}

private struct HuffmanTable {
    var maxBits = 0
    var symbols: [UInt8] = []
    var lengths: [UInt8] = []

    static func read(_ base: UnsafePointer<UInt8>, _ count: Int) throws -> (HuffmanTable, Int) {
        guard count > 0 else { throw AnalyticsZstd.Failure.corrupt }
        let header = Int(base[0])
        var weights: [Int] = []
        var consumed = 1
        if header >= 128 {
            let symbolCount = header - 127
            consumed += (symbolCount + 1) / 2
            guard consumed <= count else { throw AnalyticsZstd.Failure.corrupt }
            for i in 0..<symbolCount {
                let byte = Int(base[1 + i / 2])
                weights.append(i % 2 == 0 ? byte >> 4 : byte & 15)
            }
        } else {
            consumed += header
            guard consumed <= count else { throw AnalyticsZstd.Failure.corrupt }
            let (table, tableSize) = try FSETable.read(base + 1, header, maxLog: 6, maxSymbol: 255)
            var stream = try ReverseBits(base + 1 + tableSize, header - tableSize)
            var state1 = table.initialState(&stream)
            var state2 = table.initialState(&stream)
            while weights.count < 255 {
                weights.append(Int(table.symbols[state1]))
                table.update(&state1, &stream)
                if stream.overflowed { weights.append(Int(table.symbols[state2])); break }
                weights.append(Int(table.symbols[state2]))
                table.update(&state2, &stream)
                if stream.overflowed { weights.append(Int(table.symbols[state1])); break }
            }
        }
        return (try build(weights), consumed)
    }

    /// Weights above 11 (Max_Number_of_Bits) or more than 255 explicit symbols are corrupt input;
    /// both are rejected before any shift or sum so hostile headers cannot trap.
    private static func build(_ partial: [Int]) throws -> HuffmanTable {
        guard partial.count <= 255, partial.allSatisfy({ (0...11).contains($0) }) else { throw AnalyticsZstd.Failure.corrupt }
        var sum = 0
        for weight in partial where weight > 0 { sum += 1 << (weight - 1) }
        guard sum > 0 else { throw AnalyticsZstd.Failure.corrupt }
        let maxBits = Int.bitWidth - sum.leadingZeroBitCount
        let leftover = (1 << maxBits) - sum
        guard leftover > 0, leftover & (leftover - 1) == 0, maxBits <= 11 else { throw AnalyticsZstd.Failure.corrupt }
        let weights = partial + [Int.bitWidth - leftover.leadingZeroBitCount]
        let lengths = weights.map { $0 > 0 ? maxBits + 1 - $0 : 0 }
        var rankCount = [Int](repeating: 0, count: maxBits + 2)
        for length in lengths where length > 0 { rankCount[length] += 1 }
        var rankStart = [Int](repeating: 0, count: maxBits + 2)
        var position = 0
        for length in stride(from: maxBits, through: 1, by: -1) {
            rankStart[length] = position
            position += rankCount[length] << (maxBits - length)
        }
        let size = 1 << maxBits
        var table = HuffmanTable(maxBits: maxBits, symbols: [UInt8](repeating: 0, count: size), lengths: [UInt8](repeating: 0, count: size))
        for (symbol, length) in lengths.enumerated() where length > 0 {
            let span = 1 << (maxBits - length)
            let start = rankStart[length]
            for i in start..<(start + span) {
                table.symbols[i] = UInt8(symbol)
                table.lengths[i] = UInt8(length)
            }
            rankStart[length] += span
        }
        return table
    }

    func decode(_ base: UnsafePointer<UInt8>, _ count: Int, into out: UnsafeMutablePointer<UInt8>, _ length: Int) throws {
        var stream = try ReverseBits(base, count)
        let mask = (1 << maxBits) - 1
        var state = stream.read(maxBits)
        for i in 0..<length {
            out[i] = symbols[state]
            let nb = Int(lengths[state])
            state = ((state << nb) + stream.read(nb)) & mask
        }
    }
}

private struct Decoder {
    let input: UnsafePointer<UInt8>
    let count: Int
    let limit: Int
    var position = 0
    let output: OutputBuffer
    var huffman: HuffmanTable?
    var tables = [FSETable(), FSETable(), FSETable()]
    var repeats = [1, 4, 8]
    var literals = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 17)

    init(input: UnsafePointer<UInt8>, count: Int, limit: Int) {
        self.input = input
        self.count = count
        self.limit = limit
        output = OutputBuffer(capacity: min(limit, count * 4))
    }

    mutating func run() throws {
        defer { literals.deallocate() }
        while position + 4 <= count {
            let magic = readLE(position, 4)
            position += 4
            if magic == 0xFD2F_B528 {
                try frame()
            } else if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
                guard position + 4 <= count else { throw AnalyticsZstd.Failure.corrupt }
                position += 4 + readLE(position, 4)
            } else {
                throw AnalyticsZstd.Failure.corrupt
            }
        }
        guard position == count else { throw AnalyticsZstd.Failure.corrupt }
    }

    private func readLE(_ at: Int, _ bytes: Int) -> Int {
        var value = 0
        for i in 0..<bytes { value |= Int(input[at + i]) << (8 * i) }
        return value
    }

    private mutating func frame() throws {
        guard position < count else { throw AnalyticsZstd.Failure.corrupt }
        let descriptor = Int(input[position])
        position += 1
        let singleSegment = descriptor & 0x20 != 0
        let hasChecksum = descriptor & 0x04 != 0
        guard descriptor & 0x03 == 0 else { throw AnalyticsZstd.Failure.corrupt }
        if !singleSegment { position += 1 }
        let sizeBytes = [singleSegment ? 1 : 0, 2, 4, 8][descriptor >> 6]
        guard position + sizeBytes <= count else { throw AnalyticsZstd.Failure.corrupt }
        var declared: UInt64 = 0
        for i in 0..<sizeBytes { declared |= UInt64(input[position + i]) << UInt64(8 * i) }
        if sizeBytes == 2 { declared += 256 }
        position += sizeBytes
        guard declared <= UInt64(limit) else { throw AnalyticsZstd.Failure.tooLarge }
        if declared > 0 { try output.reserve(Int(declared), limit: limit) }
        huffman = nil
        tables = [FSETable(), FSETable(), FSETable()]
        repeats = [1, 4, 8]
        var last = false
        while !last {
            guard position + 3 <= count else { throw AnalyticsZstd.Failure.corrupt }
            let header = readLE(position, 3)
            position += 3
            last = header & 1 != 0
            let size = header >> 3
            switch (header >> 1) & 3 {
            case 0:
                guard position + size <= count else { throw AnalyticsZstd.Failure.corrupt }
                try output.reserve(size, limit: limit)
                output.append(input + position, size)
                position += size
            case 1:
                guard position < count else { throw AnalyticsZstd.Failure.corrupt }
                try output.reserve(size, limit: limit)
                output.appendRepeated(input[position], size)
                position += 1
            case 2:
                guard position + size <= count, size <= 1 << 17 else { throw AnalyticsZstd.Failure.corrupt }
                try compressedBlock(input + position, size)
                position += size
            default:
                throw AnalyticsZstd.Failure.corrupt
            }
        }
        if hasChecksum { position += 4 }
    }

    private mutating func compressedBlock(_ block: UnsafePointer<UInt8>, _ size: Int) throws {
        let (literalCount, used) = try readLiterals(block, size)
        try sequences(block + used, size - used, literalCount: literalCount)
    }

    private mutating func readLiterals(_ block: UnsafePointer<UInt8>, _ size: Int) throws -> (Int, Int) {
        guard size > 0 else { throw AnalyticsZstd.Failure.corrupt }
        let b0 = Int(block[0])
        let type = b0 & 3
        let format = (b0 >> 2) & 3
        func byte(_ i: Int) throws -> Int {
            guard i < size else { throw AnalyticsZstd.Failure.corrupt }
            return Int(block[i])
        }
        if type < 2 {
            var regenerated = b0 >> 3
            var header = 1
            if format == 1 { regenerated = (b0 >> 4) + (try byte(1) << 4); header = 2 }
            if format == 3 { regenerated = (b0 >> 4) + (try byte(1) << 4) + (try byte(2) << 12); header = 3 }
            guard regenerated <= 1 << 17 else { throw AnalyticsZstd.Failure.corrupt }
            if type == 0 {
                guard header + regenerated <= size else { throw AnalyticsZstd.Failure.corrupt }
                literals.update(from: block + header, count: regenerated)
                return (regenerated, header + regenerated)
            }
            literals.initialize(repeating: UInt8(try byte(header)), count: regenerated)
            return (regenerated, header + 1)
        }
        var header = 3
        var regenerated = 0
        var compressed = 0
        let streams = format == 0 ? 1 : 4
        switch format {
        case 0, 1:
            let h = b0 | (try byte(1) << 8) | (try byte(2) << 16)
            regenerated = (h >> 4) & 0x3FF
            compressed = (h >> 14) & 0x3FF
        case 2:
            let h = b0 | (try byte(1) << 8) | (try byte(2) << 16) | (try byte(3) << 24)
            regenerated = (h >> 4) & 0x3FFF
            compressed = (h >> 18) & 0x3FFF
            header = 4
        default:
            let h = b0 | (try byte(1) << 8) | (try byte(2) << 16) | (try byte(3) << 24) | (try byte(4) << 32)
            regenerated = (h >> 4) & 0x3FFFF
            compressed = (h >> 22) & 0x3FFFF
            header = 5
        }
        guard header + compressed <= size, regenerated <= 1 << 17 else { throw AnalyticsZstd.Failure.corrupt }
        var data = block + header
        var remaining = compressed
        if type == 2 {
            let (table, used) = try HuffmanTable.read(data, remaining)
            huffman = table
            data += used
            remaining -= used
        }
        guard let table = huffman else { throw AnalyticsZstd.Failure.corrupt }
        if streams == 1 {
            try table.decode(data, remaining, into: literals, regenerated)
        } else {
            guard remaining >= 6 else { throw AnalyticsZstd.Failure.corrupt }
            let sizes = [Int(data[0]) | Int(data[1]) << 8, Int(data[2]) | Int(data[3]) << 8, Int(data[4]) | Int(data[5]) << 8]
            let fourth = remaining - 6 - sizes.reduce(0, +)
            guard fourth > 0 else { throw AnalyticsZstd.Failure.corrupt }
            let segment = (regenerated + 3) / 4
            var source = data + 6
            for (index, streamSize) in (sizes + [fourth]).enumerated() {
                let length = index < 3 ? segment : regenerated - 3 * segment
                guard length >= 0 else { throw AnalyticsZstd.Failure.corrupt }
                try table.decode(source, streamSize, into: literals + index * segment, length)
                source += streamSize
            }
        }
        return (regenerated, header + compressed)
    }

    private mutating func sequences(_ data: UnsafePointer<UInt8>, _ size: Int, literalCount: Int) throws {
        guard size > 0 else { throw AnalyticsZstd.Failure.corrupt }
        var used = 1
        var sequenceCount = Int(data[0])
        if sequenceCount >= 128 {
            guard size >= 3 || (sequenceCount < 255 && size >= 2) else { throw AnalyticsZstd.Failure.corrupt }
            if sequenceCount < 255 {
                sequenceCount = ((sequenceCount - 128) << 8) + Int(data[1])
                used = 2
            } else {
                sequenceCount = Int(data[1]) + (Int(data[2]) << 8) + 0x7F00
                used = 3
            }
        }
        if sequenceCount == 0 {
            try output.reserve(literalCount, limit: limit)
            output.append(literals, literalCount)
            return
        }
        guard used < size else { throw AnalyticsZstd.Failure.corrupt }
        let modes = Int(data[used])
        used += 1
        for (slot, shift) in [(0, 6), (1, 4), (2, 2)] {
            used += try readTable(slot: slot, mode: (modes >> shift) & 3, data + used, size - used)
        }
        try execute(data + used, size - used, sequenceCount: sequenceCount, literalCount: literalCount)
    }

    private mutating func readTable(slot: Int, mode: Int, _ data: UnsafePointer<UInt8>, _ size: Int) throws -> Int {
        let spec = SequenceCodes.specs[slot]
        switch mode {
        case 0:
            tables[slot] = SequenceCodes.predefined[slot]
            return 0
        case 1:
            guard size > 0 else { throw AnalyticsZstd.Failure.corrupt }
            tables[slot] = .rle(data[0])
            return 1
        case 2:
            let (table, used) = try FSETable.read(data, size, maxLog: spec.maxLog, maxSymbol: spec.maxSymbol)
            tables[slot] = table
            return used
        default:
            guard !tables[slot].symbols.isEmpty else { throw AnalyticsZstd.Failure.corrupt }
            return 0
        }
    }

    private mutating func execute(_ data: UnsafePointer<UInt8>, _ size: Int, sequenceCount: Int, literalCount: Int) throws {
        var stream = try ReverseBits(data, size)
        let ll = tables[0], of = tables[1], ml = tables[2]
        var llState = ll.initialState(&stream)
        var ofState = of.initialState(&stream)
        var mlState = ml.initialState(&stream)
        var literalPosition = 0
        for index in 0..<sequenceCount {
            let ofCode = Int(of.symbols[ofState])
            let mlCode = Int(ml.symbols[mlState])
            let llCode = Int(ll.symbols[llState])
            guard ofCode <= 31, mlCode <= 52, llCode <= 35 else { throw AnalyticsZstd.Failure.corrupt }
            let offsetValue = (1 << ofCode) + stream.read(ofCode)
            let matchLength = SequenceCodes.matchBase[mlCode] + stream.read(SequenceCodes.matchBits[mlCode])
            let literalLength = SequenceCodes.literalBase[llCode] + stream.read(SequenceCodes.literalBits[llCode])
            if index + 1 < sequenceCount {
                ll.update(&llState, &stream)
                ml.update(&mlState, &stream)
                of.update(&ofState, &stream)
            }
            let offset = resolveOffset(offsetValue, literalLength: literalLength)
            guard literalPosition + literalLength <= literalCount else { throw AnalyticsZstd.Failure.corrupt }
            try output.reserve(literalLength + matchLength, limit: limit)
            output.append(literals + literalPosition, literalLength)
            literalPosition += literalLength
            guard offset > 0, offset <= output.count else { throw AnalyticsZstd.Failure.corrupt }
            output.copyMatch(offset: offset, length: matchLength)
        }
        let rest = literalCount - literalPosition
        try output.reserve(rest, limit: limit)
        output.append(literals + literalPosition, rest)
    }

    private mutating func resolveOffset(_ value: Int, literalLength: Int) -> Int {
        if value > 3 {
            let offset = value - 3
            repeats = [offset, repeats[0], repeats[1]]
            return offset
        }
        let index = literalLength == 0 ? value : value - 1
        switch index {
        case 0:
            return repeats[0]
        case 1:
            repeats = [repeats[1], repeats[0], repeats[2]]
        case 2:
            repeats = [repeats[2], repeats[0], repeats[1]]
        default:
            repeats = [max(repeats[0] - 1, 1), repeats[0], repeats[1]]
        }
        return repeats[0]
    }
}

private enum SequenceCodes {
    static let specs: [(maxLog: Int, maxSymbol: Int)] = [(9, 35), (8, 31), (9, 52)]

    static let literalBase = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    static let literalBits = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    static let matchBase = Array(3...34) + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539]
    static let matchBits = [Int](repeating: 0, count: 32) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]

    static let predefined: [FSETable] = [
        try! FSETable(frequencies: [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1], accuracyLog: 6),
        try! FSETable(frequencies: [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1], accuracyLog: 5),
        try! FSETable(frequencies: [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1], accuracyLog: 6),
    ]
}
