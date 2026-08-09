import Foundation

/// Parses iOS backup Manifest.db to browse backup contents.
/// The Manifest.db contains a "Files" table mapping domain/relativePath to SHA-1 hashed filenames.
final class BackupManifest {

    /// Errors surfaced when opening a backup.
    enum ManifestError: Error, LocalizedError {
        case manifestMissing(path: String)
        case backupEncrypted(path: String)
        case manifestUnreadable(path: String, underlying: String)

        var errorDescription: String? {
            switch self {
            case .manifestMissing(let path):
                return """
                Backup is incomplete - Manifest.db not found at \(path).
                The backup may have been cancelled or only partially written. Re-run the backup and try again.
                """
            case .backupEncrypted(let path):
                return """
                This backup is encrypted.
                iOS remembers the encrypted-backup setting at the device level, so every backup for this device is encrypted until it is disabled in Finder (Finder -> the device -> uncheck 'Encrypt local backup').
                Phosphor's encrypted-backup browser needs the backup password to decrypt Manifest.db at \(path).
                """
            case .manifestUnreadable(let path, let underlying):
                return "Cannot read Manifest.db at \(path): \(underlying)"
            }
        }
    }

    /// Leading magic bytes of a SQLite 3 database file.
    /// Encrypted iOS backups store Manifest.db as an opaque blob without this header,
    /// which is what makes sqlite3_prepare fail with 'unable to open database file'.
    private static let sqliteMagic = Data("SQLite format 3\0".utf8)

    let backupPath: String
    private let db: SQLiteReader
    private var sizeCache: [String: Int] = [:]
    /// Non-nil when this backup was unlocked earlier in the session. Every blob
    /// read goes through it, so consumers never see ciphertext.
    private let decryptor: BackupDecryptor?
    /// Private 0700 scratch directory holding the decrypted Manifest.db and any
    /// file copies materialized for readers that need a path. Removed on deinit.
    private let plaintextScratch: URL?
    private var plaintextCache: [String: String] = [:]

    struct FileEntry: Identifiable, Hashable {
        let id: String // fileID (SHA-1 hash)
        let domain: String
        let relativePath: String
        let flags: Int // 1 = file, 2 = directory, 4 = symlink
        let size: Int

        var isFile: Bool { flags == 1 }
        var isDirectory: Bool { flags == 2 }
        var fileName: String {
            (relativePath as NSString).lastPathComponent
        }
        var fileExtension: String {
            (fileName as NSString).pathExtension.lowercased()
        }
        var fullDomainPath: String {
            domain.isEmpty ? relativePath : "\(domain)/\(relativePath)"
        }

        /// Path to the actual file in the backup directory
        func diskPath(backupRoot: String) -> String {
            let prefix = String(id.prefix(2))
            return "\(backupRoot)/\(prefix)/\(id)"
        }
    }

    enum Domain: String, CaseIterable {
        case cameraRoll = "CameraRollDomain"
        case appDomain = "AppDomain"
        case appDomainGroup = "AppDomainGroup"
        case homeDomain = "HomeDomain"
        case systemPreferences = "SystemPreferencesDomain"
        case wirelessDomain = "WirelessDomain"
        case keychain = "KeychainDomain"
        case managedPreferences = "ManagedPreferencesDomain"
        case mediaAnalysis = "MediaAnalysisDomain"
        case healthDomain = "HealthDomain"

        var displayName: String {
            switch self {
            case .cameraRoll: return "Camera Roll"
            case .appDomain: return "Applications"
            case .appDomainGroup: return "App Groups"
            case .homeDomain: return "Home"
            case .systemPreferences: return "System Preferences"
            case .wirelessDomain: return "Wireless"
            case .keychain: return "Keychain"
            case .managedPreferences: return "Managed Preferences"
            case .mediaAnalysis: return "Media Analysis"
            case .healthDomain: return "Health"
            }
        }
    }

    init(backupPath: String) throws {
        self.backupPath = backupPath
        let manifestPath = (backupPath as NSString).appendingPathComponent("Manifest.db")

        // Preflight: Manifest.db must exist, have the SQLite header, and the backup
        // must not be flagged as encrypted. Detecting this up front turns the opaque
        // 'SQLite prepare failed: unable to open database file' into a useful message.
        let fm = FileManager.default
        guard fm.fileExists(atPath: manifestPath) else {
            throw ManifestError.manifestMissing(path: manifestPath)
        }

        let declaredEncrypted = PlistParser.parseManifest(backupPath)?.isEncrypted ?? false
        var hasSQLiteHeader = true
        if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: manifestPath)) {
            defer { try? handle.close() }
            hasSQLiteHeader = (try? handle.read(upToCount: Self.sqliteMagic.count)) == Self.sqliteMagic
        }

        // An encrypted backup is readable once it has been unlocked this session.
        // Everything downstream then works unchanged, because the manifest hands
        // out plaintext.
        if declaredEncrypted || !hasSQLiteHeader {
            guard let decryptor = BackupUnlockStore.shared.decryptor(for: backupPath) else {
                throw ManifestError.backupEncrypted(path: manifestPath)
            }
            let scratch = Self.makeScratchDirectory()
            let plaintextManifest = scratch.appendingPathComponent("Manifest.db")
            do {
                try decryptor.decryptedManifestDatabase()
                    .write(to: plaintextManifest, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plaintextManifest.path)
                self.db = try SQLiteReader(path: plaintextManifest.path)
            } catch {
                try? fm.removeItem(at: scratch)
                throw ManifestError.manifestUnreadable(path: manifestPath, underlying: error.localizedDescription)
            }
            self.decryptor = decryptor
            self.plaintextScratch = scratch
            return
        }

        self.decryptor = nil
        self.plaintextScratch = nil
        do {
            self.db = try SQLiteReader(path: manifestPath)
        } catch {
            throw ManifestError.manifestUnreadable(path: manifestPath, underlying: error.localizedDescription)
        }
    }

    deinit {
        if let plaintextScratch {
            try? FileManager.default.removeItem(at: plaintextScratch)
        }
    }

    /// SQLite needs a file, so decrypted bytes have to land somewhere. Keep them in
    /// a per-instance 0700 directory that is removed when the manifest goes away.
    private static func makeScratchDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("phosphor-unlocked-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    /// True when this manifest is serving decrypted content.
    var isDecrypting: Bool { decryptor != nil }

    /// Plaintext bytes for one entry, decrypting on the fly when needed.
    func fileData(for entry: FileEntry) throws -> Data {
        let sourcePath = entry.diskPath(backupRoot: backupPath)
        guard let decryptor else {
            return try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        }
        return try decryptor.decryptFile(
            at: sourcePath,
            record: fileRecord(for: entry.id),
            displayName: entry.fileName
        )
    }

    /// A readable on-disk path for one entry. Unencrypted backups return the blob
    /// in place; encrypted ones get a decrypted copy in this manifest's scratch
    /// directory. Use this for readers that need a path rather than bytes, such as
    /// SQLiteReader.
    func readablePath(for entry: FileEntry) throws -> String {
        let sourcePath = entry.diskPath(backupRoot: backupPath)
        guard decryptor != nil, let plaintextScratch else { return sourcePath }
        if let cached = plaintextCache[entry.id] { return cached }

        let destination = plaintextScratch.appendingPathComponent(entry.id)
        try fileData(for: entry).write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        plaintextCache[entry.id] = destination.path
        return destination.path
    }

    /// Look one entry up by its SHA-1 fileID. Callers that already know a
    /// well-known hash (sms.db, an attachment) use this to reach the decrypting
    /// accessors instead of building the blob path by hand.
    func entry(withFileID fileID: String) -> FileEntry? {
        guard let rows = try? db.query(
            "SELECT fileID, domain, relativePath, flags FROM Files WHERE fileID = ?",
            params: [fileID]
        ) else { return nil }
        return rows.compactMap(parseFileEntry).first
    }

    /// The MBFile record for one entry, which carries its wrapped key and true size.
    private func fileRecord(for fileID: String) -> BackupFileRecord? {
        guard let rows = try? db.query("SELECT file FROM Files WHERE fileID = ?", params: [fileID]),
              let blob = rows.first?["file"] as? Data else { return nil }
        return BackupFileRecord(fileBlob: blob)
    }

    /// Get all unique domains in the backup.
    func domains() throws -> [String] {
        let rows = try db.query("SELECT DISTINCT domain FROM Files ORDER BY domain")
        return rows.compactMap { $0["domain"] as? String }
    }

    /// Get all files in a specific domain.
    func files(inDomain domain: String) throws -> [FileEntry] {
        let rows = try db.query(
            "SELECT fileID, domain, relativePath, flags FROM Files WHERE domain = ? ORDER BY relativePath",
            params: [domain]
        )
        return rows.compactMap(parseFileEntry)
    }

    /// Get all files matching a path pattern.
    func files(matching pattern: String) throws -> [FileEntry] {
        let rows = try db.query(
            "SELECT fileID, domain, relativePath, flags FROM Files WHERE relativePath LIKE ? ORDER BY relativePath",
            params: [pattern]
        )
        return rows.compactMap(parseFileEntry)
    }

    /// Search files by name.
    func search(_ query: String, limit: Int = 500) throws -> [FileEntry] {
        let boundedLimit = max(1, min(limit, 5_000))
        let rows = try db.query(
            "SELECT fileID, domain, relativePath, flags FROM Files WHERE relativePath LIKE ? ORDER BY relativePath LIMIT \(boundedLimit)",
            params: ["%\(query)%"]
        )
        return rows.compactMap(parseFileEntry)
    }

    /// Get the SMS database file entry.
    func smsDatabase() throws -> FileEntry? {
        let rows = try db.query(
            "SELECT fileID, domain, relativePath, flags FROM Files WHERE domain = 'HomeDomain' AND relativePath = 'Library/SMS/sms.db'"
        )
        return rows.first.flatMap(parseFileEntry)
    }

    /// Get the AddressBook database.
    func addressBook() throws -> FileEntry? {
        let rows = try db.query(
            "SELECT fileID, domain, relativePath, flags FROM Files WHERE domain = 'HomeDomain' AND relativePath = 'Library/AddressBook/AddressBook.sqlitedb'"
        )
        return rows.first.flatMap(parseFileEntry)
    }

    /// Get WhatsApp ChatStorage.sqlite.
    func whatsAppDatabase() throws -> FileEntry? {
        let rows = try db.query(
            "SELECT fileID, domain, relativePath, flags FROM Files WHERE relativePath LIKE '%ChatStorage.sqlite' AND domain LIKE '%whatsapp%'"
        )
        return rows.first.flatMap(parseFileEntry)
    }

    /// Get all photo files from Camera Roll.
    func cameraRollPhotos() throws -> [FileEntry] {
        let rows = try db.query(
            "SELECT fileID, domain, relativePath, flags FROM Files WHERE domain = 'CameraRollDomain' AND flags = 1 AND (relativePath LIKE '%.jpg' OR relativePath LIKE '%.jpeg' OR relativePath LIKE '%.png' OR relativePath LIKE '%.heic' OR relativePath LIKE '%.heif' OR relativePath LIKE '%.mov' OR relativePath LIKE '%.mp4') ORDER BY relativePath"
        )
        return rows.compactMap(parseFileEntry)
    }

    /// Get files for a specific app bundle ID.
    func appFiles(bundleId: String) throws -> [FileEntry] {
        let domain = "AppDomain-\(bundleId)"
        let groupDomain = "AppDomainGroup-group.\(bundleId)"
        let rows = try db.query(
            "SELECT fileID, domain, relativePath, flags FROM Files WHERE domain = ? OR domain = ? ORDER BY relativePath",
            params: [domain, groupDomain]
        )
        return rows.compactMap(parseFileEntry)
    }

    /// Get total file count.
    func totalFileCount() throws -> Int {
        try db.rowCount(for: "Files")
    }

    /// Build a directory tree structure from file entries.
    func directoryTree(for entries: [FileEntry]) -> DirectoryNode {
        let root = DirectoryNode(name: "/", path: "")
        for entry in entries {
            let components = entry.relativePath.split(separator: "/").map(String.init)
            var current = root
            var pathSoFar = ""
            for (i, component) in components.enumerated() {
                pathSoFar += (pathSoFar.isEmpty ? "" : "/") + component
                if i == components.count - 1 && entry.isFile {
                    current.files.append(entry)
                } else {
                    if let existing = current.child(named: component) {
                        current = existing
                    } else {
                        let child = DirectoryNode(name: component, path: pathSoFar)
                        current.addChild(child)
                        current = child
                    }
                }
            }
        }
        return root
    }

    /// Resolve actual on-disk size for an entry on demand. Manifest browsing
    /// queries intentionally do not stat every file up front because large iOS
    /// backups can contain hundreds of thousands of files.
    func fileSize(for entry: FileEntry) -> Int {
        if let cached = sizeCache[entry.id] { return cached }
        let diskPath = entry.diskPath(backupRoot: backupPath)
        // On an encrypted backup the blob on disk is padded up to the AES block
        // size, so the manifest record is the only source of the real length.
        let size: Int
        if decryptor != nil, let recorded = fileRecord(for: entry.id)?.size, recorded > 0 {
            size = recorded
        } else {
            size = (try? FileManager.default.attributesOfItem(atPath: diskPath)[.size] as? Int) ?? 0
        }
        sizeCache[entry.id] = size
        return size
    }

    func resolvingSizes(for entries: [FileEntry]) -> [FileEntry] {
        entries.map { entry in
            FileEntry(
                id: entry.id,
                domain: entry.domain,
                relativePath: entry.relativePath,
                flags: entry.flags,
                size: fileSize(for: entry)
            )
        }
    }

    func totalSize(for entries: [FileEntry]) -> Int {
        entries.reduce(0) { $0 + fileSize(for: $1) }
    }

    /// Copy a file from the backup to a destination.
    func extractFile(_ entry: FileEntry, to destination: String) throws {
        let sourcePath = entry.diskPath(backupRoot: backupPath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath) else {
            throw NSError(domain: "Phosphor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Backup file not found: \(sourcePath)"])
        }
        let destDir = (destination as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination) {
            try fm.removeItem(atPath: destination)
        }
        guard decryptor != nil else {
            // Unencrypted: copy in place rather than reading multi-gigabyte
            // media through memory.
            try fm.copyItem(atPath: sourcePath, toPath: destination)
            return
        }
        try fileData(for: entry).write(to: URL(fileURLWithPath: destination), options: .atomic)
    }

    // MARK: - Private

    private func parseFileEntry(_ row: [String: Any?]) -> FileEntry? {
        guard let fileID = row["fileID"] as? String,
              let domain = row["domain"] as? String,
              let relativePath = row["relativePath"] as? String else {
            return nil
        }
        let flags = (row["flags"] as? Int) ?? 1

        // Size is resolved lazily via fileSize(for:) when needed. Avoiding a
        // filesystem stat here keeps manifest browsing and search responsive on
        // large backups.
        return FileEntry(id: fileID, domain: domain, relativePath: relativePath, flags: flags, size: 0)
    }
}

/// Tree node for representing backup directory structure.
final class DirectoryNode: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    var children: [DirectoryNode] = []
    var files: [BackupManifest.FileEntry] = []
    private var childrenByName: [String: DirectoryNode] = [:]

    func child(named name: String) -> DirectoryNode? {
        childrenByName[name]
    }

    func addChild(_ child: DirectoryNode) {
        children.append(child)
        childrenByName[child.name] = child
    }

    var totalItems: Int {
        files.count + children.reduce(0) { $0 + $1.totalItems }
    }

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}
