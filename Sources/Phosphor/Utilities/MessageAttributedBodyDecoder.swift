import Foundation

/// Recovers message text that recent iOS versions store only in the
/// `message.attributedBody` NSArchiver typedstream blob.
enum MessageAttributedBodyDecoder {
    private static let typedstreamSignature = Data([0x04, 0x0B]) + Data("streamtyped".utf8)
    static let maximumArchiveSize = 16 * 1024 * 1024
    static let attributedBodyCandidateSQLProjection = """
        CASE WHEN (m.text IS NULL OR m.text = '')
                  AND length(m.attributedBody) <= \(maximumArchiveSize)
             THEN m.ROWID ELSE NULL END AS attributed_body_rowid
        """
    static let attributedBodySQLProjection = """
        CASE WHEN length(m.attributedBody) <= \(maximumArchiveSize)
             THEN m.attributedBody ELSE NULL END AS attributedBody
        """

    static func text(from data: Data) -> String? {
        guard data.count >= typedstreamSignature.count,
              data.count <= maximumArchiveSize,
              data.starts(with: typedstreamSignature),
              let values = try? MessageTypedStreamDecoder.decode(data) else {
            return nil
        }

        // An archived NSAttributedString stores its visible body as the first
        // NSString/NSMutableString object. Later strings are formatting keys and
        // attribute metadata, so joining every decoded string corrupts the body.
        for value in values {
            guard case let .object(classInfo, objects) = value,
                  classInfo.name == "NSString" || classInfo.name == "NSMutableString",
                  let first = objects.first,
                  case let .string(text) = first else {
                continue
            }
            return text.isEmpty ? nil : text
        }
        return nil
    }
}
