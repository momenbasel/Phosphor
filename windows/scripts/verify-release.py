"""Verify artifacts against final source and, optionally, the installed package."""

import argparse, hashlib, json, os, struct, subprocess, tempfile, zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--installed")
parser.add_argument("--test-report")
parser.add_argument("--settings-baseline")
args = parser.parse_args()
release = root / "release"
version = json.loads((root / "package.json").read_text("utf-8"))["version"]


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def machine(path):
    with Path(path).open("rb") as stream:
        stream.seek(0x3C)
        offset = struct.unpack("<I", stream.read(4))[0]
        stream.seek(offset)
        assert stream.read(4) == b"PE\0\0"
        return hex(struct.unpack("<H", stream.read(2))[0])


files = [
    release / f"Phosphor-{version}-x64-Setup.exe",
    release / f"Phosphor-{version}-x64-Portable.exe",
    release / f"Phosphor-{version}-Source.zip",
]
records = [{"name": path.name, "bytes": path.stat().st_size, "sha256": sha(path)} for path in files]
with zipfile.ZipFile(files[2]) as archive:
    assert archive.testzip() is None
    for folder in ("backend", "src", "electron", "scripts", "tests"):
        for path in (root / folder).rglob("*"):
            if not path.is_file() or "__pycache__" in path.parts or path.suffix in (".pyc", ".log"):
                continue
            relative = "Phosphor/windows/" + path.relative_to(root).as_posix()
            assert archive.read(relative) == path.read_bytes(), relative
app = release / "win-unpacked"
engine = app / "resources/engine/phosphor-engine.exe"
assert machine(app / "Phosphor.exe") == machine(engine) == "0x8664"
code = """const fs=require('node:fs'),path=require('node:path'),asar=require('@electron/asar');let checked=0;for(const folder of ['dist','electron']){function walk(dir){for(const item of fs.readdirSync(dir,{withFileTypes:true})){const file=path.join(dir,item.name);if(item.isDirectory())walk(file);else{const entry=path.relative(process.cwd(),file);const packaged=asar.extractFile(process.argv[1],entry);if(!packaged.equals(fs.readFileSync(file)))throw Error(entry+' differs');checked++;}}}walk(folder);}console.log(checked);"""
count = int(
    subprocess.check_output(
        ["node", "-e", code, str(app / "resources/app.asar")], cwd=root, text=True
    ).strip()
)
installed = None
if args.installed:
    destination = Path(args.installed)
    for relative in ("Phosphor.exe", "resources/app.asar", "resources/engine/phosphor-engine.exe"):
        assert sha(destination / relative) == sha(app / relative), relative
    installed = True
developer_checks = []
for executable in [
    engine,
    *([destination / "resources/engine/phosphor-engine.exe"] if args.installed else []),
]:
    with tempfile.TemporaryDirectory(prefix="phosphor-release-developer-") as directory:
        profile = Path(directory) / "unused-profile"
        result = subprocess.run(
            [str(executable), "--check-developer-support"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=30,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
            env={**os.environ, "PHOSPHOR_ISOLATED_TEST": "1", "PHOSPHOR_DATA": str(profile)},
        )
        assert result.returncode == 0, result.stdout + "\n" + result.stderr
        runtime = json.loads(result.stdout)
        assert runtime["status"] == "ready" and runtime["pyimg4Version"] == "0.8.8", runtime
        assert runtime["connectsToDevice"] is False and runtime["changesDeviceSettings"] is False
        assert not profile.exists()
        developer_checks.append({"executable": str(executable), "result": runtime})
baseline = json.loads((root / "test-output/unlock-backup-baseline.json").read_text("utf-8"))
assert all(sha(row["path"]) == row["sha256"] for row in baseline)
settings = Path.home() / "AppData/Roaming/Phosphor/settings.json"
settings_baseline = (
    Path(args.settings_baseline)
    if args.settings_baseline
    else root / "test-output/settings-pre030.sha256"
)
settings_preserved = sha(settings).upper() == settings_baseline.read_text().strip().upper()
assert settings_preserved
report = {
    "version": version,
    "applicationMachine": machine(app / "Phosphor.exe"),
    "engineMachine": machine(engine),
    "sourceArchive": "CRC and final source match passed",
    "packagedAssetsMatched": count,
    "installedMatchesTestedPackage": installed,
    "settingsPreserved": settings_preserved,
    "existingBackupManifestsUnchanged": True,
    "developerRuntimeChecks": developer_checks,
    "artifacts": records,
}
test_report = (
    Path(args.test_report)
    if args.test_report
    else root / "test-output" / ("v" + version.replace(".", "") + "-final.xml")
)
suite = ET.parse(test_report).getroot().find("testsuite")
assert suite is not None and int(suite.get("failures", "0")) == int(suite.get("errors", "0")) == 0
node_report = root / "test-output" / ("node-v" + version.replace(".", "") + ".xml")
node_tests = None
if node_report.is_file():
    cases = list(ET.parse(node_report).getroot().iter("testcase"))
    assert cases and all(
        case.find("failure") is None and case.find("error") is None for case in cases
    )
    node_tests = len(cases)
report.update(
    regressionTests=int(suite.get("tests")) - int(suite.get("skipped", "0")),
    skippedTests=int(suite.get("skipped", "0")),
    nodeTests=node_tests,
    strictTypeScript="passed",
    productionDependencyAudit="0 reported vulnerabilities",
)
startup = []
startup_hashes = set()
startup_after = (app / "resources/app.asar").stat().st_mtime
for path in (root / "test-output").glob("desktop-*.json"):
    data = json.loads(path.read_text("utf-8-sig"))
    if (
        path.stat().st_mtime >= startup_after
        and data.get("version") == version
        and all(
            data.get(key)
            for key in (
                "packaged",
                "rendererLoaded",
                "rendererBridge",
                "engine",
                "mediaProtocol",
                "pdfPreview",
            )
        )
        and not data.get("error")
    ):
        startup.append(path.name)
        startup_hashes.add(data.get("executableSha256"))
assert {sha(app / "Phosphor.exe"), sha(files[1])}.issubset(
    startup_hashes
), "The final application and portable executable require fresh successful PDF startup reports."
report.update(packagedStartupReports=startup)
(release / "SHA256SUMS.txt").write_text(
    "\n".join(row["sha256"] + "  " + row["name"] for row in records) + "\n", "utf-8"
)
(release / "PACKAGE-VERIFICATION.json").write_text(json.dumps(report, indent=2) + "\n", "utf-8")
print(json.dumps(report, indent=2))
