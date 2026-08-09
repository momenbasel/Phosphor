import Foundation

/// Extracts contacts from iOS backup AddressBook databases.
/// Parses AddressBook.sqlitedb (ABPerson table) and AddressBookImages.sqlitedb.
final class ContactsExtractor {

    let backupPath: String
    private let manifest: BackupManifest

    struct Contact: Identifiable, Hashable {
        let id: Int
        let firstName: String
        let lastName: String
        let organization: String
        let phoneNumbers: [String]
        let emails: [String]
        let createdDate: Date?

        var fullName: String {
            let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
            return name.isEmpty ? organization : name
        }

        var initials: String {
            let f = firstName.first.map(String.init) ?? ""
            let l = lastName.first.map(String.init) ?? ""
            return (f + l).uppercased()
        }
    }

    init(backupPath: String) throws {
        self.backupPath = backupPath
        self.manifest = try BackupManifest(backupPath: backupPath)
    }

    // MARK: - Extraction

    /// Get all contacts from backup.
    func getContacts() throws -> [Contact] {
        // AddressBook.sqlitedb hash: 31bb7ba8914766d4ba40d6dfb6113c8b614be442
        let knownHash = "31bb7ba8914766d4ba40d6dfb6113c8b614be442"
        // On an encrypted backup that blob is ciphertext, so its presence proves
        // nothing. Force the manifest lookup, which decrypts.
        var dbPath = manifest.isDecrypting ? "" : "\(backupPath)/\(knownHash.prefix(2))/\(knownHash)"

        // Fallback: search manifest
        if !FileManager.default.fileExists(atPath: dbPath) {
            guard let entry = try manifest.files(matching: "%AddressBook.sqlitedb").first(where: { $0.domain == "HomeDomain" }) else {
                throw NSError(domain: "Phosphor", code: 404, userInfo: [NSLocalizedDescriptionKey: "AddressBook database not found in backup"])
            }
            dbPath = try manifest.readablePath(for: entry)
        }

        let db = try SQLiteReader(path: dbPath)
        let tables = try db.tableNames()

        guard tables.contains("ABPerson") else {
            throw NSError(domain: "Phosphor", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid AddressBook database"])
        }

        // Single query with LEFT JOINs to avoid N+1 problem
        // Property 3 = phone, Property 4 = email
        let persons = try db.query("""
            SELECT ROWID, First, Last, Organization, CreationDate
            FROM ABPerson
            ORDER BY COALESCE(First, '') || COALESCE(Last, '') || COALESCE(Organization, '')
        """)

        // Batch-load all phone numbers and emails in two queries
        let allPhones = try db.query("""
            SELECT record_id, value FROM ABMultiValue WHERE property = 3 ORDER BY record_id
        """)
        let allEmails = try db.query("""
            SELECT record_id, value FROM ABMultiValue WHERE property = 4 ORDER BY record_id
        """)

        // Index by record_id for O(1) lookup
        var phonesByRecord: [Int: [String]] = [:]
        for row in allPhones {
            if let rid = row["record_id"] as? Int, let val = row["value"] as? String {
                phonesByRecord[rid, default: []].append(val)
            }
        }
        var emailsByRecord: [Int: [String]] = [:]
        for row in allEmails {
            if let rid = row["record_id"] as? Int, let val = row["value"] as? String {
                emailsByRecord[rid, default: []].append(val)
            }
        }

        var contacts: [Contact] = []

        for row in persons {
            let rowId = (row["ROWID"] as? Int) ?? 0
            let first = (row["First"] as? String) ?? ""
            let last = (row["Last"] as? String) ?? ""
            let org = (row["Organization"] as? String) ?? ""
            let created = (row["CreationDate"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) }

            contacts.append(Contact(
                id: rowId,
                firstName: first,
                lastName: last,
                organization: org,
                phoneNumbers: phonesByRecord[rowId] ?? [],
                emails: emailsByRecord[rowId] ?? [],
                createdDate: created
            ))
        }

        return contacts
    }

    /// Search contacts in SQLite before materializing rows. The result and
    /// phone/email fan-out are bounded by `limit` so unified search cannot load
    /// an entire address book for one query.
    func searchContacts(_ query: String, limit: Int = 250) throws -> [Contact] {
        let knownHash = "31bb7ba8914766d4ba40d6dfb6113c8b614be442"
        var dbPath = manifest.isDecrypting ? "" : "\(backupPath)/\(knownHash.prefix(2))/\(knownHash)"
        if !FileManager.default.fileExists(atPath: dbPath) {
            guard let entry = try manifest.files(matching: "%AddressBook.sqlitedb").first(where: { $0.domain == "HomeDomain" }) else {
                throw NSError(domain: "Phosphor", code: 404, userInfo: [NSLocalizedDescriptionKey: "AddressBook database not found in backup"])
            }
            dbPath = try manifest.readablePath(for: entry)
        }

        let db = try SQLiteReader(path: dbPath)
        guard try db.tableNames().contains("ABPerson") else {
            throw NSError(domain: "Phosphor", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid AddressBook database"])
        }

        let boundedLimit = max(1, min(limit, 1_000))
        let pattern = "%\(query)%"
        let persons = try db.query("""
            SELECT DISTINCT p.ROWID, p.First, p.Last, p.Organization, p.CreationDate
            FROM ABPerson p
            LEFT JOIN ABMultiValue mv ON mv.record_id = p.ROWID AND mv.property IN (3, 4)
            WHERE p.First LIKE ? COLLATE NOCASE
               OR p.Last LIKE ? COLLATE NOCASE
               OR p.Organization LIKE ? COLLATE NOCASE
               OR mv.value LIKE ? COLLATE NOCASE
            ORDER BY COALESCE(p.First, '') || COALESCE(p.Last, '') || COALESCE(p.Organization, '')
            LIMIT \(boundedLimit)
        """, params: [pattern, pattern, pattern, pattern])

        let ids = persons.compactMap { $0["ROWID"] as? Int }
        guard !ids.isEmpty else { return [] }
        let idList = ids.map(String.init).joined(separator: ",")
        let phoneRows = try db.query("SELECT record_id, value FROM ABMultiValue WHERE property = 3 AND record_id IN (\(idList)) ORDER BY record_id")
        let emailRows = try db.query("SELECT record_id, value FROM ABMultiValue WHERE property = 4 AND record_id IN (\(idList)) ORDER BY record_id")

        var phones: [Int: [String]] = [:]
        for row in phoneRows {
            if let id = row["record_id"] as? Int, let value = row["value"] as? String {
                phones[id, default: []].append(value)
            }
        }
        var emails: [Int: [String]] = [:]
        for row in emailRows {
            if let id = row["record_id"] as? Int, let value = row["value"] as? String {
                emails[id, default: []].append(value)
            }
        }

        return persons.compactMap { row in
            guard let id = row["ROWID"] as? Int else { return nil }
            return Contact(
                id: id,
                firstName: (row["First"] as? String) ?? "",
                lastName: (row["Last"] as? String) ?? "",
                organization: (row["Organization"] as? String) ?? "",
                phoneNumbers: phones[id] ?? [],
                emails: emails[id] ?? [],
                createdDate: (row["CreationDate"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) }
            )
        }
    }

    /// Get contact count without loading all data.
    func getContactCount() throws -> Int {
        let knownHash = "31bb7ba8914766d4ba40d6dfb6113c8b614be442"
        // On an encrypted backup that blob is ciphertext, so its presence proves
        // nothing. Force the manifest lookup, which decrypts.
        var dbPath = manifest.isDecrypting ? "" : "\(backupPath)/\(knownHash.prefix(2))/\(knownHash)"

        if !FileManager.default.fileExists(atPath: dbPath) {
            guard let entry = try manifest.files(matching: "%AddressBook.sqlitedb").first(where: { $0.domain == "HomeDomain" }) else { return 0 }
            dbPath = try manifest.readablePath(for: entry)
        }

        guard let db = try? SQLiteReader(path: dbPath) else { return 0 }
        return try db.rowCount(for: "ABPerson")
    }

    // MARK: - Export

    /// Export contacts as vCard (.vcf) file.
    func exportAsVCard(contacts: [Contact], to path: String) throws {
        var vcf = ""
        for contact in contacts {
            vcf += "BEGIN:VCARD\n"
            vcf += "VERSION:3.0\n"
            vcf += "N:\(contact.lastName);\(contact.firstName);;;\n"
            vcf += "FN:\(contact.fullName)\n"
            if !contact.organization.isEmpty {
                vcf += "ORG:\(contact.organization)\n"
            }
            for phone in contact.phoneNumbers {
                vcf += "TEL;TYPE=CELL:\(phone)\n"
            }
            for email in contact.emails {
                vcf += "EMAIL:\(email)\n"
            }
            vcf += "END:VCARD\n\n"
        }
        try vcf.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Export contacts as CSV.
    func exportAsCSV(contacts: [Contact], to path: String) throws {
        var csv = "First Name,Last Name,Organization,Phone Numbers,Email Addresses\n"
        for contact in contacts {
            let phones = contact.phoneNumbers.joined(separator: "; ")
            let emails = contact.emails.joined(separator: "; ")
            csv += CSVExport.row([contact.firstName, contact.lastName, contact.organization, phones, emails])
        }
        try csv.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
