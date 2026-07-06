import Foundation

enum CSVExport {
    /// RFC 4180 field escaping plus spreadsheet formula neutralization.
    /// Prefixing formula-looking cells with an apostrophe keeps exported iOS data
    /// from executing if a user opens the CSV in Numbers, Excel, or Sheets.
    static func field(_ raw: String) -> String {
        var safe = raw
        if let first = safe.unicodeScalars.first,
           ["=", "+", "-", "@", "\t", "\r", "\n"].contains(String(first)) {
            safe = "'" + safe
        }
        safe = safe.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(safe)\""
    }

    static func row(_ fields: [String], lineEnding: String = "\n") -> String {
        fields.map(field).joined(separator: ",") + lineEnding
    }
}
