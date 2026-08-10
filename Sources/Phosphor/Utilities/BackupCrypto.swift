import Foundation
import CommonCrypto

/// Cryptographic primitives for password-protected iOS backups.
///
/// iOS encrypts a backup by deriving a key from the backup password, using it to
/// unwrap the per-protection-class keys stored in `Manifest.plist`'s `BackupKeyBag`,
/// and encrypting `Manifest.db` plus every file blob with AES-256-CBC under a
/// per-item key that is itself wrapped by its class key.
enum BackupCrypto {

    /// RFC 3394 AES key unwrap. Returns nil when the integrity check fails, which
    /// is how a wrong backup password is detected.
    static func aesKeyUnwrap(kek: Data, wrapped: Data) -> Data? {
        guard !kek.isEmpty, wrapped.count >= 16, wrapped.count % 8 == 0 else { return nil }
        var rawLength = CCSymmetricUnwrappedSize(CCWrappingAlgorithm(kCCWRAPAES), wrapped.count)
        var raw = Data(count: rawLength)
        let status: Int32 = raw.withUnsafeMutableBytes { rawBuffer in
            wrapped.withUnsafeBytes { wrappedBuffer in
                kek.withUnsafeBytes { kekBuffer in
                    CCSymmetricKeyUnwrap(
                        CCWrappingAlgorithm(kCCWRAPAES),
                        CCrfc3394_iv, CCrfc3394_ivLen,
                        kekBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), kek.count,
                        wrappedBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), wrapped.count,
                        rawBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), &rawLength
                    )
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        return raw.prefix(rawLength)
    }

    /// PBKDF2 over arbitrary binary input. iOS 10.2+ chains two rounds (SHA-256
    /// then SHA-1), so the first round's 32-byte output feeds the second as a
    /// binary password rather than a string.
    static func pbkdf2(
        prf: Int,
        password: Data,
        salt: Data,
        rounds: UInt32,
        length: Int
    ) -> Data? {
        guard length > 0, rounds > 0, !salt.isEmpty else { return nil }
        var derived = Data(count: length)
        let status: Int32 = derived.withUnsafeMutableBytes { derivedBuffer in
            password.withUnsafeBytes { passwordBuffer in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                        saltBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(prf), rounds,
                        derivedBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), length
                    )
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        return derived
    }

    /// AES-256-CBC with an all-zero IV and no padding. Both `Manifest.db` and the
    /// individual file blobs in an encrypted backup use this form; callers trim
    /// trailing block padding using the plaintext size recorded in the manifest.
    static func aesCBCDecrypt(key: Data, data: Data) -> Data? {
        guard key.count == kCCKeySizeAES256, !data.isEmpty, data.count % kCCBlockSizeAES128 == 0 else {
            return nil
        }
        let iv = Data(count: kCCBlockSizeAES128)
        let capacity = data.count
        var out = Data(count: capacity)
        var moved = 0
        let status: Int32 = out.withUnsafeMutableBytes { outBuffer in
            data.withUnsafeBytes { dataBuffer in
                iv.withUnsafeBytes { ivBuffer in
                    key.withUnsafeBytes { keyBuffer in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBuffer.baseAddress!, key.count,
                            ivBuffer.baseAddress!,
                            dataBuffer.baseAddress!, capacity,
                            outBuffer.baseAddress!, capacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        return out.prefix(moved)
    }
}

/// The `BackupKeyBag` blob from `Manifest.plist`, parsed into its protection classes.
///
/// The blob is a flat sequence of TLV records: a four-character ASCII tag, a
/// big-endian 32-bit length, then the value. Records before the second `UUID`
/// describe the keybag itself; every later `UUID` opens a new protection class.
struct BackupKeybag {

    struct ProtectionClass {
        let identifier: UInt32
        let wrap: UInt32
        let wrappedKey: Data
        var key: Data?
    }

    /// A protection class is wrapped by the passcode-derived key when this bit is set.
    private static let wrapPasscode: UInt32 = 2

    private(set) var classes: [UInt32: ProtectionClass] = [:]
    private var attributes: [String: Data] = [:]

    init?(data: Data) {
        var offset = 0
        var currentIdentifier: UInt32?
        var currentWrap: UInt32 = 0
        var currentWrappedKey: Data?
        var sawKeybagUUID = false
        var sawKeybagWrap = false

        func flushCurrentClass() {
            guard let identifier = currentIdentifier, let wrappedKey = currentWrappedKey else { return }
            classes[identifier] = ProtectionClass(
                identifier: identifier,
                wrap: currentWrap,
                wrappedKey: wrappedKey,
                key: nil
            )
            currentIdentifier = nil
            currentWrap = 0
            currentWrappedKey = nil
        }

        while offset + 8 <= data.count {
            let tagStart = data.startIndex + offset
            guard let tag = String(data: data[tagStart..<(tagStart + 4)], encoding: .ascii) else { return nil }
            let length = Int(Self.bigEndianUInt32(data[(tagStart + 4)..<(tagStart + 8)]))
            let valueStart = tagStart + 8
            guard length >= 0, valueStart + length <= data.endIndex else { return nil }
            let value = Data(data[valueStart..<(valueStart + length)])
            offset += 8 + length

            switch tag {
            case "UUID" where !sawKeybagUUID:
                // The first UUID identifies the keybag, not a protection class.
                sawKeybagUUID = true
                attributes[tag] = value
            case "UUID":
                flushCurrentClass()
            case "CLAS":
                currentIdentifier = Self.bigEndianUInt32(value)
            case "WPKY":
                currentWrappedKey = value
            case "WRAP" where !sawKeybagWrap:
                // The first WRAP describes the keybag; every later one belongs to
                // the protection class currently being read.
                sawKeybagWrap = true
                attributes[tag] = value
            case "WRAP":
                currentWrap = Self.bigEndianUInt32(value)
            case "KTYP", "PBKY":
                break
            default:
                attributes[tag] = value
            }
        }
        flushCurrentClass()

        guard attributes["SALT"] != nil, attributes["ITER"] != nil, !classes.isEmpty else { return nil }
    }

    /// Derive the passcode key and unwrap every passcode-wrapped class key.
    /// Returns false when the password is wrong - RFC 3394 unwrapping carries its
    /// own integrity check, so a bad password fails here rather than producing
    /// garbage plaintext later.
    mutating func unlock(password: String) -> Bool {
        guard let salt = attributes["SALT"],
              let iterationData = attributes["ITER"] else { return false }
        let iterations = Self.bigEndianUInt32(iterationData)
        guard iterations > 0 else { return false }

        var passphrase = Data(password.utf8)
        // iOS 10.2 and later add a SHA-256 pre-round keyed by DPSL/DPIC.
        if let doubleSalt = attributes["DPSL"], let doubleIterationData = attributes["DPIC"] {
            let doubleIterations = Self.bigEndianUInt32(doubleIterationData)
            guard doubleIterations > 0,
                  let stretched = BackupCrypto.pbkdf2(
                      prf: kCCPRFHmacAlgSHA256,
                      password: passphrase,
                      salt: doubleSalt,
                      rounds: doubleIterations,
                      length: 32
                  ) else { return false }
            passphrase = stretched
        }

        guard let passcodeKey = BackupCrypto.pbkdf2(
            prf: kCCPRFHmacAlgSHA1,
            password: passphrase,
            salt: salt,
            rounds: iterations,
            length: 32
        ) else { return false }

        var unwrappedAny = false
        for (identifier, protectionClass) in classes {
            guard protectionClass.wrap & Self.wrapPasscode != 0 else { continue }
            guard let key = BackupCrypto.aesKeyUnwrap(kek: passcodeKey, wrapped: protectionClass.wrappedKey) else {
                // A single failure means the derived key is wrong for the whole bag.
                return false
            }
            classes[identifier]?.key = key
            unwrappedAny = true
        }
        return unwrappedAny
    }

    /// Unwrap a per-item key (`ManifestKey`, or a file's `EncryptionKey`).
    /// The blob is a little-endian protection class followed by the wrapped key.
    func unwrapItemKey(_ blob: Data) -> Data? {
        guard blob.count > 4 else { return nil }
        let identifier = UInt32(littleEndian: Data(blob.prefix(4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard let classKey = classes[identifier]?.key else { return nil }
        return BackupCrypto.aesKeyUnwrap(kek: classKey, wrapped: Data(blob.dropFirst(4)))
    }

    private static func bigEndianUInt32(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

/// Decrypts one unlocked backup. Holds the unwrapped class keys in memory only -
/// nothing derived from the password is ever written to disk.
final class BackupDecryptor {

    enum DecryptError: LocalizedError {
        case manifestPlistMissing
        case notEncrypted
        case keybagUnreadable
        case wrongPassword
        case manifestKeyMissing
        case manifestDecryptionFailed
        case fileKeyMissing
        case fileDecryptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .manifestPlistMissing: return "Manifest.plist not found in this backup"
            case .notEncrypted: return "This backup is not encrypted"
            case .keybagUnreadable: return "Backup keybag is missing or malformed"
            case .wrongPassword: return "Incorrect backup password"
            case .manifestKeyMissing: return "Manifest.plist has no ManifestKey entry"
            case .manifestDecryptionFailed: return "Manifest.db could not be decrypted with this password"
            case .fileKeyMissing: return "Backup entry has no usable encryption key"
            case .fileDecryptionFailed(let name): return "Could not decrypt \(name) from the backup"
            }
        }
    }

    let backupPath: String
    private let keybag: BackupKeybag
    private let manifestKey: Data

    /// Unlock a backup directory. Throws `.wrongPassword` when the password does
    /// not match, so callers can re-prompt without special-casing.
    init(backupPath: String, password: String) throws {
        self.backupPath = backupPath

        let manifestPlistPath = (backupPath as NSString).appendingPathComponent("Manifest.plist")
        guard let plistData = FileManager.default.contents(atPath: manifestPlistPath),
              let plist = PlistParser.parse(data: plistData) else {
            throw DecryptError.manifestPlistMissing
        }
        guard plist["IsEncrypted"] as? Bool ?? false else { throw DecryptError.notEncrypted }
        guard let keybagData = plist["BackupKeyBag"] as? Data,
              var keybag = BackupKeybag(data: keybagData) else {
            throw DecryptError.keybagUnreadable
        }
        guard keybag.unlock(password: password) else { throw DecryptError.wrongPassword }
        guard let manifestKeyBlob = plist["ManifestKey"] as? Data else {
            throw DecryptError.manifestKeyMissing
        }
        guard let manifestKey = keybag.unwrapItemKey(manifestKeyBlob) else {
            throw DecryptError.wrongPassword
        }
        self.keybag = keybag
        self.manifestKey = manifestKey
    }

    /// Decrypt `Manifest.db` in memory. The ciphertext length is already a whole
    /// number of AES blocks and matches the plaintext SQLite page count, so no
    /// padding trim is needed here.
    func decryptedManifestDatabase() throws -> Data {
        let manifestDBPath = (backupPath as NSString).appendingPathComponent("Manifest.db")
        guard let encrypted = FileManager.default.contents(atPath: manifestDBPath) else {
            throw DecryptError.manifestPlistMissing
        }
        guard let plaintext = BackupCrypto.aesCBCDecrypt(key: manifestKey, data: encrypted),
              plaintext.starts(with: Data("SQLite format 3\0".utf8)) else {
            throw DecryptError.manifestDecryptionFailed
        }
        return plaintext
    }

    /// Decrypt one backup file blob using the key stored in its manifest record.
    func decryptFile(at sourcePath: String, record: BackupFileRecord?, displayName: String) throws -> Data {
        guard let encrypted = FileManager.default.contents(atPath: sourcePath) else {
            throw DecryptError.fileDecryptionFailed(displayName)
        }
        guard let record, let wrappedKey = record.wrappedKey else {
            // Only empty files legitimately carry no key inside an encrypted
            // backup. Returning raw bytes for anything else would hand ciphertext
            // to SQLite or an image decoder and surface as a corrupt-file error
            // instead of the real cause.
            guard encrypted.isEmpty || record?.size == 0 else {
                throw DecryptError.fileKeyMissing
            }
            return encrypted
        }
        guard let key = keybag.unwrapItemKey(wrappedKey) else {
            throw DecryptError.fileKeyMissing
        }
        guard let plaintext = BackupCrypto.aesCBCDecrypt(key: key, data: encrypted) else {
            throw DecryptError.fileDecryptionFailed(displayName)
        }
        // File plaintext is padded up to the AES block size; the manifest records
        // the real length.
        if record.size > 0 && record.size <= plaintext.count {
            return plaintext.prefix(record.size)
        }
        return plaintext
    }
}

/// The per-file metadata Phosphor needs out of a Manifest.db `file` blob.
///
/// The blob is an `NSKeyedArchiver` plist whose object graph references its
/// values by archiver UID. Those UIDs are not representable in Swift through
/// `PropertyListSerialization`, so the record is located structurally instead:
/// the file object is the only `$objects` entry carrying `ProtectionClass`, and
/// the wrapped key is the only 44-byte `NS.data` blob in the archive.
struct BackupFileRecord {
    let protectionClass: Int
    let wrappedKey: Data?
    let size: Int
    let modifiedTime: TimeInterval?

    /// Length of a wrapped file key: a 4-byte little-endian protection class
    /// plus the 40-byte RFC 3394 wrapping of a 32-byte AES key.
    private static let wrappedKeyLength = 44

    init?(fileBlob: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: fileBlob, format: nil),
              let root = plist as? [String: Any],
              let objects = root["$objects"] as? [Any] else { return nil }

        let dictionaries = objects.compactMap { $0 as? [String: Any] }
        guard let fileObject = dictionaries.first(where: { $0["ProtectionClass"] != nil }) else { return nil }

        protectionClass = (fileObject["ProtectionClass"] as? NSNumber)?.intValue ?? 0
        size = (fileObject["Size"] as? NSNumber)?.intValue ?? 0
        let rawModified = fileObject["LastModified"] ?? fileObject["MTime"]
        modifiedTime = Self.modifiedTime(from: rawModified, objects: objects)
        if fileObject["EncryptionKey"] == nil {
            wrappedKey = nil
        } else {
            wrappedKey = dictionaries
                .compactMap { $0["NS.data"] as? Data }
                .first { $0.count == Self.wrappedKeyLength }
        }
    }

    /// Decode an NSDate stored through an NSKeyedArchiver UID without invoking
    /// NSKeyedUnarchiver on backup-controlled data. `NS.time` is measured from
    /// Apple's 2001 reference date; direct numeric manifest values retain their
    /// historical interpretation as Unix timestamps.
    private static func modifiedTime(from rawValue: Any?, objects: [Any]) -> TimeInterval? {
        if let date = rawValue as? Date { return date.timeIntervalSince1970 }
        if let number = rawValue as? NSNumber { return number.doubleValue }

        guard let rawValue,
              let index = archiveObjectIndex(from: rawValue),
              objects.indices.contains(index) else { return nil }
        let resolved = objects[index]
        if let date = resolved as? Date { return date.timeIntervalSince1970 }
        if let dictionary = resolved as? [String: Any],
           let referenceTime = dictionary["NS.time"] as? NSNumber {
            return referenceTime.doubleValue + Date.timeIntervalBetween1970AndReferenceDate
        }
        if let number = resolved as? NSNumber { return number.doubleValue }
        return nil
    }

    /// PropertyListSerialization exposes binary-plist UID values as the opaque
    /// CFKeyedArchiverUID type. Support its stable description plus the CF$UID
    /// dictionary shape used by XML/plist tooling, while rejecting arbitrary
    /// strings and out-of-range values.
    private static func archiveObjectIndex(from value: Any) -> Int? {
        if let dictionary = value as? [String: Any],
           let number = dictionary["CF$UID"] as? NSNumber,
           number.intValue >= 0 {
            return number.intValue
        }
        let description = String(describing: value)
        guard description.contains("CFKeyedArchiverUID"),
              let marker = description.range(of: "{value = "),
              let end = description[marker.upperBound...].firstIndex(of: "}") else { return nil }
        let digits = description[marker.upperBound..<end]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}
