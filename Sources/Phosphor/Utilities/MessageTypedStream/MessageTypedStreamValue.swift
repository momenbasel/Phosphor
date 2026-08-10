// Adapted from Madrid TypedStream at commit 8f5f4f1.
// Copyright 2025 Mattt. Licensed under the MIT License; see THIRD_PARTY_NOTICES.md.

/// Types of data that can be archived into the `typedstream`
public enum MessageTypedStreamValue: Hashable, Sendable {
    /// An instance of a class that may contain some embedded data.
    /// `typedstream` data doesn't include property names, so data is stored in order of appearance.
    case object(MessageTypedStreamClass, [MessageTypedStreamObject])
    /// Data that is likely a property on the object described by the `typedstream` but not part of a class.
    case data([MessageTypedStreamObject])
    /// A class referenced in the `typedstream`, usually part of an inheritance hierarchy that does not contain any data itself.
    case `class`(MessageTypedStreamClass)
    /// A placeholder, used when reserving a spot in the objects table for a reference to be filled with class information.
    case placeholder
    /// A type that made it through the parsing process without getting replaced by an object.
    case type([MessageTypedStreamType])

    // MARK: - Convenience Properties

    /// If this archivable represents an `NSString` or `NSMutableString` object,
    /// returns its string value.
    ///
    /// ### Example
    /// ```swift
    /// let nsstring = MessageTypedStreamValue.object(
    ///     MessageTypedStreamClass(name: "NSString", version: 1),
    ///     [.string("Hello world")]
    /// )
    /// print(nsstring.stringValue) // Optional("Hello world")
    ///
    /// let notNSString = MessageTypedStreamValue.object(
    ///     MessageTypedStreamClass(name: "NSNumber", version: 1),
    ///     [.signedInteger(100)]
    /// )
    /// print(notNSString.stringValue) // nil
    /// ```
    public var stringValue: String? {
        if case let .object(classInfo, value) = self,
            classInfo.name == "NSString" || classInfo.name == "NSMutableString",
            let first = value.first,
            case let .string(text) = first
        {
            // Filter out strings that look like attribute keys or metadata
            if text.hasPrefix("__k")  // System keys often start with __k
                || text.contains("Attribute")  // Attribute names
                || text.contains("NS")  // Foundation framework keys
                || !text.contains(where: { $0.isLetter || $0.isNumber })  // Strings with no letters or numbers are likely metadata
            {
                return nil
            }

            return text
        }
        return nil
    }

    /// If this archivable represents an `NSNumber` object containing an integer,
    /// returns its 64-bit integer value.
    ///
    /// ### Example
    /// ```swift
    /// let nsnumber = MessageTypedStreamValue.object(
    ///     MessageTypedStreamClass(name: "NSNumber", version: 1),
    ///     [.signedInteger(100)]
    /// )
    /// print(nsnumber.integerValue) // Optional(100)
    ///
    /// let notNSNumber = MessageTypedStreamValue.object(
    ///     MessageTypedStreamClass(name: "NSString", version: 1),
    ///     [.string("Hello world")]
    /// )
    /// print(notNSNumber.integerValue) // nil
    /// ```
    public var integerValue: Int64? {
        if case let .object(classInfo, value) = self,
            classInfo.name == "NSNumber",
            let first = value.first,
            case let .signedInteger(num) = first
        {
            return num
        }
        return nil
    }

    /// If this archivable represents an `NSNumber` object containing a floating-point value,
    /// returns its double-precision value.
    ///
    /// ### Example
    /// ```swift
    /// let nsnumber = MessageTypedStreamValue.object(
    ///     MessageTypedStreamClass(name: "NSNumber", version: 1),
    ///     [.double(100.001)]
    /// )
    /// print(nsnumber.doubleValue) // Optional(100.001)
    ///
    /// let notNSNumber = MessageTypedStreamValue.object(
    ///     MessageTypedStreamClass(name: "NSString", version: 1),
    ///     [.string("Hello world")]
    /// )
    /// print(notNSNumber.doubleValue) // nil
    /// ```
    public var doubleValue: Double? {
        if case let .object(classInfo, value) = self,
            classInfo.name == "NSNumber",
            let first = value.first,
            case let .double(num) = first
        {
            return num
        }
        return nil
    }
}