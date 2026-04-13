import Foundation

/// Extracts Apple Notes from iOS backup NoteStore.sqlite.
///
/// Notes are stored in HomeDomain/Library/Notes/NoteStore.sqlite
/// The database uses Core Data (ZICCLOUDSYNCINGOBJECT table).
final class NotesExtractor {

    private let db: SQLiteReader

    struct Note: Identifiable, Hashable {
        let id: Int
        let title: String
        let snippet: String
        let htmlBody: String?
        let createdDate: Date?
        let modifiedDate: Date?
        let folderName: String
        let isPinned: Bool
        let isLocked: Bool
        let hasChecklist: Bool

        var displayTitle: String {
            if !title.isEmpty { return title }
            let cleaned = snippet.prefix(50)
            return cleaned.isEmpty ? "Untitled Note" : String(cleaned)
        }

        var formattedModifiedDate: String {
            modifiedDate?.shortString ?? "Unknown"
        }
    }

    struct NoteFolder: Identifiable, Hashable {
        let id: Int
        let name: String
        let noteCount: Int

        var displayName: String {
            if name == "DefaultFolder-CloudKit" { return "Notes" }
            if name == "Recently Deleted-Cloud" { return "Recently Deleted" }
            return name
        }
    }

    init(databasePath: String) throws {
        self.db = try SQLiteReader(path: databasePath)
    }

    /// Initialize from a backup directory.
    convenience init(backupPath: String) throws {
        let manifest = try BackupManifest(backupPath: backupPath)
        let candidates = try manifest.search("NoteStore.sqlite")
        let noteStoreEntry = candidates.first { $0.isFile && $0.relativePath.hasSuffix("NoteStore.sqlite") }

        guard let entry = noteStoreEntry else {
            throw NSError(domain: "Phosphor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "NoteStore.sqlite not found in backup"])
        }

        let filePath = entry.diskPath(backupRoot: backupPath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw NSError(domain: "Phosphor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "NoteStore.sqlite file not found on disk"])
        }

        try self.init(databasePath: filePath)
    }

    // MARK: - Folders

    func getFolders() throws -> [NoteFolder] {
        // Try the iCloud-era schema first (ZICCLOUDSYNCINGOBJECT)
        let tables = try db.tableNames()

        if tables.contains("ZICCLOUDSYNCINGOBJECT") {
            return try getFoldersModern()
        } else if tables.contains("ZNOTEBODY") {
            return try getFoldersLegacy()
        }

        return []
    }

    private func getFoldersModern() throws -> [NoteFolder] {
        let sql = """
            SELECT
                Z_PK,
                ZTITLE2 as title,
                (SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT n
                 WHERE n.ZFOLDER = f.Z_PK AND n.ZTITLE1 IS NOT NULL) as note_count
            FROM ZICCLOUDSYNCINGOBJECT f
            WHERE f.ZTITLE2 IS NOT NULL AND f.ZFOLDER IS NULL
            ORDER BY f.ZTITLE2
        """
        let rows = try db.query(sql)
        return rows.compactMap { row -> NoteFolder? in
            guard let pk = row["Z_PK"] as? Int,
                  let title = row["title"] as? String else { return nil }
            return NoteFolder(id: pk, name: title, noteCount: (row["note_count"] as? Int) ?? 0)
        }
    }

    private func getFoldersLegacy() throws -> [NoteFolder] {
        let sql = """
            SELECT Z_PK, ZTITLE as title,
                (SELECT COUNT(*) FROM ZNOTE WHERE ZSTORE = s.Z_PK) as note_count
            FROM ZSTORE s
            ORDER BY ZTITLE
        """
        let rows = try db.query(sql)
        return rows.compactMap { row -> NoteFolder? in
            guard let pk = row["Z_PK"] as? Int else { return nil }
            let title = (row["title"] as? String) ?? "Notes"
            return NoteFolder(id: pk, name: title, noteCount: (row["note_count"] as? Int) ?? 0)
        }
    }

    // MARK: - Notes

    func getNotes(folderId: Int? = nil) throws -> [Note] {
        let tables = try db.tableNames()

        if tables.contains("ZICCLOUDSYNCINGOBJECT") {
            return try getNotesModern(folderId: folderId)
        } else if tables.contains("ZNOTEBODY") {
            return try getNotesLegacy(folderId: folderId)
        }

        return []
    }

    private func getNotesModern(folderId: Int?) throws -> [Note] {
        var sql = """
            SELECT
                n.Z_PK,
                n.ZTITLE1,
                n.ZSNIPPET,
                n.ZCREATIONDATE3,
                n.ZMODIFICATIONDATE1,
                n.ZISPINNED,
                n.ZISPASSWORDPROTECTED,
                n.ZHASCHECKLIST,
                COALESCE(f.ZTITLE2, 'Notes') as folder_name,
                nb.ZHTMLSTRING
            FROM ZICCLOUDSYNCINGOBJECT n
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK
            LEFT JOIN ZICCLOUDSYNCINGOBJECT nb ON nb.ZNOTE = n.Z_PK AND nb.ZHTMLSTRING IS NOT NULL
            WHERE n.ZTITLE1 IS NOT NULL
        """
        if let folderId {
            sql += " AND n.ZFOLDER = \(folderId)"
        }
        sql += " ORDER BY n.ZMODIFICATIONDATE1 DESC"

        let rows = try db.query(sql)
        return rows.compactMap { row -> Note? in
            guard let pk = row["Z_PK"] as? Int else { return nil }

            let created = (row["ZCREATIONDATE3"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) }
            let modified = (row["ZMODIFICATIONDATE1"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) }

            return Note(
                id: pk,
                title: (row["ZTITLE1"] as? String) ?? "",
                snippet: (row["ZSNIPPET"] as? String) ?? "",
                htmlBody: row["ZHTMLSTRING"] as? String,
                createdDate: created,
                modifiedDate: modified,
                folderName: (row["folder_name"] as? String) ?? "Notes",
                isPinned: (row["ZISPINNED"] as? Int) == 1,
                isLocked: (row["ZISPASSWORDPROTECTED"] as? Int) == 1,
                hasChecklist: (row["ZHASCHECKLIST"] as? Int) == 1
            )
        }
    }

    private func getNotesLegacy(folderId: Int?) throws -> [Note] {
        var sql = """
            SELECT
                n.Z_PK,
                n.ZTITLE,
                n.ZSUMMARY,
                n.ZCREATIONDATE,
                n.ZMODIFICATIONDATE,
                nb.ZCONTENT,
                COALESCE(s.ZTITLE, 'Notes') as folder_name
            FROM ZNOTE n
            LEFT JOIN ZNOTEBODY nb ON nb.ZNOTE = n.Z_PK
            LEFT JOIN ZSTORE s ON n.ZSTORE = s.Z_PK
        """
        if let folderId {
            sql += " WHERE n.ZSTORE = \(folderId)"
        }
        sql += " ORDER BY n.ZMODIFICATIONDATE DESC"

        let rows = try db.query(sql)
        return rows.compactMap { row -> Note? in
            guard let pk = row["Z_PK"] as? Int else { return nil }
            let created = (row["ZCREATIONDATE"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) }
            let modified = (row["ZMODIFICATIONDATE"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) }

            return Note(
                id: pk,
                title: (row["ZTITLE"] as? String) ?? "",
                snippet: (row["ZSUMMARY"] as? String) ?? "",
                htmlBody: row["ZCONTENT"] as? String,
                createdDate: created,
                modifiedDate: modified,
                folderName: (row["folder_name"] as? String) ?? "Notes",
                isPinned: false,
                isLocked: false,
                hasChecklist: false
            )
        }
    }

    // MARK: - Search

    func searchNotes(_ query: String) throws -> [Note] {
        let allNotes = try getNotes()
        let q = query.lowercased()
        return allNotes.filter {
            $0.title.lowercased().contains(q) || $0.snippet.lowercased().contains(q)
        }
    }

    // MARK: - Export

    func exportNote(_ note: Note, to path: String) throws {
        if let html = note.htmlBody {
            let fullHTML = """
            <!DOCTYPE html>
            <html lang="en"><head><meta charset="UTF-8">
            <title>\(note.displayTitle)</title>
            <style>
            body { font-family: -apple-system, system-ui, sans-serif; max-width: 680px;
                   margin: 40px auto; padding: 0 20px; line-height: 1.6; color: #1d1d1f; }
            h1 { font-size: 24px; margin-bottom: 8px; }
            .meta { font-size: 13px; color: #86868b; margin-bottom: 24px; }
            </style></head><body>
            <h1>\(note.displayTitle)</h1>
            <div class="meta">\(note.folderName) &middot; Modified \(note.formattedModifiedDate)</div>
            \(html)
            </body></html>
            """
            try fullHTML.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            var text = "# \(note.displayTitle)\n"
            text += "Folder: \(note.folderName)\n"
            if let date = note.modifiedDate { text += "Modified: \(date.shortString)\n" }
            text += "\n\(note.snippet)"
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func exportAll(to directory: String) throws -> Int {
        let notes = try getNotes()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var count = 0
        for note in notes {
            let safeName = note.displayTitle
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .prefix(50)
            let ext = note.htmlBody != nil ? "html" : "txt"
            let path = (directory as NSString).appendingPathComponent("\(safeName).\(ext)")
            try exportNote(note, to: path)
            count += 1
        }
        return count
    }
}
