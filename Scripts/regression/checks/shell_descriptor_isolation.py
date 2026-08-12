"""A spawned child must not inherit other commands' pipe descriptors.

Shell launches children with posix_spawn. Without POSIX_SPAWN_CLOEXEC_DEFAULT
every child inherits every descriptor the app has open, including the write ends
of other in-flight commands' stdout pipes. The parent closes only its own copy,
so the unrelated command's reader never sees EOF: it stalls until its read
timeout and then returns exit code 0 with empty stdout - a silent wrong answer,
not a visible failure.

Measured on the branch that introduced posix_spawn: 23 of 30 concurrent
commands lost stdout. This runs the same race and requires zero.
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
        let group = DispatchGroup()
        let lock = NSLock()
        var lostStdout = 0

        // Each short command races a long-lived one. If the long child inherits
        // the short command's stdout pipe write end, the short command's reader
        // never sees EOF and it returns success with no output.
        for _ in 0..<30 {
            group.enter()
            DispatchQueue.global().async {
                _ = Shell.run("/bin/sh", arguments: ["-c", "sleep 3"], timeout: 10)
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                let result = Shell.run("/bin/sh", arguments: ["-c", "echo OK"], timeout: 10)
                lock.lock()
                if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != "OK" {
                    lostStdout += 1
                }
                lock.unlock()
                group.leave()
            }
        }

        group.wait()
        print("LOST_STDOUT|\(lostStdout)")
    }
}
'''

STUB = "enum PyMobileDevice { static func available() -> Bool { false } }\n"


def test_spawned_children_do_not_inherit_other_commands_pipes(root: Path) -> None:
    shell_source = (root / "Sources/Phosphor/Utilities/Shell.swift").read_text()
    assert "POSIX_SPAWN_CLOEXEC_DEFAULT" in shell_source, (
        "posix_spawn must set POSIX_SPAWN_CLOEXEC_DEFAULT or children inherit "
        "other in-flight commands' stdout pipes"
    )

    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        (temp / "Shell.swift").write_text(shell_source)
        (temp / "Stub.swift").write_text(STUB)
        (temp / "Probe.swift").write_text(PROBE)
        executable = temp / "descriptor-isolation-probe"
        compiled = subprocess.run(
            [
                "swiftc", "-parse-as-library",
                str(temp / "Shell.swift"), str(temp / "Stub.swift"), str(temp / "Probe.swift"),
                "-o", str(executable),
            ],
            capture_output=True, text=True, timeout=180,
        )
        assert compiled.returncode == 0, compiled.stderr
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=120)

    assert result.returncode == 0, result.stderr
    lost = int(result.stdout.split("LOST_STDOUT|", 1)[1].split()[0])
    assert lost == 0, (
        f"{lost}/30 concurrent commands returned success with empty stdout - a "
        "child is inheriting another command's pipe write end"
    )
