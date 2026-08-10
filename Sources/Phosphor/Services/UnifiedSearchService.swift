import Foundation

enum UnifiedSearchError: LocalizedError, Sendable {
    case lockedBackup
    case invalidBackup

    var errorDescription: String? {
        switch self {
        case .lockedBackup:
            return "This backup is encrypted. Unlock it from Backups, then search again."
        case .invalidBackup:
            return "The selected backup is incomplete or unreadable. Choose a different backup or create a new one."
        }
    }
}

enum UnifiedSearchService {
    static func search(
        query: String,
        backupPath: String,
        sources: Set<UnifiedSearchSource> = Set(UnifiedSearchSource.allCases),
        limitPerSource: Int = 250
    ) throws -> UnifiedSearchResponse {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return UnifiedSearchResponse(results: [], sourceErrors: [:])
        }

        do {
            _ = try BackupManifest(backupPath: backupPath)
        } catch let manifestError as BackupManifest.ManifestError {
            switch manifestError {
            case .backupEncrypted:
                throw UnifiedSearchError.lockedBackup
            case .manifestMissing, .manifestUnreadable, .invalidFileID:
                throw UnifiedSearchError.invalidBackup
            }
        } catch {
            throw UnifiedSearchError.invalidBackup
        }

        var results: [UnifiedSearchResult] = []
        var sourceErrors: [UnifiedSearchSource: String] = [:]

        func attempt(_ source: UnifiedSearchSource, _ operation: () throws -> [UnifiedSearchResult]) throws {
            guard sources.contains(source) else { return }
            try Task.checkCancellation()
            do {
                results.append(contentsOf: try operation().prefix(limitPerSource))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                sourceErrors[source] = "This source could not be searched in the selected backup."
            }
        }

        try attempt(.messages) {
            let exporter = try MessageExporter(backupPath: backupPath)
            return try exporter.searchMessages(normalized, limit: limitPerSource).map { message in
                UnifiedSearchResult(
                    source: .messages,
                    sourceID: String(message.id),
                    title: message.senderLabel,
                    subtitle: message.service.isEmpty ? "Message" : message.service,
                    snippet: compact(message.displayText),
                    date: message.date
                )
            }
        }

        try attempt(.whatsApp) {
            let exporter = try WhatsAppExporter(backupPath: backupPath)
            return try exporter.searchMessages(normalized, limit: limitPerSource).map { message in
                let sender = message.isFromMe
                    ? "Me"
                    : (message.senderJid ?? "Unknown").replacingOccurrences(of: "@s.whatsapp.net", with: "")
                return UnifiedSearchResult(
                    source: .whatsApp,
                    sourceID: String(message.id),
                    title: sender,
                    subtitle: "WhatsApp",
                    snippet: compact(message.displayText),
                    date: message.date
                )
            }
        }

        try attempt(.notes) {
            try NotesExtractor(backupPath: backupPath).searchNotes(normalized, limit: limitPerSource).map { note in
                UnifiedSearchResult(
                    source: .notes,
                    sourceID: String(note.id),
                    title: note.displayTitle,
                    subtitle: note.folderName,
                    snippet: compact(note.snippet),
                    date: note.modifiedDate
                )
            }
        }

        try attempt(.contacts) {
            try ContactsExtractor(backupPath: backupPath).searchContacts(normalized, limit: limitPerSource).map { contact in
                let details = (contact.phoneNumbers + contact.emails).joined(separator: " • ")
                return UnifiedSearchResult(
                    source: .contacts,
                    sourceID: String(contact.id),
                    title: contact.fullName.isEmpty ? "Unnamed Contact" : contact.fullName,
                    subtitle: contact.organization.isEmpty ? "Contact" : contact.organization,
                    snippet: compact(details),
                    date: contact.createdDate
                )
            }
        }

        try attempt(.callLog) {
            try CallLogExtractor(backupPath: backupPath).searchCallLog(normalized, limit: limitPerSource).map { call in
                UnifiedSearchResult(
                    source: .callLog,
                    sourceID: String(call.id),
                    title: call.address,
                    subtitle: call.callType.label,
                    snippet: call.durationString,
                    date: call.date
                )
            }
        }

        if sources.contains(.safari) {
            try Task.checkCancellation()
            let extractor = SafariExtractor(backupPath: backupPath)
            var bookmarks: [UnifiedSearchResult] = []
            var history: [UnifiedSearchResult] = []

            do {
                bookmarks = try extractor.searchBookmarks(normalized, limit: limitPerSource).map { bookmark in
                    UnifiedSearchResult(
                        source: .safari,
                        sourceID: "bookmark-\(bookmark.id)",
                        title: bookmark.displayTitle,
                        subtitle: "Bookmark • \(bookmark.parentTitle)",
                        snippet: compact(bookmark.url),
                        date: nil
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                sourceErrors[.safari] = "Some Safari data could not be searched in the selected backup."
            }

            try Task.checkCancellation()
            do {
                history = try extractor.searchHistory(normalized, limit: limitPerSource).map { item in
                    UnifiedSearchResult(
                        source: .safari,
                        sourceID: "history-\(item.id)",
                        title: item.displayTitle,
                        subtitle: "History • \(item.visitCount) visits",
                        snippet: compact(item.url),
                        date: item.lastVisitDate
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                sourceErrors[.safari] = "Some Safari data could not be searched in the selected backup."
            }

            results.append(contentsOf: interleave(bookmarks, history, limit: limitPerSource))
        }

        try attempt(.files) {
            let manifest = try BackupManifest(backupPath: backupPath)
            return try manifest.search(normalized, limit: limitPerSource).map { entry in
                UnifiedSearchResult(
                    source: .files,
                    sourceID: entry.id,
                    title: entry.fileName.isEmpty ? entry.relativePath : entry.fileName,
                    subtitle: entry.domain,
                    snippet: compact(entry.relativePath),
                    date: nil
                )
            }
        }

        try Task.checkCancellation()
        return UnifiedSearchResponse(
            results: UnifiedSearchExporter.ordered(results),
            sourceErrors: sourceErrors
        )
    }

    private static func matches(_ query: String, in values: [String]) -> Bool {
        values.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Apply one shared Safari budget without allowing either bookmarks or
    /// history to consume every retained slot when both have matches.
    private static func interleave(
        _ first: [UnifiedSearchResult],
        _ second: [UnifiedSearchResult],
        limit: Int
    ) -> [UnifiedSearchResult] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }
        var merged: [UnifiedSearchResult] = []
        merged.reserveCapacity(min(boundedLimit, first.count + second.count))
        var index = 0
        while merged.count < boundedLimit && (index < first.count || index < second.count) {
            if index < first.count { merged.append(first[index]) }
            if merged.count < boundedLimit, index < second.count { merged.append(second[index]) }
            index += 1
        }
        return merged
    }

    private static func compact(_ value: String, limit: Int = 240) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "…"
    }
}
