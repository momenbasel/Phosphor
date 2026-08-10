// Adapted from Madrid TypedStream at commit 8f5f4f1.
// Copyright 2025 Mattt. Licensed under the MIT License; see THIRD_PARTY_NOTICES.md.

/// Represents primitive types of data that can be stored in a `typedstream`
///
/// These type encodings are partially documented [here](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html) by Apple.
public enum MessageTypedStreamType: Hashable, Sendable {
    /// Encoded string data, usually embedded in an object. Denoted by:
    ///
    /// | Hex    | UTF-8 |
    /// |--------|-------|
    /// | `0x28` | `+`   |
    case utf8String
    /// Encoded bytes that can be parsed again as data. Denoted by:
    ///
    /// | Hex    | UTF-8 |
    /// |--------|-------|
    /// | `0x2A` | `*`   |
    case embeddedData
    /// An instance of a class, usually with data. Denoted by:
    ///
    /// | Hex    | UTF-8 |
    /// |--------|-------|
    /// | `0x40` | `@`   |
    case object
    /// A signed integer type. Denoted by:
    ///
    /// | Hex    | UTF-8 |
    /// |--------|-------|
    /// | `0x63` | `c`   |
    /// | `0x69` | `i`   |
    /// | `0x6C` | `l`   |
    /// | `0x71` | `q`   |
    /// | `0x73` | `s`   |
    case signedInt
    /// An unsigned integer type. Denoted by:
    ///
    /// | Hex    | UTF-8 |
    /// |--------|-------|
    /// | `0x43` | `C`   |
    /// | `0x49` | `I`   |
    /// | `0x4C` | `L`   |
    /// | `0x51` | `Q`   |
    /// | `0x53` | `S`   |
    case unsignedInt
    /// A `Float` value. Denoted by:
    ///
    /// | Hex    | UTF-8 |
    /// |--------|-------|
    /// | `0x66` | `f`   |
    case float
    /// A `Double` value. Denoted by:
    ///
    /// | Hex    | UTF-8 |
    /// |--------|-------|
    /// | `0x64` | `d`   |
    case double
    /// Some text we can reuse later, e.g., a class name.
    case string(String)
    /// An array containing some data of a given length. Denoted by braced digits: `[123]`.
    case array(Int)
    /// Data for which we do not know the type.
    case unknown(UInt8)

    static func fromByte(_ byte: UInt8) -> MessageTypedStreamType {
        switch byte {
        case 0x40:
            return .object
        case 0x2B:
            return .utf8String
        case 0x2A:
            return .embeddedData
        case 0x66:
            return .float
        case 0x64:
            return .double
        case 0x63, 0x69, 0x6C, 0x71, 0x73:
            return .signedInt
        case 0x43, 0x49, 0x4C, 0x51, 0x53:
            return .unsignedInt
        default:
            return .unknown(byte)
        }
    }

    static func newString(_ string: String) -> MessageTypedStreamType {
        return .string(string)
    }

    static func getArrayLength(types: [UInt8]) -> ([MessageTypedStreamType], Int)? {
        guard let first = types.first, first == 0x5B else {  // '[' character
            return nil
        }
        var length = 0
        var index = 1
        while index < types.count,
            let digit = UInt8(exactly: types[index]),
            (48 ... 57).contains(digit)
        {
            let value = Int(digit - 48)  // ASCII '0' is 48
            guard length <= (Int.max - value) / 10 else { return nil }
            length = length * 10 + value
            index += 1
        }
        if length > 0 {
            return ([.array(length)], index)
        } else {
            return nil
        }
    }
}