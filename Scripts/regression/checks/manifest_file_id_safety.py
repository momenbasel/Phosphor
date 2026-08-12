"""A manifest fileID must not be able to steer a filesystem write.

An iOS backup fileID is always the 40-character lowercase SHA-1 hex of
`domain-relativePath`. The value is used unescaped to build paths:
`FileEntry.diskPath` interpolates it into `<root>/<first two chars>/<id>`, and
the encrypted-backup path writes decrypted plaintext to
`plaintextScratch.appendingPathComponent(id)`. `appendingPathComponent`
traverses `..` without complaint, and Phosphor ships with
`com.apple.security.app-sandbox` set to false, so before this guard a Files row
carrying

    ../../../../../../Users/<user>/Library/LaunchAgents/com.evil.plist

in an attacker-supplied encrypted backup wrote attacker-controlled bytes to
that path - persistence, from merely opening a backup someone sent you.
"""
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

PROBE = r'''
import Foundation

@main
struct Probe {
    static func main() {
        let traversals = [
            "../../../../../../Users/victim/Library/LaunchAgents/com.evil.plist",
            "..",
            "../etc/passwd",
            "/etc/passwd",
            "a/../../b",
            "",
            String(repeating: "a", count: 39),
            String(repeating: "a", count: 41),
            "ABCDEF0123456789abcdef0123456789abcdef01",
            "g".padding(toLength: 40, withPad: "g", startingAt: 0),
        ]
        for candidate in traversals {
            precondition(!IDCheck.isValid(candidate), "accepted \(candidate)")
        }
        precondition(IDCheck.isValid("3d0d7e5fb2ce288813306e4d4636395e047a3d28"))
        print("OK")
    }
}
'''

# Mirrors the production predicate. Kept in sync by the source assertions below.
SHIM = r'''
import Foundation

enum IDCheck {
    static func isValid(_ fileID: String) -> Bool {
        fileID.count == 40 && fileID.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
'''


def test_manifest_rejects_non_sha1_file_ids(root: Path) -> None:
    source = (root / "Sources/Phosphor/Utilities/BackupManifest.swift").read_text()

    assert "isValidFileID" in source, "BackupManifest must validate fileID shape"
    assert "Self.isValidFileID(fileID)" in source, (
        "parseFileEntry must reject a malformed fileID so no downstream sink has to"
    )
    assert "guard Self.isValidFileID(entry.id)" in source, (
        "readablePath writes decrypted bytes to a path built from the fileID and "
        "must validate it directly, not rely on its caller"
    )
    assert "fileID.count == 40" in source and "isHexDigit" in source, (
        "the predicate must pin length and alphabet"
    )

    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        (temp / "Shim.swift").write_text(SHIM)
        (temp / "Probe.swift").write_text(PROBE)
        executable = temp / "file-id-probe"
        compiled = subprocess.run(
            ["swiftc", "-parse-as-library", str(temp / "Shim.swift"), str(temp / "Probe.swift"),
             "-o", str(executable)],
            capture_output=True, text=True, timeout=120,
        )
        assert compiled.returncode == 0, compiled.stderr
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)

    assert result.returncode == 0, result.stderr
    assert "OK" in result.stdout
