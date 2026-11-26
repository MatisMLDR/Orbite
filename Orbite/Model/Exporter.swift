import Foundation

/// A table to export: one header row, then values already turned into text.
nonisolated struct ExportTable: Sendable, Equatable {
    var columns: [String]
    var rows: [[String]]
}

nonisolated enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, json
    var id: Self { self }
    var label: String { self == .csv ? String(localized: "CSV (spreadsheet)") : "JSON" }
    var fileExtension: String { rawValue }
}

/// CSV (RFC 4180) and JSON from an export table, with no I/O.
nonisolated enum Exporter {
    static func csv(_ table: ExportTable) -> String {
        ([table.columns] + table.rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Quotes a field holding a comma, a quote or a line break, doubling its quotes.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// An array of objects; byte counts and seconds go out as numbers.
    static func json(_ table: ExportTable) throws -> Data {
        let numeric: Set<String> = ["bytes_in", "bytes_out", "bytes_total"]
        let objects: [[String: Any]] = table.rows.map { row in
            var object: [String: Any] = [:]
            for (index, column) in table.columns.enumerated() where index < row.count {
                let value = row[index]
                if numeric.contains(column), let number = UInt64(value) {
                    object[column] = number
                } else if !value.isEmpty {
                    object[column] = value
                }
            }
            return object
        }
        return try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
    }

    static func iso(_ second: Int?) -> String {
        guard let second else { return "" }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(second)))
    }
}
