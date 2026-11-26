import Darwin
import Foundation

/// Read-only MaxMind DB (.mmdb) reader over a memory-mapped file.
/// Format: https://maxmind.github.io/MaxMind-DB/ — binary search tree, then a data section.
nonisolated final class MMDB: @unchecked Sendable {
    indirect enum Value: Sendable {
        case string(String)
        case double(Double)
        case float(Float)
        case uint(UInt64)
        case int(Int64)
        case bool(Bool)
        case map([String: Value])
        case array([Value])
        case bytes

        subscript(key: String) -> Value? {
            if case .map(let map) = self { return map[key] }
            return nil
        }

        subscript(index: Int) -> Value? {
            if case .array(let array) = self, index < array.count { return array[index] }
            return nil
        }

        var string: String? { if case .string(let s) = self { return s }; return nil }

        var number: Double? {
            switch self {
            case .double(let d): d
            case .float(let f): Double(f)
            case .uint(let u): Double(u)
            case .int(let i): Double(i)
            default: nil
            }
        }
    }

    struct OpenError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let nodeCount: Int
    let recordSize: Int
    let ipVersion: Int
    let databaseType: String
    let buildDate: Date?

    private let base: UnsafeRawPointer
    private let length: Int
    private let treeSize: Int
    private var ipv4Start = 0

    init(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw OpenError(message: String(localized: "Cannot open \(path)")) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { throw OpenError(message: String(localized: "Empty file")) }
        let size = Int(info.st_size)
        guard let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), mapped != MAP_FAILED else {
            throw OpenError(message: String(localized: "mmap failed"))
        }
        let pointer = UnsafeRawPointer(mapped)
        base = pointer
        length = size

        // Metadata follows the last "\xAB\xCD\xEFMaxMind.com" marker.
        let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        var metadataStart: Int?
        var position = size - marker.count
        let floor = max(0, size - 128 * 1024)
        while position >= floor {
            if (0..<marker.count).allSatisfy({ pointer.load(fromByteOffset: position + $0, as: UInt8.self) == marker[$0] }) {
                metadataStart = position + marker.count
                break
            }
            position -= 1
        }
        guard let metadataStart else {
            munmap(mapped, size)
            throw OpenError(message: String(localized: "MMDB metadata not found"))
        }

        var cursor = metadataStart
        let metadata = Self.decode(pointer, size, &cursor, pointerBase: metadataStart)
        guard let nodes = metadata["node_count"]?.number, let record = metadata["record_size"]?.number,
              [24, 28, 32].contains(Int(record)) else {
            munmap(mapped, size)
            throw OpenError(message: String(localized: "Invalid MMDB metadata"))
        }
        nodeCount = Int(nodes)
        recordSize = Int(record)
        ipVersion = Int(metadata["ip_version"]?.number ?? 6)
        databaseType = metadata["database_type"]?.string ?? ""
        buildDate = metadata["build_epoch"]?.number.map { Date(timeIntervalSince1970: $0) }
        treeSize = recordSize * 2 / 8 * nodeCount

        if ipVersion == 6 {
            var node = 0
            for _ in 0..<96 where node < nodeCount { node = readRecord(node, bit: 0) }
            ipv4Start = node
        }
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), length)
    }

    func lookup(_ address: String) -> Value? {
        guard let bytes = IPAddress.bytes(address) else { return nil }
        if bytes.count == 16 && ipVersion == 4 { return nil }
        var node = bytes.count == 4 && ipVersion == 6 ? ipv4Start : 0
        for index in 0..<(bytes.count * 8) {
            guard node < nodeCount else { break }
            let bit = Int(bytes[index >> 3] >> (7 - UInt8(index & 7))) & 1
            node = readRecord(node, bit: bit)
        }
        guard node > nodeCount else { return nil }
        var cursor = treeSize + (node - nodeCount)
        let dataStart = treeSize + 16
        guard cursor < length else { return nil }
        return Self.decode(base, length, &cursor, pointerBase: dataStart)
    }

    private func byte(_ offset: Int) -> Int {
        Int(base.load(fromByteOffset: offset, as: UInt8.self))
    }

    private func readRecord(_ node: Int, bit: Int) -> Int {
        let offset = node * recordSize / 4
        switch recordSize {
        case 24:
            let o = offset + bit * 3
            return byte(o) << 16 | byte(o + 1) << 8 | byte(o + 2)
        case 28:
            if bit == 0 {
                return (byte(offset + 3) & 0xF0) << 20 | byte(offset) << 16 | byte(offset + 1) << 8 | byte(offset + 2)
            }
            return (byte(offset + 3) & 0x0F) << 24 | byte(offset + 4) << 16 | byte(offset + 5) << 8 | byte(offset + 6)
        default:
            let o = offset + bit * 4
            return byte(o) << 24 | byte(o + 1) << 16 | byte(o + 2) << 8 | byte(o + 3)
        }
    }

    private static func decode(_ base: UnsafeRawPointer, _ length: Int, _ cursor: inout Int, pointerBase: Int, depth: Int = 0) -> Value {
        func byte() -> Int {
            guard cursor < length else { return 0 }
            defer { cursor += 1 }
            return Int(base.load(fromByteOffset: cursor, as: UInt8.self))
        }
        func bigEndian(_ count: Int) -> UInt64 {
            var value: UInt64 = 0
            for _ in 0..<count { value = value << 8 | UInt64(byte()) }
            return value
        }
        guard depth < 32, cursor < length else { return .bytes }

        let control = byte()
        var type = control >> 5
        if type == 1 { // pointer
            let sizeBits = (control >> 3) & 0x3
            let high = control & 0x7
            let pointer: Int
            switch sizeBits {
            case 0: pointer = high << 8 | byte()
            case 1: pointer = (high << 16 | byte() << 8 | byte()) + 2048
            case 2: pointer = (high << 24 | byte() << 16 | byte() << 8 | byte()) + 526_336
            default: pointer = Int(bigEndian(4))
            }
            var target = pointerBase + pointer
            return decode(base, length, &target, pointerBase: pointerBase, depth: depth + 1)
        }
        if type == 0 { type = 7 + byte() }

        var size = control & 0x1F
        switch size {
        case 29: size = 29 + byte()
        case 30: size = 285 + Int(bigEndian(2))
        case 31: size = 65_821 + Int(bigEndian(3))
        default: break
        }

        switch type {
        case 2: // UTF-8 string
            guard cursor + size <= length else { return .bytes }
            let buffer = UnsafeRawBufferPointer(start: base + cursor, count: size)
            cursor += size
            return .string(String(decoding: buffer, as: UTF8.self))
        case 3:
            return .double(Double(bitPattern: bigEndian(8)))
        case 15:
            return .float(Float(bitPattern: UInt32(bigEndian(4))))
        case 5, 6, 9:
            return .uint(bigEndian(size))
        case 10: // uint128: keep the low 64 bits
            if size > 8 { cursor += size - 8; return .uint(bigEndian(8)) }
            return .uint(bigEndian(size))
        case 8:
            let raw = bigEndian(size)
            return .int(Int64(Int32(truncatingIfNeeded: raw)))
        case 14:
            return .bool(size != 0)
        case 7:
            var map: [String: Value] = [:]
            map.reserveCapacity(size)
            for _ in 0..<size {
                let key = decode(base, length, &cursor, pointerBase: pointerBase, depth: depth + 1)
                let value = decode(base, length, &cursor, pointerBase: pointerBase, depth: depth + 1)
                if let key = key.string { map[key] = value }
            }
            return .map(map)
        case 11:
            var array: [Value] = []
            array.reserveCapacity(size)
            for _ in 0..<size {
                array.append(decode(base, length, &cursor, pointerBase: pointerBase, depth: depth + 1))
            }
            return .array(array)
        default: // bytes, data cache container, end marker
            cursor += size
            return .bytes
        }
    }
}

nonisolated struct GeoPlace: Sendable, Hashable, Codable {
    var city: String?
    var region: String?
    var countryCode: String?
    var country: String?
    var latitude: Double
    var longitude: Double
}

nonisolated struct NetworkOwner: Sendable, Hashable, Codable {
    var number: Int?
    var organization: String?
}

/// DB-IP City Lite + ASN Lite.
nonisolated final class GeoDatabase: @unchecked Sendable {
    let city: MMDB?
    let asn: MMDB?

    init(cityPath: String?, asnPath: String?) {
        city = cityPath.flatMap { try? MMDB(path: $0) }
        asn = asnPath.flatMap { try? MMDB(path: $0) }
    }

    var isUsable: Bool { city != nil }

    func place(for address: String) -> GeoPlace? {
        guard let record = city?.lookup(address),
              let latitude = record["location"]?["latitude"]?.number,
              let longitude = record["location"]?["longitude"]?.number else { return nil }
        return GeoPlace(
            city: Self.name(record["city"]),
            region: Self.name(record["subdivisions"]?[0]),
            countryCode: record["country"]?["iso_code"]?.string,
            country: Self.name(record["country"]),
            latitude: latitude,
            longitude: longitude)
    }

    func owner(for address: String) -> NetworkOwner? {
        guard let record = asn?.lookup(address) else { return nil }
        let number = record["autonomous_system_number"]?.number.map { Int($0) }
        let organization = record["autonomous_system_organization"]?.string
        guard number != nil || organization != nil else { return nil }
        return NetworkOwner(number: number, organization: organization)
    }

    /// The name in the app's language when the database has one, English otherwise.
    private static func name(_ value: MMDB.Value?) -> String? {
        guard let names = value?["names"] else { return nil }
        let language = Format.locale.language.languageCode?.identifier ?? "en"
        return names[language]?.string ?? names["en"]?.string
    }
}
