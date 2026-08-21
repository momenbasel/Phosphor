from __future__ import annotations

from pathlib import Path
import sqlite3
import subprocess
import tempfile


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_unified_search_export_is_deterministic_and_formula_safe(root: Path) -> None:
    model = root / "Sources/Phosphor/Models/UnifiedSearchResult.swift"
    exporter = root / "Sources/Phosphor/Services/UnifiedSearchExporter.swift"
    csv_helper = root / "Sources/Phosphor/Utilities/CSVExport.swift"
    assert model.exists(), "UnifiedSearchResult must exist"
    assert exporter.exists(), "UnifiedSearchExporter must exist"

    probe = r'''
import Foundation

@main
struct Probe {
    static func main() throws {
        let results = [
            UnifiedSearchResult(source: .notes, sourceID: "2", title: "=formula", subtitle: "Folder", snippet: "second", date: nil),
            UnifiedSearchResult(source: .messages, sourceID: "1", title: "Alice", subtitle: "Message", snippet: "first", date: Date(timeIntervalSince1970: 10)),
        ]
        let csv = UnifiedSearchExporter.csvData(results: results)
        let json = try UnifiedSearchExporter.jsonData(results: results)
        print("CSV|" + String(decoding: csv, as: UTF8.self).replacingOccurrences(of: "\n", with: "<NL>"))
        let decoded = try JSONSerialization.jsonObject(with: json) as! [[String: Any]]
        print("JSON|\(decoded.count)|\(decoded[0]["source"] as! String)|\(decoded[1]["source"] as! String)")
        print("PRIVATE_IDS|\(decoded.contains { $0["source_id"] != nil })")
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "unified-search-export-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(csv_helper), str(model), str(exporter), str(probe_path), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)

    assert result.returncode == 0, result.stderr
    assert "CSV|Source,Title,Subtitle,Snippet,Date<NL>" in result.stdout, result.stdout
    assert "'=formula" in result.stdout, "spreadsheet formula prefixes must be neutralized"
    assert "JSON|2|messages|notes" in result.stdout, "exports must use stable chronological/source ordering"
    assert "PRIVATE_IDS|false" in result.stdout, "JSON must not expose backup hashes or database row identifiers"


def test_unified_search_covers_backup_data_sources(root: Path) -> None:
    service = read(root, "Sources/Phosphor/Services/UnifiedSearchService.swift")
    model = read(root, "Sources/Phosphor/Models/UnifiedSearchResult.swift")
    notes = read(root, "Sources/Phosphor/Services/NotesExtractor.swift")
    contacts = read(root, "Sources/Phosphor/Services/ContactsExtractor.swift")
    safari = read(root, "Sources/Phosphor/Services/SafariExtractor.swift")
    calls = read(root, "Sources/Phosphor/Services/CallLogExtractor.swift")
    for case in ["messages", "whatsApp", "notes", "contacts", "callLog", "safari", "files"]:
        assert f"case {case}" in model, f"missing unified search source {case}"
    for adapter in [
        "MessageExporter", "WhatsAppExporter", "NotesExtractor", "ContactsExtractor",
        "CallLogExtractor", "SafariExtractor", "BackupManifest",
    ]:
        assert adapter in service, f"UnifiedSearchService must search {adapter}"
    assert "Task.checkCancellation()" in service, "source fan-in must be cancellable between expensive adapters"
    assert "sourceErrors" in service, "one unavailable source must not hide results from healthy sources"
    assert "error.localizedDescription" not in service, "source failures must not expose backup paths or private identifiers"
    assert "case lockedBackup" in service and "case invalidBackup" in service
    assert "BackupManifest.ManifestError" in service, "search should preflight locked/incomplete backups once"
    assert "searchNotes(normalized, limit: limitPerSource)" in service
    assert "searchContacts(normalized, limit: limitPerSource)" in service
    assert "searchBookmarks(normalized, limit: limitPerSource)" in service
    assert "searchHistory(normalized, limit: limitPerSource)" in service
    safari_block = service.split("if sources.contains(.safari)", 1)[1].split("try attempt(.files)", 1)[0]
    assert "try attempt(.safari)" not in service
    assert safari_block.count("} catch is CancellationError {") == 2
    assert safari_block.count("sourceErrors[.safari]") == 2
    assert safari_block.index("searchBookmarks") < safari_block.index("searchHistory")
    assert "func searchNotes(_ query: String, limit: Int" in notes
    assert "ZHTMLSTRING" not in notes.split("func searchNotes(_ query: String, limit: Int", 1)[1], "search must not load full note HTML"
    assert "func searchContacts(_ query: String, limit: Int" in contacts
    assert "func searchBookmarks(_ query: String, limit: Int" in safari
    assert "func searchHistory(_ query: String, limit: Int" in safari
    assert "searchCallLog(normalized, limit: limitPerSource)" in service
    assert "func searchCallLog(_ query: String, limit: Int" in calls
    assert "WHERE \\(predicate)" in calls and "LIMIT \\(boundedLimit)" in calls
    assert "interleave(bookmarks, history, limit: limitPerSource)" in service
    assert '"source_id"' not in read(root, "Sources/Phosphor/Services/UnifiedSearchExporter.swift")


def test_unified_search_warns_and_drops_partial_corrupt_safari_history(root: Path) -> None:
    support = r'''
import Foundation

extension Date {
    var shortString: String { "" }
    var iso8601String: String { "" }
}

enum MessageExportFormat { case csv, json, text }
enum CSVExport { static func row(_ values: [String]) -> String { "" } }

struct StubMessage {
    let id = 1
    let senderLabel = ""
    let service = ""
    let displayText = ""
    let date: Date? = nil
    let isFromMe = false
    let senderJid: String? = nil
}
final class MessageExporter {
    init(backupPath: String) throws {}
    func searchMessages(_ query: String, limit: Int) throws -> [StubMessage] { [] }
}
final class WhatsAppExporter {
    init(backupPath: String) throws {}
    func searchMessages(_ query: String, limit: Int) throws -> [StubMessage] { [] }
}

struct StubNote {
    let id = 1
    let displayTitle = ""
    let folderName = ""
    let snippet = ""
    let modifiedDate: Date? = nil
}
final class NotesExtractor {
    init(backupPath: String) throws {}
    func searchNotes(_ query: String, limit: Int) throws -> [StubNote] { [] }
}

struct StubContact {
    let id = 1
    let phoneNumbers: [String] = []
    let emails: [String] = []
    let fullName = ""
    let organization = ""
    let createdDate: Date? = nil
}
final class ContactsExtractor {
    init(backupPath: String) throws {}
    func searchContacts(_ query: String, limit: Int) throws -> [StubContact] { [] }
}

struct StubCallType { let label = "" }
struct StubCall {
    let id = 1
    let address = ""
    let callType = StubCallType()
    let durationString = ""
    let date: Date? = nil
}
final class CallLogExtractor {
    init(backupPath: String) throws {}
    func searchCallLog(_ query: String, limit: Int) throws -> [StubCall] { [] }
}

enum UnifiedSearchExporter {
    static func ordered(_ results: [UnifiedSearchResult]) -> [UnifiedSearchResult] { results }
}

final class BackupManifest {
    enum ManifestError: Error { case backupEncrypted, manifestMissing, manifestUnreadable, invalidFileID(String) }
    struct FileEntry {
        let id: String
        let isFile: Bool
        let relativePath: String
        let domain: String
        let fileName: String
        let diskPath: String
    }

    private let backupPath: String
    init(backupPath: String) throws { self.backupPath = backupPath }

    func search(_ query: String, limit: Int = 250) throws -> [FileEntry] {
        let name: String
        if query.contains("Bookmarks.db") { name = "Bookmarks.db" }
        else if query.contains("History.db") { name = "History.db" }
        else { return [] }
        return [FileEntry(
            id: name,
            isFile: true,
            relativePath: "Library/Safari/\(name)",
            domain: "HomeDomain",
            fileName: name,
            diskPath: (backupPath as NSString).appendingPathComponent(name)
        )]
    }

    func readablePath(for entry: FileEntry) throws -> String { entry.diskPath }
}
'''
    probe = r'''
import Foundation

@main
struct Probe {
    static func main() throws {
        let response = try UnifiedSearchService.search(
            query: "needle",
            backupPath: CommandLine.arguments[1],
            sources: Set([.safari]),
            limitPerSource: 1_000
        )
        let bookmarkCount = response.results.filter { $0.sourceID.hasPrefix("bookmark-") }.count
        let historyCount = response.results.filter { $0.sourceID.hasPrefix("history-") }.count
        let warning = response.sourceErrors[.safari] ?? "missing"
        print("BOOKMARKS|\(bookmarkCount)")
        print("HISTORY|\(historyCount)")
        print("WARNING|\(warning)")
        print("PRIVATE|\(warning.contains(CommandLine.arguments[1]))")
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        bookmarks = temp / "Bookmarks.db"
        connection = sqlite3.connect(bookmarks)
        connection.execute(
            "CREATE TABLE bookmarks(id INTEGER PRIMARY KEY, title TEXT, url TEXT, order_index INTEGER, parent INTEGER)"
        )
        connection.execute("INSERT INTO bookmarks VALUES (1, 'Folder', NULL, 0, NULL)")
        connection.execute("INSERT INTO bookmarks VALUES (2, 'needle bookmark', 'https://example.invalid', 1, 1)")
        connection.commit()
        connection.close()

        history = temp / "History.db"
        connection = sqlite3.connect(history)
        connection.execute("PRAGMA page_size=1024")
        connection.execute("PRAGMA journal_mode=DELETE")
        connection.execute(
            "CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER)"
        )
        connection.execute("CREATE TABLE history_visits(history_item INTEGER, visit_time REAL)")
        for index in range(1, 2_001):
            connection.execute(
                "INSERT INTO history_items VALUES (?, ?, ?, 1)",
                (index, f"https://example.invalid/{index}", f"needle-{index}-" + ("x" * 700)),
            )
            connection.execute("INSERT INTO history_visits VALUES (?, ?)", (index, float(index)))
        connection.commit()
        connection.close()
        page_size = 1024
        page_count = history.stat().st_size // page_size
        with history.open("r+b") as handle:
            handle.seek((max(10, page_count // 3) - 1) * page_size)
            handle.write(b"\0" * page_size)

        support_path = temp / "Support.swift"
        support_path.write_text(support)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "unified-search-corrupt-source-probe"
        compile_result = subprocess.run(
            [
                "swiftc", "-parse-as-library",
                str(root / "Sources/Phosphor/Utilities/SQLiteReader.swift"),
                str(root / "Sources/Phosphor/Models/UnifiedSearchResult.swift"),
                str(root / "Sources/Phosphor/Services/SafariExtractor.swift"),
                str(root / "Sources/Phosphor/Services/UnifiedSearchService.swift"),
                str(support_path), str(probe_path), "-lsqlite3", "-o", str(executable),
            ],
            capture_output=True,
            text=True,
            timeout=90,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable), str(temp)], capture_output=True, text=True, timeout=30)

    assert result.returncode == 0, result.stderr
    assert "BOOKMARKS|1" in result.stdout, result.stdout
    assert "HISTORY|0" in result.stdout, "corrupt history rows must not be published as complete: " + result.stdout
    assert "WARNING|Some Safari data could not be searched in the selected backup." in result.stdout, result.stdout
    assert "PRIVATE|false" in result.stdout, "source warnings must not expose backup paths: " + result.stdout


def test_call_log_search_queries_before_limiting(root: Path) -> None:
    probe = r'''
import Foundation

extension Int { var formattedFileSize: String { String(self) } }
extension Date { var shortString: String { "" } }
enum CSVExport { static func row(_ values: [String]) -> String { "" } }

final class BackupManifest {
    struct FileEntry { let isFile = false }
    init(backupPath: String) throws {}
    func search(_ query: String) throws -> [FileEntry] { [] }
    func readablePath(for entry: FileEntry) throws -> String { "" }
}

@main
struct Probe {
    static func main() throws {
        let extractor = try CallLogExtractor(databasePath: CommandLine.arguments[1])
        let found = try extractor.searchCallLog("needle", limit: 10)
        print("FOUND|\(found.count)|\(found.first?.address ?? "")")
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        database = temp / "calls.sqlite"
        connection = sqlite3.connect(database)
        connection.execute(
            "CREATE TABLE ZCALLRECORD (Z_PK INTEGER, ZADDRESS TEXT, ZDATE REAL, "
            "ZDURATION REAL, ZCALLTYPE INTEGER, ZISO_COUNTRY_CODE TEXT)"
        )
        connection.executemany(
            "INSERT INTO ZCALLRECORD VALUES (?, ?, ?, 0, 1, 'US')",
            [(index, f"recent-{index}", float(index)) for index in range(2, 1_102)],
        )
        connection.execute("INSERT INTO ZCALLRECORD VALUES (1, 'needle', 1, 0, 1, 'US')")
        connection.commit()
        connection.close()

        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "call-search-probe"
        compile_result = subprocess.run(
            [
                "swiftc", "-parse-as-library",
                str(root / "Sources/Phosphor/Utilities/SQLiteReader.swift"),
                str(root / "Sources/Phosphor/Models/MediaItem.swift"),
                str(root / "Sources/Phosphor/Services/CallLogExtractor.swift"),
                str(probe_path), "-lsqlite3", "-o", str(executable),
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable), str(database)], capture_output=True, text=True, timeout=10)

    assert result.returncode == 0, result.stderr
    assert "FOUND|1|needle" in result.stdout, result.stdout


def test_unified_search_ui_ignores_stale_results_and_exports_selection(root: Path) -> None:
    vm = read(root, "Sources/Phosphor/ViewModels/UnifiedSearchViewModel.swift")
    view = read(root, "Sources/Phosphor/Views/Search/UnifiedSearchView.swift")
    sidebar = read(root, "Sources/Phosphor/Views/SidebarView.swift")
    content = read(root, "Sources/Phosphor/Views/ContentView.swift")
    app = read(root, "Sources/Phosphor/App/PhosphorApp.swift")

    assert "searchOperationID" in vm
    assert "searchOperationID == operationID" in vm
    assert "hasCompletedSearch" in vm, "typing a query must not make the initial UI claim that a search returned no results"
    assert "invalidateSearchState()" in vm, "query/source changes must clear stale search results"
    assert "viewModel.hasCompletedSearch" in view, "empty-state copy must reflect completed search state, not merely non-empty query text"
    assert "Task.detached" in vm, "backup database search must not run on the main actor"
    assert "withTaskCancellationHandler" in vm
    assert "worker.cancel()" in vm
    assert vm.count("invalidateSearchState()") >= 4, "query, source, backup, and cancellation changes must invalidate stale results"
    invalidation = vm.split("private func invalidateSearchState()", 1)[1]
    assert "results = []" in invalidation and "sourceErrors = [:]" in invalidation
    assert "selectedResultIDs" in vm
    assert "Export Selected" in view
    assert "Unified Search" in sidebar
    assert "UnifiedSearchView" in content
    assert "@EnvironmentObject private var viewModel: UnifiedSearchViewModel" in view
    assert "@StateObject private var unifiedSearchVM = UnifiedSearchViewModel()" in app
    assert ".environmentObject(unifiedSearchVM)" in app
    empty_results_branch = view.split("} else if viewModel.results.isEmpty {", 1)[1].split("} else {", 1)[0]
    assert "!viewModel.sourceErrors.isEmpty" in empty_results_branch
    assert "sourceWarnings" in empty_results_branch, "zero-result source failures must remain visible"


def test_unified_search_empty_state_tracks_completed_search_behaviorally(root: Path) -> None:
    support = r'''
import Foundation

struct BackupInfo: Sendable {
    let id: String
    let path: String
}

enum UnifiedSearchSource: CaseIterable, Hashable, Sendable {
    case files
}

struct UnifiedSearchResult: Identifiable, Sendable {
    let id: String
}

struct UnifiedSearchResponse: Sendable {
    let results: [UnifiedSearchResult]
    let sourceErrors: [UnifiedSearchSource: String]
}

enum UnifiedSearchService {
    static func search(
        query: String,
        backupPath: String,
        sources: Set<UnifiedSearchSource>
    ) throws -> UnifiedSearchResponse {
        if query == "slow" {
            // Deliberately ignore task cancellation and complete late. This proves
            // the view model rejects a stale success instead of relying on a
            // cooperative service to throw CancellationError.
            Thread.sleep(forTimeInterval: 0.2)
            return UnifiedSearchResponse(
                results: [UnifiedSearchResult(id: "stale")],
                sourceErrors: [:]
            )
        }
        return UnifiedSearchResponse(results: [], sourceErrors: [:])
    }
}
'''
    probe = r'''
import Foundation

@main
struct Probe {
    @MainActor
    static func main() async {
        let viewModel = UnifiedSearchViewModel()
        viewModel.chooseBackup(BackupInfo(id: "backup", path: "/backup"))

        viewModel.query = "none"
        print("TYPED|\(viewModel.hasCompletedSearch)|\(viewModel.results.count)")

        viewModel.search()
        while viewModel.isSearching { await Task.yield() }
        print("COMPLETED|\(viewModel.hasCompletedSearch)|\(viewModel.results.count)")

        viewModel.query = "changed"
        print("CHANGED|\(viewModel.hasCompletedSearch)|\(viewModel.results.count)")

        viewModel.query = "slow"
        viewModel.search()
        viewModel.query = "replacement"
        try? await Task.sleep(nanoseconds: 300_000_000)
        print("STALE|\(viewModel.hasCompletedSearch)|\(viewModel.isSearching)|\(viewModel.results.count)")
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        support_path = temp / "Support.swift"
        support_path.write_text(support)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "unified-search-state-probe"
        compile_result = subprocess.run(
            [
                "swiftc", "-parse-as-library",
                str(root / "Sources/Phosphor/ViewModels/UnifiedSearchViewModel.swift"),
                str(support_path), str(probe_path), "-o", str(executable),
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)

    assert result.returncode == 0, result.stderr
    assert "TYPED|false|0" in result.stdout, result.stdout
    assert "COMPLETED|true|0" in result.stdout, result.stdout
    assert "CHANGED|false|0" in result.stdout, result.stdout
    assert "STALE|false|false|0" in result.stdout, result.stdout


def test_unified_search_requires_an_explicit_backup(root: Path) -> None:
    vm = read(root, "Sources/Phosphor/ViewModels/UnifiedSearchViewModel.swift")
    view = read(root, "Sources/Phosphor/Views/Search/UnifiedSearchView.swift")
    assert "selectedBackup" in vm
    assert "No Backup Selected" in view
    assert "Choose Backup" in view or "backupPicker" in view
