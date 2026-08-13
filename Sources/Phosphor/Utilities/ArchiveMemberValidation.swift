import Foundation

enum ArchiveMemberValidation {
    /// BSD/GNU tar verbose listings begin each member with a type character.
    /// Phosphor archives need only regular files and directories; links, devices,
    /// FIFOs, and any unrecognized output are rejected before extraction.
    static func allEntriesAreRegularFilesOrDirectories(_ verboseListing: String) -> Bool {
        let lines = verboseListing
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            guard let type = line.first else { return false }
            return type == "-" || type == "d"
        }
    }
}
