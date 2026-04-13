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
        var dbPath = "\(backupPath)/\(knownHash.prefix(2))/\(knownHash)"

        // Fallback: search manifest
        if !FileManager.default.fileExists(atPath: dbPath) {
            guard let entry = try manifest.files(matching: "%AddressBook.sqlitedb").first(where: { $0.domain == "HomeDomain" }) else {
                throw NSError(domain: "Phosphor", code: 404, userInfo: [NSLocalizedDescriptionKey: "AddressBook database not found in backup"])
            }
            dbPath = entry.diskPath(backupRoot: backupPath)
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

    /// Get contact count without loading all data.
    func getContactCount() throws -> Int {
        let knownHash = "31bb7ba8914766d4ba40d6dfb6113c8b614be442"
        var dbPath = "\(backupPath)/\(knownHash.prefix(2))/\(knownHash)"

        if !FileManager.default.fileExists(atPath: dbPath) {
            guard let entry = try manifest.files(matching: "%AddressBook.sqlitedb").first(where: { $0.domain == "HomeDomain" }) else { return 0 }
            dbPath = entry.diskPath(backupRoot: backupPath)
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
            csv += "\"\(contact.firstName)\",\"\(contact.lastName)\",\"\(contact.organization)\",\"\(phones)\",\"\(emails)\"\n"
        }
        try csv.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
