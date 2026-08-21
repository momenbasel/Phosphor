import Foundation

@MainActor
final class UnifiedSearchViewModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            invalidateSearchState()
        }
    }
    @Published var selectedBackup: BackupInfo?
    @Published var enabledSources = Set(UnifiedSearchSource.allCases) {
        didSet {
            guard enabledSources != oldValue else { return }
            invalidateSearchState()
        }
    }
    @Published private(set) var results: [UnifiedSearchResult] = []
    @Published private(set) var sourceErrors: [UnifiedSearchSource: String] = [:]
    @Published var selectedResultIDs = Set<UnifiedSearchResult.ID>()
    @Published private(set) var isSearching = false
    @Published private(set) var hasCompletedSearch = false
    @Published private(set) var errorMessage: String?

    private var searchTask: Task<Void, Never>?
    private(set) var searchOperationID: UUID?

    private struct SearchFailure: Error, Sendable {
        let message: String
    }

    var selectedResults: [UnifiedSearchResult] {
        results.filter { selectedResultIDs.contains($0.id) }
    }

    func chooseBackup(_ backup: BackupInfo?) {
        guard selectedBackup?.path != backup?.path else { return }
        invalidateSearchState()
        selectedBackup = backup
    }

    func search() {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let backup = selectedBackup else {
            errorMessage = "Choose a backup before searching."
            return
        }
        guard normalized.count >= 2 else {
            errorMessage = "Enter at least two characters."
            return
        }
        guard !enabledSources.isEmpty else {
            errorMessage = "Choose at least one data source."
            return
        }

        searchTask?.cancel()
        let operationID = UUID()
        searchOperationID = operationID
        let sources = enabledSources
        isSearching = true
        hasCompletedSearch = false
        errorMessage = nil
        results = []
        sourceErrors = [:]
        selectedResultIDs = []

        searchTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    return Result<UnifiedSearchResponse, SearchFailure>.success(
                        try UnifiedSearchService.search(
                            query: normalized,
                            backupPath: backup.path,
                            sources: sources
                        )
                    )
                } catch is CancellationError {
                    return .failure(SearchFailure(message: "Search cancelled."))
                } catch {
                    return .failure(SearchFailure(message: error.localizedDescription))
                }
            }
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled, searchOperationID == operationID else { return }
            isSearching = false
            searchTask = nil
            switch outcome {
            case .success(let response):
                results = response.results
                sourceErrors = response.sourceErrors
                hasCompletedSearch = true
            case .failure(let failure):
                if !Task.isCancelled && failure.message != "Search cancelled." {
                    errorMessage = failure.message
                }
            }
        }
    }

    func cancel() {
        invalidateSearchState()
    }

    private func invalidateSearchState() {
        searchTask?.cancel()
        searchTask = nil
        searchOperationID = nil
        isSearching = false
        hasCompletedSearch = false
        results = []
        sourceErrors = [:]
        selectedResultIDs = []
        errorMessage = nil
    }

    func selectAllVisible() {
        selectedResultIDs = Set(results.map(\.id))
    }

    func clearSelection() {
        selectedResultIDs = []
    }
}
