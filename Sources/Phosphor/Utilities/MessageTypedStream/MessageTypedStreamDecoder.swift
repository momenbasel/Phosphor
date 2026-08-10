// Adapted from Madrid TypedStream at commit 8f5f4f1.
// Copyright 2025 Mattt. Licensed under the MIT License; see THIRD_PARTY_NOTICES.md.

import Foundation

/// Errors that can occur when parsing `typedstream` data.
///
/// This corresponds to the new `typedstream` deserializer.
public enum MessageTypedStreamDecoderError: Error, LocalizedError {
    /// Read or slice operation exceeded the stream bounds.
    case outOfBounds(index: Int, length: Int)
    /// The stream header is missing, malformed, or unsupported.
    case invalidHeader
    /// Failed to slice the source stream.
    case sliceError(Swift.Error)
    /// Failed to decode string data as UTF-8.
    case stringParseError(Swift.Error)
    /// Array type declaration could not be parsed.
    case invalidArray
    /// MessageTypedStreamType reference pointer is invalid or out of range.
    case invalidPointer(UInt8)
    /// Corrupt input nested objects deeply enough to risk exhausting the stack.
    case nestingTooDeep
    /// Parsing exceeded the bounded work or collection budget.
    case resourceLimit

    public var errorDescription: String? {
        switch self {
        case .outOfBounds(let index, let length):
            return "Index \(String(index, radix: 16)) is outside of range \(String(length, radix: 16))!"
        case .invalidHeader:
            return "Invalid typedstream header!"
        case .sliceError(let error):
            return "Unable to slice source stream: \(error)"
        case .stringParseError(let error):
            return "Failed to parse string: \(error)"
        case .invalidArray:
            return "Failed to parse array data"
        case .invalidPointer(let value):
            return "Failed to parse pointer: \(String(value, radix: 16))"
        case .nestingTooDeep:
            return "Typedstream object nesting exceeds the supported limit"
        case .resourceLimit:
            return "Typedstream exceeds the supported parsing budget"
        }
    }
}

/// Deserializes data from the NeXT/Apple `typedstream` binary format.
///
/// `typedstream` is designed to serialize and deserialize complex object graphs
/// and data structures in C and Objective-C. A stream begins with a header
/// (format version and architecture), followed by typed data elements
/// prefixed with type information.
///
/// Use `decode(_:)` to parse `Data` into an array of `MessageTypedStreamValue` values.
/// `typedstream` data does not include property names;
/// values are stored in order of appearance.
public final class MessageTypedStreamDecoder {
    /// Result of parsing a class: either a reference index or a new hierarchy.
    private enum ClassResult {
        /// A reference to an already-seen class in the `TypedStreamReader`'s object table
        case index(Int)
        /// A new class hierarchy to be inserted into the `TypedStreamReader`'s object table
        case classHierarchy([MessageTypedStreamValue])
    }

    // MARK: - Constants

    /// Indicates an `Int16` in the byte stream
    private let I_16: UInt8 = 0x81
    /// Indicates an `Int32` in the byte stream
    private let I_32: UInt8 = 0x82
    /// Indicates a `Float` or `Double` in the byte stream; the `MessageTypedStreamType` determines the size
    private let DECIMAL: UInt8 = 0x83
    /// Indicates the start of a new object
    private let START: UInt8 = 0x84
    /// Indicates that there is no more data to parse, for example the end of a class inheritance chain
    private let EMPTY: UInt8 = 0x85
    /// Indicates the last byte of an object
    private let END: UInt8 = 0x86
    /// Bytes equal or greater in value than the reference tag indicate an index in the table of already-seen types
    private let REFERENCE_TAG: UInt64 = 0x92
    /// Attributed-string type declarations are tiny; reject corrupt declarations
    /// before they can expand into very large enum arrays.
    private let maximumTypeDeclarationSize: UInt64 = 65_536

    // MARK: - Properties

    /// The `typedstream` we want to parse
    let stream: [UInt8]
    /// The current index we are at in the stream
    var idx: Int
    /// As we parse the `typedstream`, build a table of seen `MessageTypedStreamType`s to reference in the future
    ///
    /// The first time a `MessageTypedStreamType` is seen, it is present in the stream literally,
    /// but afterwards are only referenced by index in order of appearance.
    var typesTable: [[MessageTypedStreamType]]
    /// As we parse the `typedstream`, build a table of seen archivable data to reference in the future
    var objectTable: [MessageTypedStreamValue]
    /// We want to copy embedded types the first time they are seen, even if the types were resolved through references
    var seenEmbeddedTypes: Set<UInt32>
    /// Stores the position of the current `MessageTypedStreamValue.placeholder`
    var placeholder: Int?
    /// Bounds recursive embedded objects in backup-controlled archives.
    var embeddedDepth: Int
    /// Limits parser control-flow work independently of large string payloads.
    var remainingByteReads: Int
    /// Limits decoded collection growth, including expansion through references.
    var remainingDecodedValues: Int

    // MARK: - Static Methods

    /// Decodes `typedstream` data into an array of `MessageTypedStreamValue` values.
    ///
    /// - Parameter data: The `typedstream` bytes to decode.
    /// - Returns: An array of decoded values in stream order.
    /// - Throws: `MessageTypedStreamDecoderError` when the stream is malformed or parsing fails.
    public static func decode(_ data: Data) throws -> [MessageTypedStreamValue] {
        let bytes = [UInt8](data)
        let decoder = MessageTypedStreamDecoder(stream: bytes)
        return try decoder.parse()
    }

    // MARK: - Initialization

    /// Creates a decoder for the given byte stream.
    init(stream: [UInt8]) {
        self.stream = stream
        self.idx = 0
        self.typesTable = []
        self.objectTable = []
        self.seenEmbeddedTypes = Set()
        self.placeholder = nil
        self.embeddedDepth = 0
        self.remainingByteReads = 1_000_000
        self.remainingDecodedValues = 131_072
    }

    // MARK: - Methods

    /// Parses the stream and returns decoded `MessageTypedStreamValue` values in order.
    ///
    /// Does not retain object inheritance hierarchy; callers assemble the
    /// flat result into the desired structure.
    ///
    /// - Returns: An array of values parsed from the stream.
    /// - Throws: `MessageTypedStreamDecoderError` when parsing fails.
    func parse() throws -> [MessageTypedStreamValue] {
        var output: [MessageTypedStreamValue] = []

        try validateHeader()

        while idx < stream.count {
            if try getCurrentByte() == END {
                idx += 1
                continue
            }
            // First, get the current type
            if let foundTypes = try getType(embedded: false) {
                if let result = try readTypes(foundTypes: foundTypes) {
                    try consumeDecodedValues()
                    output.append(result)
                }
            }
        }

        return output
    }

    /// Validates the stream header (version, signature, system version).
    private func validateHeader() throws {
        // Encoding type
        let typedstreamVersion = try readUnsignedInt()
        // Encoding signature
        let signature = try readString()
        // System version
        let systemVersion = try readSignedInt()

        if typedstreamVersion != 4 || signature != "streamtyped" || systemVersion != 1000 {
            throw MessageTypedStreamDecoderError.invalidHeader
        }
    }

    /// Reads a signed integer; size is inferred from stream type markers.
    private func readSignedInt() throws -> Int64 {
        while true {
            switch try getCurrentByte() {
            case I_16:
                idx += 1
                let size = 2
                let bytes = try readExactBytes(size: size)
                let value = Int16(littleEndian: bytes.withUnsafeBytes { $0.load(as: Int16.self) })
                return Int64(value)
            case I_32:
                idx += 1
                let size = 4
                let bytes = try readExactBytes(size: size)
                let value = Int32(littleEndian: bytes.withUnsafeBytes { $0.load(as: Int32.self) })
                return Int64(value)
            default:
                let currentByte = try getCurrentByte()
                if currentByte > UInt8(REFERENCE_TAG), try getNextByte() != END {
                    // Malformed streams can contain long runs of reference-like
                    // bytes. Skip them iteratively so backup input cannot exhaust
                    // the process stack.
                    idx += 1
                    continue
                }
                let value = Int8(bitPattern: currentByte)
                idx += 1
                return Int64(value)
            }
        }
    }

    /// Reads an unsigned integer; size is inferred from stream type markers.
    private func readUnsignedInt() throws -> UInt64 {
        switch try getCurrentByte() {
        case I_16:
            idx += 1
            let size = 2
            let bytes = try readExactBytes(size: size)
            let value = UInt16(littleEndian: bytes.withUnsafeBytes { $0.load(as: UInt16.self) })
            return UInt64(value)
        case I_32:
            idx += 1
            let size = 4
            let bytes = try readExactBytes(size: size)
            let value = UInt32(littleEndian: bytes.withUnsafeBytes { $0.load(as: UInt32.self) })
            return UInt64(value)
        default:
            let value = try getCurrentByte()
            idx += 1
            return UInt64(value)
        }
    }

    /// Reads a 32-bit float from the stream.
    private func readFloat() throws -> Float {
        switch try getCurrentByte() {
        case DECIMAL:
            idx += 1
            let size = 4
            let bytes = try readExactBytes(size: size)
            let value = Float(bitPattern: bytes.withUnsafeBytes { $0.load(as: UInt32.self) })
            return value
        case I_16, I_32:
            let intValue = try readSignedInt()
            return Float(intValue)
        default:
            idx += 1
            let intValue = try readSignedInt()
            return Float(intValue)
        }
    }

    /// Read a double-precision float from the byte stream
    private func readDouble() throws -> Double {
        switch try getCurrentByte() {
        case DECIMAL:
            idx += 1
            let size = 8
            let bytes = try readExactBytes(size: size)
            let value = Double(bitPattern: bytes.withUnsafeBytes { $0.load(as: UInt64.self) })
            return value
        case I_16, I_32:
            let intValue = try readSignedInt()
            return Double(intValue)
        default:
            idx += 1
            let intValue = try readSignedInt()
            return Double(intValue)
        }
    }

    /// Reads exactly `size` bytes and advances the index.
    private func readExactBytes(size: Int) throws -> Data {
        guard size >= 0, idx >= 0, idx <= stream.count, size <= stream.count - idx else {
            throw MessageTypedStreamDecoderError.outOfBounds(index: idx, length: stream.count)
        }
        let end = idx + size
        let data = Data(stream[idx ..< end])
        idx += size
        return data
    }

    /// Reads `length` bytes and decodes them as UTF-8.
    private func readExactAsString(length: Int) throws -> String {
        let bytes = try readExactBytes(size: length)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw MessageTypedStreamDecoderError.stringParseError(NSError(domain: "Invalid UTF-8", code: 0))
        }
        return string
    }

    /// Returns the byte at the given index.
    private func getByte(at index: Int) throws -> UInt8 {
        guard remainingByteReads > 0 else { throw MessageTypedStreamDecoderError.resourceLimit }
        remainingByteReads -= 1
        guard index >= 0, index < stream.count else {
            throw MessageTypedStreamDecoderError.outOfBounds(index: index, length: stream.count)
        }
        return stream[index]
    }

    /// Reserves decoded collection capacity before allocating or copying it.
    private func consumeDecodedValues(_ count: Int = 1) throws {
        guard count >= 0, count <= remainingDecodedValues else {
            throw MessageTypedStreamDecoderError.resourceLimit
        }
        remainingDecodedValues -= count
    }

    /// Returns the byte at the current stream index.
    private func getCurrentByte() throws -> UInt8 {
        return try getByte(at: idx)
    }

    /// Returns the byte immediately after the current index.
    private func getNextByte() throws -> UInt8 {
        return try getByte(at: idx + 1)
    }

    /// Reads `size` bytes as a byte array.
    private func readArray(size: Int) throws -> [UInt8] {
        let data = try readExactBytes(size: size)
        return [UInt8](data)
    }

    /// Reads the type declaration for the next element.
    private func readType() throws -> [MessageTypedStreamType] {
        let length = try readUnsignedInt()
        guard length <= maximumTypeDeclarationSize else {
            throw MessageTypedStreamDecoderError.resourceLimit
        }
        let typesData = try readExactBytes(size: Int(length))
        let typesBytes = [UInt8](typesData)

        // Handle array size
        if typesBytes.first == 0x5B {  // '[' character
            if let (arrayTypes, _) = MessageTypedStreamType.getArrayLength(types: typesBytes) {
                return arrayTypes
            } else {
                throw MessageTypedStreamDecoderError.invalidArray
            }
        }

        return typesBytes.map { MessageTypedStreamType.fromByte($0) }
    }

    /// Reads a type reference pointer from the stream.
    private func readPointer() throws -> UInt32 {
        let pointer = try getCurrentByte()
        idx += 1
        let referenceTag = UInt8(REFERENCE_TAG)
        // typedstream references are encoded in a signed byte domain:
        // valid reference bytes are [0x92...0xFF] and [0x00...0x7F].
        guard pointer < 0x80 || pointer >= referenceTag else {
            throw MessageTypedStreamDecoderError.invalidPointer(pointer)
        }
        return UInt32(pointer &- referenceTag)
    }

    /// Parses a class declaration or reference.
    private func readClass(depth: Int = 0) throws -> ClassResult {
        guard depth <= 256 else { throw MessageTypedStreamDecoderError.nestingTooDeep }
        var output: [MessageTypedStreamValue] = []
        switch try getCurrentByte() {
        case START:
            // Skip some header bytes
            while try getCurrentByte() == START {
                idx += 1
            }
            let length = try readUnsignedInt()

            if length >= REFERENCE_TAG {
                let index = length - REFERENCE_TAG
                return .index(Int(index))
            }

            let className = try readExactAsString(length: Int(length))
            let version = try readUnsignedInt()

            typesTable.append([.newString(className)])
            try consumeDecodedValues()
            output.append(.class(MessageTypedStreamClass(name: className, version: version)))

            let parentClassResult = try readClass(depth: depth + 1)
            if case .classHierarchy(let parent) = parentClassResult {
                try consumeDecodedValues(parent.count)
                output.append(contentsOf: parent)
            }
        case EMPTY:
            idx += 1
        default:
            let index = try readPointer()
            return .index(Int(index))
        }
        return .classHierarchy(output)
    }

    /// Reads an object from the stream or returns a cached reference.
    private func readObject() throws -> MessageTypedStreamValue? {
        switch try getCurrentByte() {
        case START:
            let classResult = try readClass()
            switch classResult {
            case .index(let idx):
                return objectTable[safe: idx]
            case .classHierarchy(let classes):
                try consumeDecodedValues(classes.count)
                objectTable.append(contentsOf: classes)
            }
            return nil
        case EMPTY:
            idx += 1
            return nil
        default:
            let index = try readPointer()
            return objectTable[safe: Int(index)]
        }
    }

    /// Reads a length-prefixed string from the stream.
    private func readString() throws -> String {
        let length = try readUnsignedInt()
        let string = try readExactAsString(length: Int(length))
        return string
    }

    /// Reads embedded `MessageTypedStreamValue` data (e.g. from `MessageTypedStreamType.embeddedData`).
    private func readEmbeddedData() throws -> MessageTypedStreamValue? {
        guard embeddedDepth < 256 else { throw MessageTypedStreamDecoderError.nestingTooDeep }
        embeddedDepth += 1
        defer { embeddedDepth -= 1 }
        // Skip the 0x84
        idx += 1
        if let types = try getType(embedded: true) {
            return try readTypes(foundTypes: types)
        }
        return nil
    }

    /// Returns the current type(s), from the stream or `typesTable` by reference.
    /// - Parameter embedded: When true, records embedded types in the object table.
    private func getType(embedded: Bool) throws -> [MessageTypedStreamType]? {
        switch try getCurrentByte() {
        case START:
            // Ignore repeated types, for example in a dict
            idx += 1
            let objectTypes = try readType()
            // Embedded data is stored as a C String in the objects table
            if embedded {
                try consumeDecodedValues()
                objectTable.append(.type(objectTypes))
                seenEmbeddedTypes.insert(UInt32(typesTable.count))
            }
            typesTable.append(objectTypes)
            return typesTable.last
        case END:
            // This indicates the end of the current object
            return nil
        default:
            // Ignore repeated types, for example in a dict
            while try getCurrentByte() == getNextByte() {
                idx += 1
            }
            let refTag = try readPointer()
            let result = typesTable[safe: Int(refTag)]
            if embedded, let res = result {
                // We only want to include the first embedded reference tag, not subsequent references to the same embed
                if !seenEmbeddedTypes.contains(refTag) {
                    try consumeDecodedValues()
                    objectTable.append(.type(res))
                    seenEmbeddedTypes.insert(refTag)
                }
            }
            return result
        }
    }

    /// Parses stream data according to the given types and returns an `MessageTypedStreamValue`.
    private func readTypes(foundTypes: [MessageTypedStreamType]) throws -> MessageTypedStreamValue? {
        // Reserve the full type expansion up front so references cannot repeatedly
        // inflate a small declaration into an unbounded output graph.
        try consumeDecodedValues(foundTypes.count)
        var output: [MessageTypedStreamObject] = []
        var isObject = false

        for foundType in foundTypes {
            switch foundType {
            case .utf8String:
                let string = try readString()
                output.append(.string(string))
            case .embeddedData:
                if let embeddedData = try readEmbeddedData() {
                    return embeddedData
                }
            case .object:
                isObject = true
                let length = objectTable.count
                placeholder = length
                try consumeDecodedValues()
                objectTable.append(.placeholder)
                if let object = try readObject() {
                    switch object {
                    case .object(_, let data):
                        // If this is a new object, i.e. one without any data, we add the data into it later
                        // If the object already has data in it, we just want to return that object
                        if !data.isEmpty {
                            placeholder = nil
                            objectTable.removeLast()
                            return object
                        }
                        try consumeDecodedValues(data.count)
                        output.append(contentsOf: data)
                    case .class(let cls):
                        output.append(.class(cls))
                    case .data(let data):
                        try consumeDecodedValues(data.count)
                        output.append(contentsOf: data)
                    default:
                        break
                    }
                }
            case .signedInt:
                let value = try readSignedInt()
                output.append(.signedInteger(value))
            case .unsignedInt:
                let value = try readUnsignedInt()
                output.append(.unsignedInteger(value))
            case .float:
                let value = try readFloat()
                output.append(.float(value))
            case .double:
                let value = try readDouble()
                output.append(.double(value))
            case .unknown(let byte):
                output.append(.byte(byte))
            case .string(let s):
                output.append(.string(s))
            case .array(let size):
                let array = try readArray(size: size)
                output.append(.array(array))
            }
        }

        // If we had reserved a place for an object, fill that spot
        if let spot = placeholder {
            if !output.isEmpty {
                // We got a class, but do not have its respective data yet
                if let last = output.last, case .class(let cls) = last {
                    objectTable[spot] = .object(cls, [])
                }
                // The spot after the current placeholder contains the class at the top of the class hierarchy
                else if let next = objectTable[safe: spot + 1], case .class(let cls) = next {
                    objectTable[spot] = .object(cls, output)
                    placeholder = nil
                    return objectTable[spot]
                }
                // We got some data for a class that was already seen
                else if case .object(let cls, var data) = objectTable[spot] {
                    try consumeDecodedValues(output.count)
                    data.append(contentsOf: output)
                    objectTable[spot] = .object(cls, data)
                    placeholder = nil
                    return objectTable[spot]
                }
                // We got some data that is not part of a class
                else {
                    objectTable[spot] = .data(output)
                    placeholder = nil
                    return objectTable[spot]
                }
            }
        }

        if !output.isEmpty && !isObject {
            return .data(output)
        }

        return nil
    }
}

// MARK: -

extension Array {
    /// Returns the element at `index` if in bounds; otherwise `nil`.
    fileprivate subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}