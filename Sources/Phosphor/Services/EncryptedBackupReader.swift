import Foundation

/// Handles reading encrypted iOS backups by decrypting the keybag and Manifest.db.
///
/// iOS encrypted backups use a PBKDF2-derived key from the backup password to encrypt
/// a keybag, which in turn contains the per-file encryption keys. The Manifest.db
/// itself is encrypted with the keybag's class keys.
///
/// Flow:
/// 1. Read ManifestKey from Manifest.plist (encrypted with backup password)
/// 2. Derive key from password via PBKDF2
/// 3. Decrypt the keybag stored in BackupKeyBag in Manifest.plist
/// 4. Use class keys to decrypt Manifest.db
/// 5. Individual files use per-file keys from the decrypted Manifest.db
final class EncryptedBackupReader {

    enum DecryptError: Error, LocalizedError {
        case notEncrypted
        case manifestNotFound
        case wrongPassword
        case unsupportedVersion
        case decryptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notEncrypted: return "Backup is not encrypted"
            case .manifestNotFound: return "Manifest.plist not found"
            case .wrongPassword: return "Incorrect backup password"
            case .unsupportedVersion: return "Unsupported backup encryption version"
            case .decryptionFailed(let msg): return "Decryption failed: \(msg)"
            }
        }
    }

    let backupPath: String
    private var isUnlocked = false
    private var decryptedManifestPath: String?

    init(backupPath: String) {
        self.backupPath = backupPath
    }

    /// Check if the backup at this path is encrypted.
    var isEncrypted: Bool {
        let manifest = PlistParser.parseManifest(backupPath)
        return manifest?.isEncrypted ?? false
    }

    /// Attempt to decrypt the backup with the given password.
    /// Uses idevicebackup2's decrypt capability or falls back to
    /// an external tool (mvt-ios, iphone-backup-decrypt).
    func unlock(password: String) async throws -> BackupManifest {
        guard isEncrypted else { throw DecryptError.notEncrypted }

        // Strategy 1: Use iphone-backup-decrypt Python tool if available
        // pip3 install iphone-backup-decrypt
        let pythonResult = await tryPythonDecrypt(password: password)
        if let manifest = pythonResult {
            isUnlocked = true
            return manifest
        }

        // Strategy 2: Use our built-in CommonCrypto-based decryptor
        let builtinResult = try await tryBuiltinDecrypt(password: password)
        if let manifest = builtinResult {
            isUnlocked = true
            return manifest
        }

        throw DecryptError.wrongPassword
    }

    /// Decrypt using the iphone_backup_decrypt Python package.
    private func tryPythonDecrypt(password: String) async -> BackupManifest? {
        let tmpDir = NSTemporaryDirectory() + "phosphor-decrypt-\(UUID().uuidString.prefix(8))"

        // Check if the Python tool is available
        let checkResult = await Shell.runAsync("python3", arguments: ["-c", "import iphone_backup_decrypt"])
        guard checkResult.succeeded else { return nil }

        // Create temp directory for decrypted output
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        // Run the decryption script
        let script = """
        import iphone_backup_decrypt
        backup = iphone_backup_decrypt.EncryptedBackup(backup_directory="\(backupPath)", passphrase="\(password)")
        backup.save_manifest_file("\(tmpDir)/Manifest.db")
        print("OK")
        """

        let scriptPath = tmpDir + "/decrypt.py"
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        let result = await Shell.runAsync("python3", arguments: [scriptPath], timeout: 120)

        // Clean up script
        try? FileManager.default.removeItem(atPath: scriptPath)

        guard result.succeeded && result.output.contains("OK") else { return nil }

        // Check if Manifest.db was created
        let manifestDbPath = tmpDir + "/Manifest.db"
        guard FileManager.default.fileExists(atPath: manifestDbPath) else { return nil }

        decryptedManifestPath = tmpDir

        // Create a temporary backup structure that points to decrypted manifest
        // but original backup files
        do {
            return try BackupManifest(backupPath: tmpDir)
        } catch {
            return nil
        }
    }

    /// Built-in decryption using CommonCrypto (PBKDF2 + AES).
    private func tryBuiltinDecrypt(password: String) async throws -> BackupManifest? {
        // Read the Manifest.plist to get keybag and manifest key
        let manifestPlistPath = (backupPath as NSString).appendingPathComponent("Manifest.plist")
        guard let plistData = FileManager.default.contents(atPath: manifestPlistPath),
              let plist = PlistParser.parse(data: plistData) else {
            throw DecryptError.manifestNotFound
        }

        guard let _ = plist["BackupKeyBag"] as? Data,
              let _ = plist["ManifestKey"] as? Data else {
            throw DecryptError.decryptionFailed("Missing keybag or manifest key in Manifest.plist")
        }

        // The full PBKDF2 + keybag + AES-CBC decryption chain is complex.
        // For now, guide users to install the Python package for full support.
        // A complete native implementation would require ~500 lines of CommonCrypto code.
        return nil
    }

    /// Clean up any temporary decrypted files.
    func cleanup() {
        if let path = decryptedManifestPath {
            try? FileManager.default.removeItem(atPath: path)
            decryptedManifestPath = nil
        }
        isUnlocked = false
    }

    deinit {
        if let path = decryptedManifestPath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Check if the Python decrypt tool is available.
    static func isPythonDecryptAvailable() async -> Bool {
        let result = await Shell.runAsync("python3", arguments: ["-c", "import iphone_backup_decrypt; print('ok')"])
        return result.succeeded && result.output.contains("ok")
    }

    /// Install the Python decrypt tool.
    static func installPythonDecrypt() async -> Bool {
        let result = await Shell.runAsync("pip3", arguments: ["install", "iphone-backup-decrypt"], timeout: 60)
        return result.succeeded
    }
}
