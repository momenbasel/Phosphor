// Adapted from Madrid TypedStream at commit 8f5f4f1.
// Copyright 2025 Mattt. Licensed under the MIT License; see THIRD_PARTY_NOTICES.md.

/// Structures containing data stored in the `typedstream`
public enum MessageTypedStreamObject: Hashable, Sendable {
    /// Text data, denoted in the stream by `MessageTypedStreamType.utf8String`
    case string(String)
    /// Signed integer types, denoted in the stream by `MessageTypedStreamType.signedInt`
    case signedInteger(Int64)
    /// Unsigned integer types, denoted in the stream by `MessageTypedStreamType.unsignedInt`
    case unsignedInteger(UInt64)
    /// Floating point numbers, denoted in the stream by `MessageTypedStreamType.float`
    case float(Float)
    /// Double precision floats, denoted in the stream by `MessageTypedStreamType.double`
    case double(Double)
    /// Bytes whose type is not known, denoted in the stream by `MessageTypedStreamType.unknown`
    case byte(UInt8)
    /// Collection of bytes in an array, denoted in the stream by `MessageTypedStreamType.array`
    case array([UInt8])
    /// A found class, used by `MessageTypedStreamValue.classCase`
    case `class`(MessageTypedStreamClass)
}