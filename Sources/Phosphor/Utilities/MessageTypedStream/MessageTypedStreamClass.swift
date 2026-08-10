// Adapted from Madrid TypedStream at commit 8f5f4f1.
// Copyright 2025 Mattt. Licensed under the MIT License; see THIRD_PARTY_NOTICES.md.

/// Represents a class stored in the `typedstream`
public struct MessageTypedStreamClass: Hashable, Sendable {
    /// The name of the class
    public let name: String
    /// The encoded version of the class
    public let version: UInt64

    /// Creates class metadata for a `typedstream` class entry.
    ///
    /// - Parameters:
    ///   - name: The class name.
    ///   - version: The encoded class version.
    public init(name: String, version: UInt64) {
        self.name = name
        self.version = version
    }
}